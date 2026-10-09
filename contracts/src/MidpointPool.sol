// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BlockroomBase} from "./base/BlockroomBase.sol";
import {Actions} from "./libraries/Actions.sol";
import {IFeeCollector, IMarketClock, IPriceGuard, IProjectTokenHooks} from "./interfaces/IBlockroom.sol";

/// @title MidpointPool
/// @notice Dark-pool style midpoint cross with commit-reveal batches.
///
///   1. Traders keep funds in an internal ledger (`deposit` / `withdraw`), decoupled in time from orders, so
///      an order's side and size are not revealed by a same-block token transfer.
///   2. COMMIT phase (batch window, market open): post `keccak256(abi.encode(OrderReveal))` and lock a small
///      anti-spam bond. Only the asset and the fact that someone committed are public.
///   3. REVEAL phase: anyone holding the preimage (trader or the trader's keeper) reveals; funds are locked.
///   4. SETTLE: after the reveal window, anyone settles. All executions in a batch print at the SAME oracle
///      mid read once at settlement; batches void (everything unlocked, bonds refunded) if the market is
///      closed, the oracle is unhealthy, the pool is paused, or the settle deadline passed.
///
///   Matching: FIFO by commit order, two-pointer walk, O(n) with n <= MAX_ORDERS_PER_BATCH. Each execution must be
///   >= both orders' effective minimum (min(minFill, remaining)), i.e. minimum-acceptable-quantity semantics.
///   FOK orders use minFill = size (a single counterparty must take the whole order).
contract MidpointPool is BlockroomBase, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Side {
        Buy,
        Sell
    }

    enum Tif {
        IOC, // whatever fills in this batch, remainder unlocked
        FOK // full size in one execution or nothing
    }

    enum Status {
        None,
        Committed,
        Revealed,
        Cancelled,
        Forfeited
    }

    struct OrderReveal {
        address trader;
        address asset;
        uint64 batchId;
        uint8 side;
        uint8 tif;
        uint128 size; // base units
        uint128 minFill; // base units
        uint128 limitPrice; // quote units per whole base token; buys: max, sells: min (0 = any)
        bytes32 salt;
    }

    struct Order {
        address trader;
        uint8 side;
        Status status;
        uint128 size;
        uint128 minFill;
        uint128 limitPrice;
        uint128 filled;
        uint256 locked;
    }

    struct Batch {
        uint64 commitEnd;
        uint64 revealEnd;
        uint64 settleDeadline;
        uint16 feeBps;
        uint16 count;
        bool settled;
        bool voided;
        uint128 commitBond;
        uint256 mid;
        uint256 matchedBase;
    }

    struct CommitInfo {
        address trader;
        address asset;
        uint64 batchId;
        uint16 index;
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_ORDERS_PER_BATCH = 64;
    uint16 public constant MAX_FEE_BPS = 100;

    IERC20 public immutable quoteToken;
    IPriceGuard public priceGuard;
    IMarketClock public clock;
    IFeeCollector public feeCollector;
    IProjectTokenHooks public hooks;

    uint32 public batchDuration;
    uint32 public revealWindow;
    uint32 public settleWindow;
    uint16 public feeBps;
    uint16 public maxOrdersPerBatch;
    uint8 public maxCommitsPerTrader;
    uint128 public commitBond;

    mapping(address asset => uint8) public assetDecimalsPlusOne;
    mapping(address user => mapping(address token => uint256)) public freeBalance;
    mapping(address asset => mapping(uint64 batchId => Batch)) internal _batches;
    mapping(address asset => mapping(uint64 batchId => mapping(uint256 idx => Order))) internal _orders;
    mapping(bytes32 commitment => CommitInfo) public commitInfo;
    mapping(address trader => mapping(address asset => mapping(uint64 batchId => uint8))) public traderCommits;

    error AssetNotAllowed();
    error TokenNotAllowed();
    error MarketClosed();
    error BatchFull();
    error TooManyCommits();
    error DuplicateCommitment();
    error UnknownCommitment();
    error NotCommitPhase();
    error NotRevealPhase();
    error NotSettleable();
    error AlreadySettled();
    error InvalidOrder();
    error InsufficientBalance();
    error ZeroAmount();
    error NotTrader();

    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);
    event Committed(address indexed asset, uint64 indexed batchId, bytes32 indexed commitment, address trader, uint16 index);
    event CommitCancelled(bytes32 indexed commitment);
    event Revealed(
        address indexed asset,
        uint64 indexed batchId,
        bytes32 indexed commitment,
        address trader,
        uint8 side,
        uint128 size,
        uint128 minFill,
        uint128 limitPrice
    );
    event Matched(
        address indexed asset,
        uint64 indexed batchId,
        address buyer,
        address seller,
        uint256 baseAmount,
        uint256 quoteAmount,
        uint256 mid
    );
    event BatchSettled(address indexed asset, uint64 indexed batchId, uint256 mid, uint256 matchedBase, uint256 fees);
    event BatchVoided(address indexed asset, uint64 indexed batchId);
    event AssetSet(address indexed asset, bool allowed, uint8 decimals);
    event ParamsSet(
        uint32 batchDuration,
        uint32 revealWindow,
        uint32 settleWindow,
        uint16 feeBps,
        uint16 maxOrdersPerBatch,
        uint8 maxCommitsPerTrader,
        uint128 commitBond
    );
    event ModulesSet(address priceGuard, address clock, address feeCollector, address hooks);

    struct Params {
        uint32 batchDuration;
        uint32 revealWindow;
        uint32 settleWindow;
        uint16 feeBps;
        uint16 maxOrdersPerBatch;
        uint8 maxCommitsPerTrader;
        uint128 commitBond;
    }

    constructor(
        address admin,
        address guardian,
        address quoteToken_,
        address priceGuard_,
        address clock_,
        address feeCollector_,
        address hooks_,
        Params memory p
    ) BlockroomBase(admin, guardian) {
        if (quoteToken_ == address(0)) revert ZeroAddress();
        quoteToken = IERC20(quoteToken_);
        _setModules(priceGuard_, clock_, feeCollector_, hooks_);
        _setParams(p);
    }

    // ------------------------------------------------------------------ admin

    function setModules(address priceGuard_, address clock_, address feeCollector_, address hooks_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setModules(priceGuard_, clock_, feeCollector_, hooks_);
    }

    function setParams(Params calldata p) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setParams(p);
    }

    function setAsset(address asset, bool allowed, uint8 decimals) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        if (asset == address(quoteToken) || decimals > 36) revert InvalidParam();
        assetDecimalsPlusOne[asset] = allowed ? decimals + 1 : 0;
        emit AssetSet(asset, allowed, decimals);
    }

    // ----------------------------------------------------------------- ledger

    function deposit(address token, uint256 amount) external nonReentrant whenNotPaused {
        if (token != address(quoteToken) && assetDecimalsPlusOne[token] == 0) revert TokenNotAllowed();
        if (amount == 0) revert ZeroAmount();
        _requireCompliant(msg.sender, Actions.MIDPOINT);
        IERC20 t = IERC20(token);
        uint256 before = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = t.balanceOf(address(this)) - before;
        freeBalance[msg.sender][token] += received;
        emit Deposited(msg.sender, token, received);
    }

    /// @notice Always available, even while paused.
    function withdraw(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = freeBalance[msg.sender][token];
        if (amount > bal) revert InsufficientBalance();
        freeBalance[msg.sender][token] = bal - amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, token, amount);
    }

    // ----------------------------------------------------------------- orders

    function currentBatchId() public view returns (uint64) {
        return uint64(block.timestamp / batchDuration);
    }

    function commit(address asset, bytes32 commitment) external nonReentrant whenNotPaused {
        if (assetDecimalsPlusOne[asset] == 0) revert AssetNotAllowed();
        if (!clock.isOpen()) revert MarketClosed();
        _requireCompliant(msg.sender, Actions.MIDPOINT);
        if (commitInfo[commitment].trader != address(0)) revert DuplicateCommitment();

        uint64 id = currentBatchId();
        Batch storage b = _batches[asset][id];
        if (b.commitEnd == 0) {
            uint64 commitEnd = (id + 1) * batchDuration;
            b.commitEnd = commitEnd;
            b.revealEnd = commitEnd + revealWindow;
            b.settleDeadline = commitEnd + revealWindow + settleWindow;
            b.feeBps = feeBps;
            b.commitBond = commitBond;
        }
        if (block.timestamp >= b.commitEnd || b.settled) revert NotCommitPhase();
        if (b.count >= maxOrdersPerBatch) revert BatchFull();
        uint8 tc = traderCommits[msg.sender][asset][id];
        if (tc >= maxCommitsPerTrader) revert TooManyCommits();
        traderCommits[msg.sender][asset][id] = tc + 1;

        uint128 bond = b.commitBond;
        if (bond > 0) {
            uint256 bal = freeBalance[msg.sender][address(quoteToken)];
            if (bal < bond) revert InsufficientBalance();
            freeBalance[msg.sender][address(quoteToken)] = bal - bond;
        }
        uint16 idx = b.count;
        b.count = idx + 1;
        commitInfo[commitment] = CommitInfo({trader: msg.sender, asset: asset, batchId: id, index: idx});
        Order storage o = _orders[asset][id][idx];
        o.trader = msg.sender;
        o.status = Status.Committed;
        emit Committed(asset, id, commitment, msg.sender, idx);
    }

    /// @notice Withdraw a commitment during the commit phase; the bond is refunded.
    function cancelCommit(bytes32 commitment) external nonReentrant {
        CommitInfo memory c = commitInfo[commitment];
        if (c.trader == address(0)) revert UnknownCommitment();
        if (c.trader != msg.sender) revert NotTrader();
        Batch storage b = _batches[c.asset][c.batchId];
        if (block.timestamp >= b.commitEnd) revert NotCommitPhase();
        Order storage o = _orders[c.asset][c.batchId][c.index];
        if (o.status != Status.Committed) revert InvalidOrder();
        o.status = Status.Cancelled;
        freeBalance[msg.sender][address(quoteToken)] += b.commitBond;
        emit CommitCancelled(commitment);
    }

    function hashOrder(OrderReveal calldata r) public pure returns (bytes32) {
        return keccak256(abi.encode(r));
    }

    /// @notice Reveal a committed order. Callable by anyone holding the preimage (e.g. a keeper).
    function reveal(OrderReveal calldata r) external nonReentrant whenNotPaused {
        _reveal(r);
    }

    function revealMany(OrderReveal[] calldata rs) external nonReentrant whenNotPaused {
        uint256 n = rs.length;
        if (n > MAX_ORDERS_PER_BATCH) revert InvalidOrder();
        for (uint256 i; i < n; ++i) {
            _reveal(rs[i]);
        }
    }

    // ----------------------------------------------------------------- settle

    function settle(address asset, uint64 batchId) external nonReentrant {
        Batch storage b = _batches[asset][batchId];
        if (b.commitEnd == 0 || block.timestamp < b.revealEnd) revert NotSettleable();
        if (b.settled) revert AlreadySettled();
        b.settled = true;

        bool ok = !paused() && block.timestamp <= b.settleDeadline && clock.isOpen();
        uint256 mid = 0;
        if (ok) {
            try priceGuard.getMid(asset, address(quoteToken)) returns (uint256 m) {
                mid = m;
            } catch {
                ok = false;
            }
        }

        uint256 fees = 0;
        uint256 n = b.count;
        if (ok) {
            b.mid = mid;
            fees = _match(
                b,
                MatchCtx({
                    asset: asset,
                    batchId: batchId,
                    mid: mid,
                    unit: 10 ** (assetDecimalsPlusOne[asset] - 1),
                    n: n,
                    feeBps: b.feeBps
                })
            );
        } else {
            b.voided = true;
        }
        fees += _release(asset, batchId, b, n, !ok);

        if (ok) emit BatchSettled(asset, batchId, mid, b.matchedBase, fees);
        else emit BatchVoided(asset, batchId);

        if (fees > 0) {
            quoteToken.safeTransfer(address(feeCollector), fees);
            feeCollector.notifyFee(address(quoteToken), fees);
        }
    }

    // ------------------------------------------------------------------ views

    function batchInfo(address asset, uint64 batchId) external view returns (Batch memory) {
        return _batches[asset][batchId];
    }

    function orderAt(address asset, uint64 batchId, uint256 idx) external view returns (Order memory) {
        return _orders[asset][batchId][idx];
    }

    /// @notice Phase timestamps for the batch that would accept a commit right now.
    function currentWindows() external view returns (uint64 id, uint64 commitEnd, uint64 revealEnd, uint64 settleBy) {
        id = currentBatchId();
        commitEnd = (id + 1) * batchDuration;
        revealEnd = commitEnd + revealWindow;
        settleBy = revealEnd + settleWindow;
    }

    // --------------------------------------------------------------- internal

    function _reveal(OrderReveal calldata r) internal {
        bytes32 commitment = keccak256(abi.encode(r));
        CommitInfo memory c = commitInfo[commitment];
        if (c.trader == address(0)) revert UnknownCommitment();
        if (r.trader != c.trader || r.asset != c.asset || r.batchId != c.batchId) revert InvalidOrder();
        Batch storage b = _batches[c.asset][c.batchId];
        if (block.timestamp < b.commitEnd || block.timestamp >= b.revealEnd || b.settled) revert NotRevealPhase();
        Order storage o = _orders[c.asset][c.batchId][c.index];
        if (o.status != Status.Committed) revert InvalidOrder();
        if (r.side > uint8(Side.Sell) || r.tif > uint8(Tif.FOK) || r.size == 0 || r.minFill > r.size) {
            revert InvalidOrder();
        }
        if (r.side == uint8(Side.Buy) && r.limitPrice == 0) revert InvalidOrder();

        // refund bond, then lock order funds
        freeBalance[c.trader][address(quoteToken)] += b.commitBond;
        o.locked = _lock(r, b.feeBps);
        o.side = r.side;
        o.status = Status.Revealed;
        o.size = r.size;
        o.minFill = r.tif == uint8(Tif.FOK) ? r.size : r.minFill;
        o.limitPrice = r.limitPrice;
        emit Revealed(c.asset, c.batchId, commitment, c.trader, r.side, r.size, o.minFill, r.limitPrice);
    }

    /// @dev Buys lock size * limit + max fee in quote token; sells lock size in base token.
    function _lock(OrderReveal calldata r, uint256 batchFeeBps) internal returns (uint256 lockAmt) {
        address lockToken;
        if (r.side == uint8(Side.Buy)) {
            uint256 notional =
                Math.mulDiv(r.size, r.limitPrice, 10 ** (assetDecimalsPlusOne[r.asset] - 1), Math.Rounding.Ceil);
            lockAmt = notional + Math.mulDiv(notional, batchFeeBps, BPS, Math.Rounding.Ceil);
            lockToken = address(quoteToken);
        } else {
            lockAmt = r.size;
            lockToken = r.asset;
        }
        uint256 bal = freeBalance[r.trader][lockToken];
        if (bal < lockAmt) revert InsufficientBalance();
        freeBalance[r.trader][lockToken] = bal - lockAmt;
    }

    struct MatchCtx {
        address asset;
        uint64 batchId;
        uint256 mid;
        uint256 unit;
        uint256 n;
        uint256 feeBps;
    }

    function _match(Batch storage b, MatchCtx memory ctx) internal returns (uint256 fees) {
        mapping(uint256 => Order) storage book = _orders[ctx.asset][ctx.batchId];
        uint256 bi = _nextEligible(book, 0, ctx.n, uint8(Side.Buy), ctx.mid);
        uint256 si = _nextEligible(book, 0, ctx.n, uint8(Side.Sell), ctx.mid);
        uint256 matched;
        while (bi < ctx.n && si < ctx.n) {
            (uint256 q, uint256 fee, bool advanceBuy, bool advanceSell) = _cross(book[bi], book[si], ctx);
            fees += fee;
            matched += q;
            if (advanceBuy) bi = _nextEligible(book, bi + 1, ctx.n, uint8(Side.Buy), ctx.mid);
            if (advanceSell) si = _nextEligible(book, si + 1, ctx.n, uint8(Side.Sell), ctx.mid);
        }
        b.matchedBase = matched;
    }

    /// @dev One step of the two-pointer walk. Either executes min(remaining) at mid - which fully fills at least
    ///      one side - or, if the size is below either order's minimum, skips the order with less remaining.
    function _cross(Order storage buy, Order storage sell, MatchCtx memory ctx)
        internal
        returns (uint256 q, uint256 fee, bool advanceBuy, bool advanceSell)
    {
        {
            uint256 remB = buy.size - buy.filled;
            uint256 remS = sell.size - sell.filled;
            q = remB < remS ? remB : remS;
            if (
                q < _effMin(buy.minFill, remB) || q < _effMin(sell.minFill, remS)
                    || Math.mulDiv(q, ctx.mid, ctx.unit) == 0
            ) {
                return (0, 0, remB <= remS, remB > remS);
            }
        }
        fee = _applyFill(buy, sell, q, ctx);
        advanceBuy = buy.filled == buy.size;
        advanceSell = sell.filled == sell.size;
    }

    function _applyFill(Order storage buy, Order storage sell, uint256 q, MatchCtx memory ctx)
        internal
        returns (uint256 fee)
    {
        uint256 notional = Math.mulDiv(q, ctx.mid, ctx.unit);
        uint256 feeB = _fee(buy.trader, notional, ctx.feeBps);
        uint256 feeS = _fee(sell.trader, notional, ctx.feeBps);
        // q <= remaining <= size (uint128), so the casts are lossless.
        buy.filled += uint128(q);
        buy.locked -= notional + feeB;
        sell.filled += uint128(q);
        sell.locked -= q;
        freeBalance[buy.trader][ctx.asset] += q;
        freeBalance[sell.trader][address(quoteToken)] += notional - feeS;
        fee = feeB + feeS;
        emit Matched(ctx.asset, ctx.batchId, buy.trader, sell.trader, q, notional, ctx.mid);
    }

    /// @dev Unlock residual funds; forfeit (or refund on void) bonds of unrevealed commitments.
    function _release(address asset, uint64 batchId, Batch storage b, uint256 n, bool voided)
        internal
        returns (uint256 forfeited)
    {
        mapping(uint256 => Order) storage book = _orders[asset][batchId];
        address quote = address(quoteToken);
        for (uint256 i; i < n; ++i) {
            Order storage o = book[i];
            if (o.status == Status.Committed) {
                if (voided) {
                    freeBalance[o.trader][quote] += b.commitBond;
                    o.status = Status.Cancelled;
                } else {
                    forfeited += b.commitBond;
                    o.status = Status.Forfeited;
                }
            } else if (o.status == Status.Revealed && o.locked > 0) {
                uint256 amt = o.locked;
                o.locked = 0;
                freeBalance[o.trader][o.side == uint8(Side.Buy) ? quote : asset] += amt;
            }
        }
    }

    function _nextEligible(mapping(uint256 => Order) storage book, uint256 from, uint256 n, uint8 side, uint256 mid)
        internal
        view
        returns (uint256 i)
    {
        for (i = from; i < n; ++i) {
            Order storage o = book[i];
            if (o.status != Status.Revealed || o.side != side) continue;
            if (side == uint8(Side.Buy) ? o.limitPrice >= mid : o.limitPrice <= mid) return i;
        }
    }

    function _effMin(uint256 minFill, uint256 rem) internal pure returns (uint256) {
        return minFill < rem ? minFill : rem;
    }

    function _fee(address trader, uint256 notional, uint256 bps) internal view returns (uint256) {
        if (bps == 0) return 0;
        uint256 discount = hooks.feeDiscountBps(trader);
        if (discount > BPS) discount = BPS;
        return Math.mulDiv(notional, bps * (BPS - discount), BPS * BPS);
    }

    function _setModules(address priceGuard_, address clock_, address feeCollector_, address hooks_) internal {
        if (
            priceGuard_ == address(0) || clock_ == address(0) || feeCollector_ == address(0) || hooks_ == address(0)
        ) revert ZeroAddress();
        priceGuard = IPriceGuard(priceGuard_);
        clock = IMarketClock(clock_);
        feeCollector = IFeeCollector(feeCollector_);
        hooks = IProjectTokenHooks(hooks_);
        emit ModulesSet(priceGuard_, clock_, feeCollector_, hooks_);
    }

    function _setParams(Params memory p) internal {
        if (
            p.batchDuration < 30 || p.batchDuration > 1 days || p.revealWindow < 15 || p.revealWindow > 1 hours
                || p.settleWindow < 30 || p.settleWindow > 1 days || p.feeBps > MAX_FEE_BPS || p.maxOrdersPerBatch == 0
                || p.maxOrdersPerBatch > MAX_ORDERS_PER_BATCH || p.maxCommitsPerTrader == 0
        ) revert InvalidParam();
        batchDuration = p.batchDuration;
        revealWindow = p.revealWindow;
        settleWindow = p.settleWindow;
        feeBps = p.feeBps;
        maxOrdersPerBatch = p.maxOrdersPerBatch;
        maxCommitsPerTrader = p.maxCommitsPerTrader;
        commitBond = p.commitBond;
        emit ParamsSet(
            p.batchDuration,
            p.revealWindow,
            p.settleWindow,
            p.feeBps,
            p.maxOrdersPerBatch,
            p.maxCommitsPerTrader,
            p.commitBond
        );
    }
}
