// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BlockroomBase} from "./base/BlockroomBase.sol";
import {Actions} from "./libraries/Actions.sol";
import {IFeeCollector, IMakerRegistry, IPriceGuard, IProjectTokenHooks} from "./interfaces/IBlockroom.sol";

/// @title Settlement
/// @notice Atomic on-chain settlement of EIP-712 RFQ quotes signed by registered market makers.
///
///  Quote lifecycle & replay protection
///   - Domain-separated (chainId + this contract), so a quote can't be replayed on another chain/deployment.
///   - `filled[digest]` caps total fills at `size`; once fully filled (or IOC/FOK used, or defaulted) the
///     maker's nonce is burned in a bitmap. Makers can cancel single nonces or bulk-cancel via `minNonce`.
///   - Expiry is bounded by `maxQuoteTtl`, which is shorter than MakerRegistry's unbonding period.
///
///  Anti last-look
///   - Before moving any funds, both legs are checked for deliverability (balance + allowance). A taker who can't
///     pay reverts (so makers can't be griefed into slashes). A maker who can't deliver - e.g. pulled inventory or
///     approval after seeing the fill - is slashed `slashBps` of notional, paid to the taker, and the quote is
///     burned. Reneging always costs the maker.
///   - Allowlisted tokens must be standard ERC-20s (no fee-on-transfer / rebasing on raw balances): Robinhood
///     stock tokens and USDG qualify (stock-token corporate actions use a UI multiplier, not rebasing).
///
///  Price guard
///   - Every fill re-checks the quote price against the oracle mid (PriceGuard band). Out-of-band = revert,
///     no slash - this is the maker's protection against stale quotes being picked off.
contract Settlement is BlockroomBase, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    enum Side {
        MakerSells, // taker buys base, pays quote
        MakerBuys // taker sells base, receives quote
    }

    enum TimeInForce {
        GTD, // good-til-expiry: any number of partial fills >= minFill
        IOC, // one fill (partial allowed, >= minFill), remainder cancelled
        FOK // one fill of the full size or nothing
    }

    struct Quote {
        bytes32 rfqId;
        address maker;
        address taker; // address(0) = any taker
        address baseToken;
        address quoteToken;
        uint8 side;
        uint8 tif;
        uint256 price; // quote units per one whole base token
        uint256 size; // base units
        uint256 minFill; // base units
        uint256 nonce;
        uint64 expiry;
    }

    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(bytes32 rfqId,address maker,address taker,address baseToken,address quoteToken,uint8 side,uint8 tif,uint256 price,uint256 size,uint256 minFill,uint256 nonce,uint64 expiry)"
    );
    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 100;
    uint16 public constant MAX_SLASH_BPS = 2_000;

    IMakerRegistry public immutable registry;
    IPriceGuard public priceGuard;
    IFeeCollector public feeCollector;
    IProjectTokenHooks public hooks;

    uint16 public feeBps;
    uint16 public slashBps;
    uint32 public maxQuoteTtl;

    /// @dev decimals + 1 for allowlisted base tokens (0 = not allowed)
    mapping(address token => uint8) public baseTokenDecimalsPlusOne;
    mapping(address token => bool) public quoteTokenAllowed;

    mapping(bytes32 digest => uint256) public filled;
    mapping(address maker => mapping(uint256 word => uint256)) public nonceBitmap;
    mapping(address maker => uint256) public minNonce;

    error QuoteExpired();
    error QuoteTtlTooLong();
    error NonceUsed();
    error BadSignature();
    error MakerNotEligible();
    error WrongTaker();
    error SelfTrade();
    error TokenNotAllowed();
    error InvalidAmount();
    error BelowMinFill();
    error ExceedsRemaining();
    error InvalidQuote();
    error MinNonceDecrease();
    error TakerCannotPay();

    event QuoteFilled(
        bytes32 indexed digest,
        bytes32 indexed rfqId,
        address indexed maker,
        address taker,
        address baseToken,
        address quoteToken,
        uint8 side,
        uint256 baseAmount,
        uint256 quoteAmount,
        uint256 fee,
        uint256 mid
    );
    /// @param penalty bond-token value slashed (stablePaid + value of projectPaid) and paid to the taker
    event QuoteDefaulted(
        bytes32 indexed digest,
        bytes32 indexed rfqId,
        address indexed maker,
        address taker,
        uint256 penalty,
        uint256 stablePaid,
        uint256 projectPaid
    );
    event NonceInvalidated(address indexed maker, uint256 nonce);
    event NoncesInvalidated(address indexed maker, uint256 word, uint256 mask);
    event MinNonceSet(address indexed maker, uint256 minNonce);
    event BaseTokenSet(address indexed token, bool allowed, uint8 decimals);
    event QuoteTokenSet(address indexed token, bool allowed);
    event ParamsSet(uint16 feeBps, uint16 slashBps, uint32 maxQuoteTtl);
    event ModulesSet(address priceGuard, address feeCollector, address hooks);

    constructor(
        address admin,
        address guardian,
        address registry_,
        address priceGuard_,
        address feeCollector_,
        address hooks_,
        uint16 feeBps_,
        uint16 slashBps_,
        uint32 maxQuoteTtl_
    ) BlockroomBase(admin, guardian) EIP712("Blockroom Settlement", "1") {
        if (registry_ == address(0)) revert ZeroAddress();
        registry = IMakerRegistry(registry_);
        _setModules(priceGuard_, feeCollector_, hooks_);
        _setParams(feeBps_, slashBps_, maxQuoteTtl_);
    }

    // ------------------------------------------------------------------ admin

    function setModules(address priceGuard_, address feeCollector_, address hooks_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setModules(priceGuard_, feeCollector_, hooks_);
    }

    function setParams(uint16 feeBps_, uint16 slashBps_, uint32 maxQuoteTtl_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setParams(feeBps_, slashBps_, maxQuoteTtl_);
    }

    function setBaseToken(address token, bool allowed, uint8 decimals) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (decimals > 36) revert InvalidParam();
        baseTokenDecimalsPlusOne[token] = allowed ? decimals + 1 : 0;
        emit BaseTokenSet(token, allowed, decimals);
    }

    function setQuoteToken(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        quoteTokenAllowed[token] = allowed;
        emit QuoteTokenSet(token, allowed);
    }

    // ------------------------------------------------------------------ maker

    function invalidateNonce(uint256 nonce) external {
        _useNonce(msg.sender, nonce);
        emit NonceInvalidated(msg.sender, nonce);
    }

    function invalidateNonces(uint256 word, uint256 mask) external {
        nonceBitmap[msg.sender][word] |= mask;
        emit NoncesInvalidated(msg.sender, word, mask);
    }

    /// @notice Bulk-cancel: every quote with nonce < `newMin` becomes unfillable.
    function setMinNonce(uint256 newMin) external {
        if (newMin <= minNonce[msg.sender]) revert MinNonceDecrease();
        minNonce[msg.sender] = newMin;
        emit MinNonceSet(msg.sender, newMin);
    }

    // ------------------------------------------------------------------ taker

    /// @notice Fill `baseAmount` of a signed quote.
    /// @dev Strict checks-effects-interactions:
    ///      1. checks  - quote/signature/maker eligibility, price guard, and that BOTH legs are deliverable
    ///                   (balance + allowance). An undeliverable taker leg reverts (no free griefing of makers);
    ///                   an undeliverable maker leg is a default.
    ///      2. effects - fill accounting and nonce burn (always burned on default).
    ///      3. interactions - either the slash (default) or the direct transfers maker<->taker + fee.
    /// @return quoteAmount quote-token notional (before fees)
    /// @return fee protocol fee charged to the taker in quote token
    /// @return defaulted true if the maker could not deliver and was slashed instead
    function fill(Quote calldata q, bytes calldata signature, uint256 baseAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 quoteAmount, uint256 fee, bool defaulted)
    {
        bytes32 digest = hashQuote(q);
        uint256 baseUnit = _validate(q, digest, signature, baseAmount);
        uint256 mid = priceGuard.checkPrice(q.baseToken, q.quoteToken, q.price);

        bool makerSells = q.side == uint8(Side.MakerSells);
        // Round notional in the maker's favour.
        quoteAmount = Math.mulDiv(
            baseAmount, q.price, baseUnit, makerSells ? Math.Rounding.Ceil : Math.Rounding.Floor
        );
        if (quoteAmount == 0) revert InvalidAmount();
        fee = _fee(msg.sender, quoteAmount);

        // ---- checks: deliverability of both legs (reverts if the taker can't pay)
        if (!_legsDeliverable(q, makerSells, baseAmount, quoteAmount + (makerSells ? fee : 0))) {
            _default(q, digest, quoteAmount);
            return (quoteAmount, 0, true);
        }

        // ---- effects
        uint256 newFilled = filled[digest] + baseAmount;
        filled[digest] = newFilled;
        if (newFilled == q.size || q.tif != uint8(TimeInForce.GTD)) _useNonce(q.maker, q.nonce);

        // ---- interactions (direct transfers, nothing is custodied by Settlement)
        _transferLegs(q, makerSells, baseAmount, quoteAmount, fee);
        _emitFilled(q, digest, baseAmount, quoteAmount, fee, mid);
    }

    // ------------------------------------------------------------------ views

    /// @dev Every Quote member is a static 32-byte ABI word, so abi.encode(TYPEHASH, q) is exactly
    ///      the EIP-712 `encodeData` (typeHash || enc(member_1) || ... || enc(member_n)).
    function hashQuote(Quote calldata q) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(QUOTE_TYPEHASH, q)));
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function isNonceUsed(address maker, uint256 nonce) public view returns (bool) {
        return nonceBitmap[maker][nonce >> 8] & (1 << (nonce & 0xff)) != 0 || nonce < minNonce[maker];
    }

    function remaining(Quote calldata q) external view returns (uint256) {
        if (isNonceUsed(q.maker, q.nonce)) return 0;
        return q.size - filled[hashQuote(q)];
    }

    function quoteFee(address taker, uint256 quoteAmount) external view returns (uint256) {
        return _fee(taker, quoteAmount);
    }

    // --------------------------------------------------------------- internal

    function _validate(Quote calldata q, bytes32 digest, bytes calldata signature, uint256 baseAmount)
        internal
        view
        returns (uint256 baseUnit)
    {
        if (q.side > uint8(Side.MakerBuys) || q.tif > uint8(TimeInForce.FOK) || q.size == 0 || q.minFill > q.size) {
            revert InvalidQuote();
        }
        uint8 dp1 = baseTokenDecimalsPlusOne[q.baseToken];
        if (dp1 == 0 || !quoteTokenAllowed[q.quoteToken]) revert TokenNotAllowed();
        if (block.timestamp > q.expiry) revert QuoteExpired();
        if (q.expiry - block.timestamp > maxQuoteTtl) revert QuoteTtlTooLong();
        if (q.taker != address(0) && q.taker != msg.sender) revert WrongTaker();
        if (q.maker == msg.sender) revert SelfTrade();
        if (isNonceUsed(q.maker, q.nonce)) revert NonceUsed();
        if (!_isValidMakerSignature(q.maker, digest, signature)) revert BadSignature();
        if (!registry.canQuote(q.maker)) revert MakerNotEligible();
        _requireCompliant(msg.sender, Actions.RFQ_TAKE);
        _requireCompliant(q.maker, Actions.RFQ_MAKE);

        if (baseAmount == 0) revert InvalidAmount();
        uint256 rem = q.size - filled[digest];
        if (baseAmount > rem) revert ExceedsRemaining();
        if (q.tif == uint8(TimeInForce.FOK) && baseAmount != q.size) revert BelowMinFill();
        if (baseAmount < q.minFill && baseAmount != rem) revert BelowMinFill();
        baseUnit = 10 ** (dp1 - 1);
    }

    function _emitFilled(
        Quote calldata q,
        bytes32 digest,
        uint256 baseAmount,
        uint256 quoteAmount,
        uint256 fee,
        uint256 mid
    ) internal {
        emit QuoteFilled(
            digest, q.rfqId, q.maker, msg.sender, q.baseToken, q.quoteToken, q.side, baseAmount, quoteAmount, fee, mid
        );
    }

    function _fee(address taker, uint256 quoteAmount) internal view returns (uint256) {
        uint256 bps = feeBps;
        if (bps == 0) return 0;
        uint256 discount = hooks.feeDiscountBps(taker);
        if (discount > BPS) discount = BPS;
        return Math.mulDiv(quoteAmount, bps * (BPS - discount), BPS * BPS);
    }

    /// @dev ECDSA first, then ERC-1271. OpenZeppelin's SignatureChecker skips ECDSA whenever the signer has code,
    ///      which rejects EIP-7702-delegated EOAs ("smart EOAs", live on Robinhood Chain) whose delegate does not
    ///      implement ERC-1271 - even though the EOA's own key is the account's ultimate authority. A pure contract
    ///      wallet has no private key, so ECDSA can never recover to its address; it is verified via ERC-1271.
    function _isValidMakerSignature(address maker, bytes32 digest, bytes calldata signature)
        internal
        view
        returns (bool)
    {
        (address recovered, ECDSA.RecoverError err, bytes32 errArg) = ECDSA.tryRecover(digest, signature);
        if (err == ECDSA.RecoverError.NoError && errArg == bytes32(0) && recovered == maker) return true;
        return maker.code.length > 0 && SignatureChecker.isValidERC1271SignatureNow(maker, digest, signature);
    }

    /// @dev Returns whether the maker can deliver; reverts if the taker can't (no free griefing of makers).
    ///      `takerQuoteOwed` includes the fee when the taker pays quote token.
    function _legsDeliverable(Quote calldata q, bool makerSells, uint256 baseAmount, uint256 takerQuoteOwed)
        internal
        view
        returns (bool)
    {
        if (makerSells) {
            if (!_canDeliver(q.quoteToken, msg.sender, takerQuoteOwed)) revert TakerCannotPay();
            return _canDeliver(q.baseToken, q.maker, baseAmount);
        }
        if (!_canDeliver(q.baseToken, msg.sender, baseAmount)) revert TakerCannotPay();
        return _canDeliver(q.quoteToken, q.maker, takerQuoteOwed);
    }

    /// @dev Default path: burn the quote (even GTD - it can never be retried), then slash and pay the taker.
    function _default(Quote calldata q, bytes32 digest, uint256 quoteAmount) internal {
        _useNonce(q.maker, q.nonce);
        uint256 penalty = Math.mulDiv(quoteAmount, slashBps, BPS);
        uint256 cap = registry.slashableValue(q.maker);
        if (penalty > cap) penalty = cap;
        uint256 stablePaid = 0;
        uint256 projectPaid = 0;
        if (penalty > 0) (stablePaid, projectPaid) = registry.slash(q.maker, msg.sender, penalty);
        emit QuoteDefaulted(digest, q.rfqId, q.maker, msg.sender, penalty, stablePaid, projectPaid);
    }

    /// @dev `q.maker` as `from` is authorised by the maker's EIP-712 signature over this exact quote, verified in
    ///      `_validate` (EOA or ERC-1271) together with nonce/expiry/fill caps - the standard signed-order pattern.
    // slither-disable-start arbitrary-send-erc20
    function _transferLegs(Quote calldata q, bool makerSells, uint256 baseAmount, uint256 quoteAmount, uint256 fee)
        internal
    {
        IERC20 base = IERC20(q.baseToken);
        IERC20 quoteT = IERC20(q.quoteToken);
        if (makerSells) {
            base.safeTransferFrom(q.maker, msg.sender, baseAmount);
            quoteT.safeTransferFrom(msg.sender, q.maker, quoteAmount);
            if (fee > 0) quoteT.safeTransferFrom(msg.sender, address(feeCollector), fee);
        } else {
            base.safeTransferFrom(msg.sender, q.maker, baseAmount);
            quoteT.safeTransferFrom(q.maker, msg.sender, quoteAmount - fee);
            if (fee > 0) quoteT.safeTransferFrom(q.maker, address(feeCollector), fee);
        }
        if (fee > 0) feeCollector.notifyFee(q.quoteToken, fee);
    }
    // slither-disable-end arbitrary-send-erc20

    /// @dev Both balance and allowance cover `amount` (view calls only - no state changes, no transfers).
    function _canDeliver(address token, address owner, uint256 amount) internal view returns (bool) {
        return IERC20(token).balanceOf(owner) >= amount && IERC20(token).allowance(owner, address(this)) >= amount;
    }

    function _useNonce(address maker, uint256 nonce) internal {
        uint256 bit = 1 << (nonce & 0xff);
        uint256 word = nonce >> 8;
        uint256 flipped = nonceBitmap[maker][word] ^= bit;
        if (flipped & bit == 0) revert NonceUsed();
    }

    function _setModules(address priceGuard_, address feeCollector_, address hooks_) internal {
        if (priceGuard_ == address(0) || feeCollector_ == address(0) || hooks_ == address(0)) revert ZeroAddress();
        priceGuard = IPriceGuard(priceGuard_);
        feeCollector = IFeeCollector(feeCollector_);
        hooks = IProjectTokenHooks(hooks_);
        emit ModulesSet(priceGuard_, feeCollector_, hooks_);
    }

    function _setParams(uint16 feeBps_, uint16 slashBps_, uint32 maxQuoteTtl_) internal {
        if (feeBps_ > MAX_FEE_BPS || slashBps_ > MAX_SLASH_BPS || maxQuoteTtl_ == 0 || maxQuoteTtl_ > 1 days) {
            revert InvalidParam();
        }
        feeBps = feeBps_;
        slashBps = slashBps_;
        maxQuoteTtl = maxQuoteTtl_;
        emit ParamsSet(feeBps_, slashBps_, maxQuoteTtl_);
    }
}
