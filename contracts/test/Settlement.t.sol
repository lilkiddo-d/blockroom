// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./utils/BaseTest.sol";
import {Settlement} from "../src/Settlement.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {BlockroomBase} from "../src/base/BlockroomBase.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {MockSmartWallet, FalseReturnERC20, FeeOnTransferERC20, MockAggregator} from "./utils/Mocks.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract SettlementTest is BaseTest {
    uint8 constant SELLS = 0;
    uint8 constant BUYS = 1;

    function setUp() public override {
        super.setUp();
        _registerMaker(maker, MIN_BOND);
        _fundAndApprove(aapl, maker, address(settlement), 1_000e18);
        _fundAndApprove(usdg, maker, address(settlement), 1_000_000e6);
        _fundAndApprove(usdg, taker, address(settlement), 1_000_000e6);
        _fundAndApprove(aapl, taker, address(settlement), 1_000e18);
    }

    // ------------------------------------------------------------- happy path

    function test_fill_makerSells() public {
        Settlement.Quote memory q = _quote(SELLS, 341e6, 100e18, 1);
        bytes memory sig = _sign(makerPk, q);
        uint256 tBefore = usdg.balanceOf(taker);
        vm.prank(taker);
        (uint256 qa, uint256 fee, bool defaulted) = settlement.fill(q, sig, 100e18);
        assertFalse(defaulted);
        assertEq(qa, 34_100e6);
        assertEq(fee, (34_100e6 * 5) / 10_000);
        assertEq(aapl.balanceOf(taker), 1_100e18);
        assertEq(tBefore - usdg.balanceOf(taker), qa + fee);
        assertEq(usdg.balanceOf(maker), 1_000_000e6 + qa);
        assertEq(usdg.balanceOf(address(fc)), fee);
        assertEq(fc.treasuryAccrued(address(usdg)), fee);
        assertEq(settlement.filled(settlement.hashQuote(q)), 100e18);
        assertTrue(settlement.isNonceUsed(maker, 1));
        assertEq(settlement.remaining(q), 0);
    }

    function test_fill_makerBuys() public {
        Settlement.Quote memory q = _quote(BUYS, 339e6, 10e18, 2);
        bytes memory sig = _sign(makerPk, q);
        uint256 tBefore = usdg.balanceOf(taker);
        vm.prank(taker);
        (uint256 qa, uint256 fee,) = settlement.fill(q, sig, 10e18);
        assertEq(qa, 3_390e6);
        assertEq(usdg.balanceOf(taker) - tBefore, qa - fee);
        assertEq(aapl.balanceOf(maker), 1_010e18);
    }

    function test_fill_partialGTD_thenRest() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 100e18, 3);
        q.minFill = 10e18;
        bytes memory sig = _sign(makerPk, q);
        vm.startPrank(taker);
        settlement.fill(q, sig, 40e18);
        assertEq(settlement.remaining(q), 60e18);
        assertFalse(settlement.isNonceUsed(maker, 3));
        settlement.fill(q, sig, 60e18);
        vm.stopPrank();
        assertTrue(settlement.isNonceUsed(maker, 3));
        assertEq(aapl.balanceOf(taker), 1_100e18);
    }

    function test_fill_remainderBelowMinFillAllowed() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 100e18, 4);
        q.minFill = 30e18;
        bytes memory sig = _sign(makerPk, q);
        vm.startPrank(taker);
        settlement.fill(q, sig, 80e18);
        settlement.fill(q, sig, 20e18); // < minFill but equals remaining
        vm.stopPrank();
    }

    function test_revert_belowMinFill() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 100e18, 5);
        q.minFill = 30e18;
        bytes memory sig = _sign(makerPk, q);
        vm.prank(taker);
        vm.expectRevert(Settlement.BelowMinFill.selector);
        settlement.fill(q, sig, 29e18);
    }

    function test_IOC_singleFill() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 100e18, 6);
        q.tif = 1;
        bytes memory sig = _sign(makerPk, q);
        vm.startPrank(taker);
        settlement.fill(q, sig, 50e18);
        vm.expectRevert(Settlement.NonceUsed.selector);
        settlement.fill(q, sig, 10e18);
        vm.stopPrank();
    }

    function test_FOK_requiresFullSize() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 100e18, 7);
        q.tif = 2;
        bytes memory sig = _sign(makerPk, q);
        vm.startPrank(taker);
        vm.expectRevert(Settlement.BelowMinFill.selector);
        settlement.fill(q, sig, 99e18);
        settlement.fill(q, sig, 100e18);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- replay

    function test_revert_replayFullFill() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 8);
        bytes memory sig = _sign(makerPk, q);
        vm.startPrank(taker);
        settlement.fill(q, sig, 10e18);
        vm.expectRevert(Settlement.NonceUsed.selector);
        settlement.fill(q, sig, 10e18);
        vm.stopPrank();
    }

    function test_revert_exceedsRemaining() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 9);
        bytes memory sig = _sign(makerPk, q);
        vm.startPrank(taker);
        settlement.fill(q, sig, 6e18);
        vm.expectRevert(Settlement.ExceedsRemaining.selector);
        settlement.fill(q, sig, 6e18);
        vm.stopPrank();
    }

    function test_revert_sameNonceDifferentQuote() public {
        Settlement.Quote memory q1 = _quote(SELLS, 340e6, 10e18, 10);
        Settlement.Quote memory q2 = _quote(SELLS, 340e6, 20e18, 10);
        bytes memory s1 = _sign(makerPk, q1);
        bytes memory s2 = _sign(makerPk, q2);
        vm.startPrank(taker);
        settlement.fill(q1, s1, 10e18);
        vm.expectRevert(Settlement.NonceUsed.selector);
        settlement.fill(q2, s2, 20e18);
        vm.stopPrank();
    }

    function test_cancel_singleNonce() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 11);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(maker);
        settlement.invalidateNonce(11);
        vm.prank(taker);
        vm.expectRevert(Settlement.NonceUsed.selector);
        settlement.fill(q, sig, 1e18);
        assertEq(settlement.remaining(q), 0);
        vm.prank(maker);
        vm.expectRevert(Settlement.NonceUsed.selector);
        settlement.invalidateNonce(11);
    }

    function test_cancel_bitmapAndMinNonce() public {
        vm.startPrank(maker);
        settlement.invalidateNonces(0, 1 << 12);
        assertTrue(settlement.isNonceUsed(maker, 12));
        settlement.setMinNonce(100);
        assertTrue(settlement.isNonceUsed(maker, 99));
        assertFalse(settlement.isNonceUsed(maker, 100));
        vm.expectRevert(Settlement.MinNonceDecrease.selector);
        settlement.setMinNonce(100);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- validation

    function test_revert_expired() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 20);
        bytes memory sig = _sign(makerPk, q);
        vm.warp(q.expiry + 1);
        vm.prank(taker);
        vm.expectRevert(Settlement.QuoteExpired.selector);
        settlement.fill(q, sig, 1e18);
    }

    function test_revert_ttlTooLong() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 21);
        q.expiry = uint64(block.timestamp + 11 minutes);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(taker);
        vm.expectRevert(Settlement.QuoteTtlTooLong.selector);
        settlement.fill(q, sig, 1e18);
    }

    function test_revert_wrongTaker() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 22);
        q.taker = makeAddr("other");
        bytes memory sig = _sign(makerPk, q);
        vm.prank(taker);
        vm.expectRevert(Settlement.WrongTaker.selector);
        settlement.fill(q, sig, 1e18);
    }

    function test_designatedTaker() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 23);
        q.taker = taker;
        bytes memory sig = _sign(makerPk, q);
        vm.prank(taker);
        settlement.fill(q, sig, 1e18);
    }

    function test_revert_selfTrade() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 24);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(maker);
        vm.expectRevert(Settlement.SelfTrade.selector);
        settlement.fill(q, sig, 1e18);
    }

    function test_revert_badSignature() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 25);
        bytes memory sig = _sign(0xBEEF, q);
        vm.prank(taker);
        vm.expectRevert(Settlement.BadSignature.selector);
        settlement.fill(q, sig, 1e18);
    }

    function test_revert_tamperedQuote() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 26);
        bytes memory sig = _sign(makerPk, q);
        q.price = 336e6;
        vm.prank(taker);
        vm.expectRevert(Settlement.BadSignature.selector);
        settlement.fill(q, sig, 1e18);
    }

    function test_revert_invalidQuoteShapes() public {
        Settlement.Quote memory q = _quote(2, 340e6, 10e18, 27);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(taker);
        vm.expectRevert(Settlement.InvalidQuote.selector);
        settlement.fill(q, sig, 1e18);

        q = _quote(SELLS, 340e6, 10e18, 28);
        q.minFill = 11e18;
        sig = _sign(makerPk, q);
        vm.prank(taker);
        vm.expectRevert(Settlement.InvalidQuote.selector);
        settlement.fill(q, sig, 1e18);

        q = _quote(SELLS, 340e6, 10e18, 29);
        sig = _sign(makerPk, q);
        vm.prank(taker);
        vm.expectRevert(Settlement.InvalidAmount.selector);
        settlement.fill(q, sig, 0);
    }

    function test_revert_tokenNotAllowed() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 30);
        q.baseToken = address(proj);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(taker);
        vm.expectRevert(Settlement.TokenNotAllowed.selector);
        settlement.fill(q, sig, 1e18);
    }

    function test_revert_dustNotional() public {
        Settlement.Quote memory q = _quote(BUYS, 340e6, 10e18, 31);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(taker);
        vm.expectRevert(Settlement.InvalidAmount.selector);
        settlement.fill(q, sig, 1); // floor(1 * 340e6 / 1e18) = 0
    }

    function test_revert_makerNotEligible() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 32);
        q.maker = makeAddr("unregistered");
        bytes memory sig = _sign(makerPk, q);
        vm.prank(taker);
        vm.expectRevert(Settlement.BadSignature.selector);
        settlement.fill(q, sig, 1e18);

        vm.prank(guardian);
        registry.setSuspended(maker, true);
        q = _quote(SELLS, 340e6, 10e18, 33);
        sig = _sign(makerPk, q);
        vm.prank(taker);
        vm.expectRevert(Settlement.MakerNotEligible.selector);
        settlement.fill(q, sig, 1e18);
    }

    function test_revert_paused() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 34);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(guardian);
        settlement.pause();
        vm.prank(taker);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        settlement.fill(q, sig, 1e18);
        vm.prank(guardian);
        settlement.unpause();
        vm.prank(taker);
        settlement.fill(q, sig, 1e18);
    }

    // ------------------------------------------------------------ price guard

    function test_revert_outsideGuard() public {
        Settlement.Quote memory q = _quote(SELLS, 344e6, 10e18, 40); // +1.18% vs 340 mid, band 1%
        bytes memory sig = _sign(makerPk, q);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(PriceGuard.PriceOutsideGuard.selector, 344e6, MID, 100));
        settlement.fill(q, sig, 1e18);
    }

    function test_staleQuoteAfterMarketMove() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 41);
        bytes memory sig = _sign(makerPk, q);
        aaplFeed.set(350e8); // market rallies ~2.9%: maker protected from being picked off
        vm.prank(taker);
        vm.expectRevert();
        settlement.fill(q, sig, 1e18);
    }

    function test_revert_staleOracle() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 42);
        aaplFeed.setWithTime(int256(AAPL_USD), block.timestamp - 2 days);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(taker);
        vm.expectRevert();
        settlement.fill(q, sig, 1e18);
    }

    // -------------------------------------------------------------- defaults

    function test_default_makerSells_insufficientBalance_slashes() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 100e18, 50);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(maker);
        aapl.transfer(address(0xdead), 1_000e18); // last-look: maker pulls inventory
        uint256 tUsdg = usdg.balanceOf(taker);
        vm.prank(taker);
        (uint256 qa, uint256 fee, bool defaulted) = settlement.fill(q, sig, 100e18);
        assertTrue(defaulted);
        assertEq(fee, 0);
        uint256 penalty = (qa * 100) / 10_000; // slashBps = 1%
        assertEq(usdg.balanceOf(taker), tUsdg + penalty, "taker refunded + compensated");
        assertEq(aapl.balanceOf(taker), 1_000e18);
        assertEq(registry.makerInfo(maker).stableBond, MIN_BOND - penalty);
        assertEq(registry.makerInfo(maker).defaults, 1);
        assertTrue(settlement.isNonceUsed(maker, 50));
    }

    function test_default_makerBuys_revokedApproval_slashes() public {
        Settlement.Quote memory q = _quote(BUYS, 340e6, 100e18, 51);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(maker);
        usdg.approve(address(settlement), 0);
        vm.prank(taker);
        (,, bool defaulted) = settlement.fill(q, sig, 100e18);
        assertTrue(defaulted);
        assertEq(aapl.balanceOf(taker), 1_000e18, "taker base refunded");
        assertEq(usdg.balanceOf(taker), 1_000_000e6 + 340e6);
    }

    function test_default_GTD_partial_burnsQuote() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 100e18, 52);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(maker);
        aapl.approve(address(settlement), 0);
        vm.prank(taker);
        settlement.fill(q, sig, 10e18);
        assertTrue(settlement.isNonceUsed(maker, 52));
    }

    function test_default_penaltyCappedAtBond() public {
        vm.prank(admin);
        settlement.setParams(5, 2_000, 10 minutes); // 20% slash
        Settlement.Quote memory q = _quote(SELLS, 340e6, 1_000e18, 53); // 340k notional -> 68k penalty
        bytes memory sig = _sign(makerPk, q);
        vm.prank(maker);
        aapl.approve(address(settlement), 0);
        uint256 before = usdg.balanceOf(taker);
        vm.prank(taker);
        settlement.fill(q, sig, 1_000e18);
        assertEq(usdg.balanceOf(taker) - before, MIN_BOND);
        assertEq(registry.slashableValue(maker), 0);
    }

    function test_default_takerCannotGriefWithoutFunds() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 100e18, 54);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(maker);
        aapl.approve(address(settlement), 0);
        address broke = makeAddr("broke");
        vm.prank(broke);
        vm.expectRevert();
        settlement.fill(q, sig, 100e18);
        assertEq(registry.makerInfo(maker).defaults, 0);
    }

    function test_default_falseReturningToken() public {
        FalseReturnERC20 f = new FalseReturnERC20();
        MockAggregator feed = new MockAggregator(8, 340e8);
        vm.startPrank(admin);
        oracle.setFeed(address(f), address(feed), address(0), 1 days, 0, 0, 18, false);
        settlement.setBaseToken(address(f), true, 18);
        vm.stopPrank();
        Settlement.Quote memory q = _quote(SELLS, 340e6, 1e18, 55);
        q.baseToken = address(f);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(taker);
        (,, bool defaulted) = settlement.fill(q, sig, 1e18);
        assertTrue(defaulted);
    }

    function test_revert_takerCannotPay() public {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 100e18, 56);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(taker);
        usdg.approve(address(settlement), 1);
        vm.prank(taker);
        vm.expectRevert(Settlement.TakerCannotPay.selector);
        settlement.fill(q, sig, 100e18);
        // the quote is untouched and still fillable
        assertEq(settlement.remaining(q), 100e18);
    }

    function test_settlementNeverCustodies() public {
        Settlement.Quote memory q = _quote(BUYS, 340e6, 10e18, 57);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(taker);
        settlement.fill(q, sig, 10e18);
        assertEq(usdg.balanceOf(address(settlement)), 0);
        assertEq(aapl.balanceOf(address(settlement)), 0);
    }

    // ------------------------------------------------------- smart wallet maker

    function test_erc1271Maker() public {
        MockSmartWallet w = new MockSmartWallet(maker);
        _registerMaker(address(w), MIN_BOND);
        aapl.mint(address(w), 10e18);
        vm.prank(maker);
        w.call(address(aapl), abi.encodeCall(aapl.approve, (address(settlement), type(uint256).max)));
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 1);
        q.maker = address(w);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(taker);
        settlement.fill(q, sig, 10e18);
        assertEq(aapl.balanceOf(address(w)), 0);
    }

    /// @dev EIP-7702 "smart EOA" maker: the address carries delegation code (0xef0100 || delegate) whose delegate
    ///      does not implement ERC-1271. The EOA's own ECDSA signature must still be accepted.
    function test_eip7702DelegatedMaker_ecdsaAccepted() public {
        address delegate = address(new FalseReturnERC20()); // any contract without isValidSignature
        vm.etch(maker, abi.encodePacked(hex"ef0100", delegate));
        assertGt(maker.code.length, 0);
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 61);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(taker);
        (,, bool defaulted) = settlement.fill(q, sig, 10e18);
        assertFalse(defaulted);
        // a forged signature is still rejected, and the 1271 fallback doesn't rescue it
        Settlement.Quote memory q2 = _quote(SELLS, 340e6, 10e18, 62);
        bytes memory bad = _sign(0xBEEF, q2);
        vm.prank(taker);
        vm.expectRevert(Settlement.BadSignature.selector);
        settlement.fill(q2, bad, 10e18);
    }

    function test_erc1271Maker_rejectsWrongSigner() public {
        MockSmartWallet w = new MockSmartWallet(maker);
        _registerMaker(address(w), MIN_BOND);
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 63);
        q.maker = address(w);
        bytes memory sig = _sign(0xBEEF, q);
        vm.prank(taker);
        vm.expectRevert(Settlement.BadSignature.selector);
        settlement.fill(q, sig, 1e18);
    }

    // ------------------------------------------------------------ compliance

    function test_compliance_gate() public {
        vm.prank(admin);
        compliance.setEnabled(true);
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 60);
        bytes memory sig = _sign(makerPk, q);
        bytes32 action = compliance.ACTION_RFQ_TAKE();
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(BlockroomBase.NotCompliant.selector, taker, action));
        settlement.fill(q, sig, 1e18);

        address[] memory list = new address[](2);
        list[0] = taker;
        list[1] = maker;
        vm.prank(complianceOp);
        compliance.setAllowed(list, true);
        vm.prank(taker);
        settlement.fill(q, sig, 1e18);
    }

    // ------------------------------------------------------- token discounts

    function test_feeDiscount_withProjectTokenStake() public {
        _enableProjectToken();
        proj.mint(taker, 100_000e18);
        vm.startPrank(taker);
        proj.approve(address(fc), type(uint256).max);
        fc.stake(100_000e18);
        vm.stopPrank();
        assertEq(hooks.feeDiscountBps(taker), 5_000);
        assertEq(settlement.quoteFee(taker, 10_000e6), 2.5e6);

        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 70);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(taker);
        (, uint256 fee,) = settlement.fill(q, sig, 10e18);
        assertEq(fee, (3_400e6 * 5 * 5_000) / 1e8);
        // 30% of fee to stakers (taker is the only staker)
        assertApproxEqAbs(fc.claimable(taker, address(usdg)), (fee * 3_000) / 10_000, 1);
    }

    function test_feeZero() public {
        vm.prank(admin);
        settlement.setParams(0, 100, 10 minutes);
        assertEq(settlement.quoteFee(taker, 1e12), 0);
        Settlement.Quote memory q = _quote(SELLS, 340e6, 10e18, 71);
        bytes memory sig = _sign(makerPk, q);
        vm.prank(taker);
        (, uint256 fee,) = settlement.fill(q, sig, 10e18);
        assertEq(fee, 0);
    }

    // ----------------------------------------------------------------- admin

    function test_admin_params() public {
        vm.startPrank(admin);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        settlement.setParams(101, 0, 1);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        settlement.setParams(1, 2_001, 1);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        settlement.setParams(1, 1, 0);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        settlement.setParams(1, 1, 1 days + 1);
        vm.expectRevert(BlockroomBase.ZeroAddress.selector);
        settlement.setModules(address(0), address(fc), address(hooks));
        settlement.setModules(address(guard), address(fc), address(hooks));
        vm.expectRevert(BlockroomBase.ZeroAddress.selector);
        settlement.setBaseToken(address(0), true, 18);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        settlement.setBaseToken(address(aapl), true, 37);
        settlement.setBaseToken(address(aapl), false, 18);
        assertEq(settlement.baseTokenDecimalsPlusOne(address(aapl)), 0);
        vm.expectRevert(BlockroomBase.ZeroAddress.selector);
        settlement.setQuoteToken(address(0), true);
        vm.stopPrank();
        vm.expectRevert();
        settlement.setParams(1, 1, 1);
        vm.expectRevert(BlockroomBase.ZeroAddress.selector);
        new Settlement(admin, guardian, address(0), address(guard), address(fc), address(hooks), 5, 100, 600);
        assertTrue(settlement.domainSeparator() != bytes32(0));
    }

    /// @dev hashQuote must equal the textbook EIP-712 encoding used by off-chain signers (viem/ethers).
    function test_hashQuote_matchesExplicitEip712() public view {
        Settlement.Quote memory q = _quote(SELLS, 340e6, 7e18, 77);
        q.taker = taker;
        q.minFill = 1e18;
        q.tif = 2;
        // field-by-field encoding (split in two halves only to stay within the unoptimized stack limit)
        bytes memory head =
            abi.encode(settlement.QUOTE_TYPEHASH(), q.rfqId, q.maker, q.taker, q.baseToken, q.quoteToken, q.side);
        bytes memory tail = abi.encode(q.tif, q.price, q.size, q.minFill, q.nonce, q.expiry);
        bytes32 structHash = keccak256(bytes.concat(head, tail));
        bytes32 expected = keccak256(abi.encodePacked("\x19\x01", settlement.domainSeparator(), structHash));
        assertEq(settlement.hashQuote(q), expected);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Blockroom Settlement"),
                keccak256("1"),
                block.chainid,
                address(settlement)
            )
        );
        assertEq(settlement.domainSeparator(), domain);
    }

    // ------------------------------------------------------------------ fuzz

    /// @dev A signed quote can never be filled for more than its size, regardless of fill sequence.
    function testFuzz_neverOverfill(uint96 size, uint96[4] memory amounts) public {
        size = uint96(bound(size, 1e15, 500e18));
        Settlement.Quote memory q = _quote(SELLS, 340e6, size, 999);
        bytes memory sig = _sign(makerPk, q);
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            uint256 a = bound(amounts[i], 0, size);
            vm.prank(taker);
            try settlement.fill(q, sig, a) {
                total += a;
            } catch {}
        }
        assertLe(total, size);
        assertEq(settlement.filled(settlement.hashQuote(q)), total);
        // after a full fill nothing more is possible
        if (total == size) {
            vm.prank(taker);
            vm.expectRevert(Settlement.NonceUsed.selector);
            settlement.fill(q, sig, 1);
        }
    }

    /// @dev No fill settles outside the price guard band.
    function testFuzz_priceGuard(uint256 price, uint256 oraclePrice) public {
        oraclePrice = bound(oraclePrice, 1e8, 10_000e8);
        price = bound(price, 1, 20_000e6);
        aaplFeed.set(int256(oraclePrice));
        uint256 mid = oraclePrice / 100; // 8dp USD -> 6dp USDG
        Settlement.Quote memory q = _quote(SELLS, price, 1e18, 1000);
        bytes memory sig = _sign(makerPk, q);
        uint256 diff = price > mid ? price - mid : mid - price;
        bool inBand = diff * 10_000 <= mid * 100;
        vm.prank(taker);
        try settlement.fill(q, sig, 1e18) {
            assertTrue(inBand, "filled outside band");
        } catch {
            assertFalse(inBand, "in-band fill reverted");
        }
    }

    function testFuzz_notionalRoundsForMaker(uint256 amount, uint256 price) public {
        amount = bound(amount, 1e12, 1_000e18);
        price = bound(price, 337e6, 343e6);
        Settlement.Quote memory qs = _quote(SELLS, price, amount, 2000);
        Settlement.Quote memory qb = _quote(BUYS, price, amount, 2001);
        bytes memory ss = _sign(makerPk, qs);
        bytes memory sb = _sign(makerPk, qb);
        vm.startPrank(taker);
        (uint256 qaS,,) = settlement.fill(qs, ss, amount);
        (uint256 qaB,,) = settlement.fill(qb, sb, amount);
        vm.stopPrank();
        assertGe(qaS * 1e18, amount * price); // maker sells: ceil
        assertLe(qaB * 1e18, amount * price); // maker buys: floor
    }

    function _enableProjectToken() internal {
        vm.startPrank(admin);
        hooks.setProjectToken(address(proj));
        ProjectTokenHooks.Tier[] memory t = new ProjectTokenHooks.Tier[](2);
        t[0] = ProjectTokenHooks.Tier({minStake: 10_000e18, discountBps: 2_000});
        t[1] = ProjectTokenHooks.Tier({minStake: 100_000e18, discountBps: 5_000});
        hooks.setTiers(t);
        vm.stopPrank();
    }
}
