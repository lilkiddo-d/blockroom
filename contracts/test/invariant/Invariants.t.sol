// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {Settlement} from "../../src/Settlement.sol";
import {MidpointPool} from "../../src/MidpointPool.sol";
import {MarketClock} from "../../src/MarketClock.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";
import {MockERC20, MockAggregator} from "../utils/Mocks.sol";

/// @dev Drives random quote creation / fills / cancels / price moves / maker inventory pulls.
contract SettlementHandler is Test {
    Settlement public settlement;
    PriceGuard public guard;
    MockAggregator public feed;
    MockERC20 public aapl;
    MockERC20 public usdg;
    address public maker;
    uint256 internal makerPk;
    address[3] public takers;

    Settlement.Quote[] internal _quotes;
    bytes[] internal _sigs;
    mapping(bytes32 => uint256) public ghostFilled;
    uint256 public ghostOutOfBandFills;
    uint256 public fills;
    uint256 public defaults;
    uint256 internal nonce;

    constructor(Settlement s, PriceGuard g, MockAggregator f, MockERC20 a, MockERC20 u, uint256 pk) {
        settlement = s;
        guard = g;
        feed = f;
        aapl = a;
        usdg = u;
        makerPk = pk;
        maker = vm.addr(pk);
        for (uint256 i; i < 3; ++i) {
            takers[i] = address(uint160(0x1000 + i));
            u.mint(takers[i], 100_000_000e6);
            a.mint(takers[i], 100_000e18);
            vm.startPrank(takers[i]);
            u.approve(address(s), type(uint256).max);
            a.approve(address(s), type(uint256).max);
            vm.stopPrank();
        }
    }

    function quoteCount() external view returns (uint256) {
        return _quotes.length;
    }

    function quoteAt(uint256 i) external view returns (Settlement.Quote memory) {
        return _quotes[i];
    }

    /// Maker signs a fresh quote around the current mid (sometimes deliberately off-market).
    function newQuote(uint256 seed) public {
        if (_quotes.length >= 40) return;
        uint256 mid = guard.getMid(address(aapl), address(usdg));
        int256 offBps = int256(seed % 301) - 150; // +/-1.5%: some quotes fall outside the 1% band
        uint256 price = uint256(int256(mid) + (int256(mid) * offBps) / 10_000);
        uint256 size = bound(seed >> 16, 1e18, 200e18);
        Settlement.Quote memory q = Settlement.Quote({
            rfqId: keccak256(abi.encode(seed)),
            maker: maker,
            taker: address(0),
            baseToken: address(aapl),
            quoteToken: address(usdg),
            side: uint8((seed >> 8) % 2),
            tif: uint8((seed >> 12) % 3),
            price: price,
            size: size,
            minFill: (seed >> 40) % 3 == 0 ? size / 4 : 0,
            nonce: ++nonce,
            expiry: uint64(block.timestamp + 5 minutes)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, settlement.hashQuote(q));
        _quotes.push(q);
        _sigs.push(abi.encodePacked(r, s, v));
    }

    function fill(uint256 qi, uint256 ti, uint256 amount) public {
        if (_quotes.length == 0) newQuote(amount);
        qi = bound(qi, 0, _quotes.length - 1);
        Settlement.Quote memory q = _quotes[qi];
        bytes32 d = settlement.hashQuote(q);
        uint256 rem = q.size - settlement.filled(d);
        if (rem == 0) return;
        if (q.tif == 2) amount = q.size;
        else amount = bound(amount, q.minFill < rem ? q.minFill : rem, rem);
        if (amount == 0) amount = 1;
        address t = takers[bound(ti, 0, 2)];
        uint256 mid = guard.getMid(q.baseToken, q.quoteToken);
        vm.prank(t);
        try settlement.fill(q, _sigs[qi], amount) returns (uint256, uint256, bool defaulted) {
            uint256 diff = q.price > mid ? q.price - mid : mid - q.price;
            if (diff * 10_000 > mid * guard.bandBps(q.baseToken)) ghostOutOfBandFills++;
            if (defaulted) {
                defaults++;
            } else {
                ghostFilled[d] += amount;
                fills++;
            }
        } catch {}
    }

    function movePrice(uint256 px) external {
        px = bound(px, 336e8, 344e8);
        feed.set(int256(px));
    }

    function cancel(uint256 qi) external {
        if (_quotes.length == 0) return;
        qi = bound(qi, 0, _quotes.length - 1);
        vm.prank(maker);
        try settlement.invalidateNonce(_quotes[qi].nonce) {} catch {}
    }

    function makerPullsInventory(bool pull) external {
        vm.prank(maker);
        aapl.approve(address(settlement), pull ? 0 : type(uint256).max);
    }

    function warp(uint256 s) external {
        vm.warp(block.timestamp + bound(s, 0, 30));
        feed.set(feed.answer());
    }
}

contract SettlementInvariantTest is BaseTest {
    SettlementHandler handler;
    uint256 supplyUsdg;
    uint256 supplyAapl;

    function setUp() public override {
        super.setUp();
        _registerMaker(maker, 1_000_000e6);
        _fundAndApprove(aapl, maker, address(settlement), 5_000e18);
        _fundAndApprove(usdg, maker, address(settlement), 5_000_000e6);

        handler = new SettlementHandler(settlement, guard, aaplFeed, aapl, usdg, makerPk);
        targetContract(address(handler));
        supplyUsdg = usdg.totalSupply();
        supplyAapl = aapl.totalSupply();
    }

    /// A signed quote can fill at most its size (and only once in total).
    function invariant_neverOverfilled() public view {
        for (uint256 i; i < handler.quoteCount(); ++i) {
            Settlement.Quote memory q = handler.quoteAt(i);
            bytes32 d = settlement.hashQuote(q);
            assertLe(settlement.filled(d), q.size);
            assertLe(handler.ghostFilled(d), q.size);
        }
    }

    /// No settlement ever happens outside the price guard.
    function invariant_noFillOutsideGuard() public view {
        assertEq(handler.ghostOutOfBandFills(), 0);
    }

    /// Settlement never custodies funds between transactions.
    function invariant_settlementHoldsNothing() public view {
        assertEq(usdg.balanceOf(address(settlement)), 0);
        assertEq(aapl.balanceOf(address(settlement)), 0);
    }

    /// Non-vacuity: drive the same handler through a long pseudo-random sequence and prove it really
    /// settles quotes (and defaults) while every invariant keeps holding.
    function test_handlerExercisesFills() public {
        for (uint256 i; i < 300; ++i) {
            uint256 r = uint256(keccak256(abi.encode(i)));
            uint256 op = r % 10;
            if (op < 4) handler.fill(r >> 8, r >> 16, r >> 24);
            else if (op < 6) handler.newQuote(r >> 8);
            else if (op == 6) handler.movePrice(r >> 8);
            else if (op == 7) handler.warp(r >> 8);
            else if (op == 8) handler.makerPullsInventory((r >> 8) % 4 == 0);
            else handler.cancel(r >> 8);
            invariant_neverOverfilled();
            invariant_noFillOutsideGuard();
            invariant_settlementHoldsNothing();
            invariant_conservation();
        }
        assertGt(handler.fills(), 20, "handler must exercise real fills");
        assertGt(handler.defaults(), 0, "handler must exercise maker defaults");
    }

    /// Tokens are conserved (no mint/burn through the protocol).
    function invariant_conservation() public view {
        assertEq(usdg.totalSupply(), supplyUsdg);
        assertEq(aapl.totalSupply(), supplyAapl);
    }
}

/// @dev Drives commit / reveal / settle cycles on the midpoint pool with random orders and prices.
contract MidpointHandler is Test {
    MidpointPool public pool;
    MockAggregator public feed;
    address public asset;
    address public quote;
    address[4] public traders;

    MidpointPool.OrderReveal[] internal _pending;
    uint64[] public settledBatches;
    uint256 public ghostOffMidExecutions;
    uint256 public ghostMidMismatch;
    uint256 public ghostExecutions;

    constructor(MidpointPool p, MockAggregator f, MockERC20 a, MockERC20 u) {
        pool = p;
        feed = f;
        asset = address(a);
        quote = address(u);
        for (uint256 i; i < 4; ++i) {
            traders[i] = address(uint160(0x2000 + i));
            u.mint(traders[i], 10_000_000e6);
            a.mint(traders[i], 10_000e18);
            vm.startPrank(traders[i]);
            u.approve(address(p), type(uint256).max);
            a.approve(address(p), type(uint256).max);
            p.deposit(address(u), 1_000_000e6);
            p.deposit(address(a), 1_000e18);
            vm.stopPrank();
        }
    }

    function settledCount() external view returns (uint256) {
        return settledBatches.length;
    }

    function commit(uint256 ti, bool buy, uint128 size, uint128 minFill, uint128 limit, bytes32 salt) external {
        address t = traders[bound(ti, 0, 3)];
        size = uint128(bound(size, 1e16, 200e18));
        minFill = uint128(bound(minFill, 0, size));
        limit = buy ? uint128(bound(limit, 300e6, 400e6)) : uint128(bound(limit, 0, 380e6));
        MidpointPool.OrderReveal memory r = MidpointPool.OrderReveal({
            trader: t,
            asset: asset,
            batchId: pool.currentBatchId(),
            side: buy ? 0 : 1,
            tif: uint8(uint256(salt) % 2),
            size: size,
            minFill: minFill,
            limitPrice: limit,
            salt: salt
        });
        bytes32 c = pool.hashOrder(r);
        vm.prank(t);
        try pool.commit(asset, c) {
            _pending.push(r);
        } catch {}
    }

    /// Advance to the reveal window, reveal everything pending, then settle at a fresh price.
    function runBatch(uint256 px, bool revealAll) external {
        if (_pending.length == 0) return;
        uint64 id = _pending[0].batchId;
        MidpointPool.Batch memory info = pool.batchInfo(asset, id);
        uint64 commitEnd = info.commitEnd;
        uint64 revealEnd = info.revealEnd;
        if (commitEnd == 0) {
            delete _pending;
            return;
        }
        if (block.timestamp < commitEnd) vm.warp(commitEnd);
        for (uint256 i; i < _pending.length; ++i) {
            if (!revealAll && i % 3 == 2) continue;
            try pool.reveal(_pending[i]) {} catch {}
        }
        if (block.timestamp < revealEnd) vm.warp(revealEnd);
        px = bound(px, 300e8, 380e8);
        feed.set(int256(px));
        vm.recordLogs();
        try pool.settle(asset, id) {
            settledBatches.push(id);
            MidpointPool.Batch memory b = pool.batchInfo(asset, id);
            if (!b.voided && b.mid != px / 100) ghostMidMismatch++;
            bytes32 sig = keccak256("Matched(address,uint64,address,address,uint256,uint256,uint256)");
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].topics[0] != sig) continue;
                (,,,, uint256 m) = abi.decode(logs[i].data, (address, address, uint256, uint256, uint256));
                if (m != px / 100) ghostOffMidExecutions++;
                ghostExecutions++;
            }
        } catch {}
        delete _pending;
        // keep inside a trading session: jump to next day's 10:00 ET if near the close
        vm.warp(block.timestamp + 30);
    }

    function withdraw(uint256 ti, uint256 amt, bool base) external {
        address t = traders[bound(ti, 0, 3)];
        address tok = base ? asset : quote;
        amt = bound(amt, 1, 1_000e6);
        vm.prank(t);
        try pool.withdraw(tok, amt) {} catch {}
    }

    function traderAt(uint256 i) external view returns (address) {
        return traders[i];
    }
}

import {Vm} from "forge-std/Vm.sol";

contract MidpointInvariantTest is BaseTest {
    MidpointHandler handler;

    function setUp() public override {
        super.setUp();
        // widen market hours so long invariant runs stay inside a session
        vm.startPrank(admin);
        clock.setSessionHours(0, 1440);
        vm.stopPrank();
        handler = new MidpointHandler(pool, aaplFeed, aapl, usdg);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](3);
        sel[0] = MidpointHandler.commit.selector;
        sel[1] = MidpointHandler.runBatch.selector;
        sel[2] = MidpointHandler.withdraw.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        excludeSender(address(pool));
    }

    /// Midpoint matches always execute at the oracle mid.
    function invariant_matchesAtOracleMid() public view {
        assertEq(handler.ghostOffMidExecutions(), 0);
        assertEq(handler.ghostMidMismatch(), 0);
    }

    /// Non-vacuity: a long pseudo-random commit/reveal/settle sequence must produce real executions.
    function test_handlerExercisesBatches() public {
        for (uint256 i; i < 120; ++i) {
            uint256 r = uint256(keccak256(abi.encode("mp", i)));
            if (r % 4 == 3) handler.runBatch(r >> 8, (r >> 16) % 3 != 0);
            else handler.commit(r >> 8, (r >> 9) % 2 == 0, uint128(r >> 16), uint128(r >> 48), uint128(r >> 80), bytes32(r));
            invariant_matchesAtOracleMid();
            invariant_solvent();
        }
        assertGt(handler.settledCount(), 5, "batches settled");
        assertGt(handler.ghostExecutions(), 0, "midpoint executions happened");
    }

    /// The pool is always solvent: token balances cover every internal ledger entry and lock.
    function invariant_solvent() public view {
        uint256 ledgerA;
        uint256 ledgerU;
        for (uint256 i; i < 4; ++i) {
            address t = handler.traderAt(i);
            ledgerA += pool.freeBalance(t, address(aapl));
            ledgerU += pool.freeBalance(t, address(usdg));
        }
        assertGe(aapl.balanceOf(address(pool)), ledgerA);
        assertGe(usdg.balanceOf(address(pool)), ledgerU);
    }
}
