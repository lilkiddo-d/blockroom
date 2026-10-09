// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./utils/BaseTest.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {MarketClock} from "../src/MarketClock.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {BlockroomTimelock} from "../src/BlockroomTimelock.sol";
import {BlockroomBase} from "../src/base/BlockroomBase.sol";
import {MockAggregator} from "./utils/Mocks.sol";

contract OracleAdapterTest is BaseTest {
    function test_mid() public view {
        (uint256 p, uint256 t) = oracle.getMid(address(aapl), address(usdg));
        assertEq(p, MID);
        assertEq(t, block.timestamp);
        assertTrue(oracle.isSupported(address(aapl)));
        assertFalse(oracle.isSupported(address(proj)));
        assertEq(oracle.feedConfig(address(aapl)).feedDecimals, 8);
    }

    function test_mid_quoteOffPeg_withinTolerance() public {
        usdgFeed.set(0.99e8);
        (uint256 p,) = oracle.getMid(address(aapl), address(usdg));
        assertEq(p, (MID * 100) / 99);
    }

    function test_revert_depeg() public {
        usdgFeed.set(0.97e8);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.Depegged.selector, address(usdg), 0.97e18));
        oracle.getMid(address(aapl), address(usdg));
    }

    function test_revert_stale_future_negative() public {
        aaplFeed.setWithTime(340e8, block.timestamp - 1 days - 1);
        vm.expectRevert();
        oracle.getMid(address(aapl), address(usdg));
        aaplFeed.setWithTime(340e8, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidAnswer.selector, address(aaplFeed)));
        oracle.getMid(address(aapl), address(usdg));
        aaplFeed.set(-1);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidAnswer.selector, address(aaplFeed)));
        oracle.getMid(address(aapl), address(usdg));
        aaplFeed.setWithTime(340e8, 0);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidAnswer.selector, address(aaplFeed)));
        oracle.getMid(address(aapl), address(usdg));
    }

    function test_revert_unsupported_or_wrongRole() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.UnsupportedAsset.selector, address(proj)));
        oracle.getMid(address(proj), address(usdg));
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.UnsupportedAsset.selector, address(aapl)));
        oracle.getMid(address(aapl), address(aapl));
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.UnsupportedAsset.selector, address(usdg)));
        oracle.getMid(address(usdg), address(usdg));
    }

    function test_secondaryDeviation() public {
        MockAggregator sec = new MockAggregator(18, 341e18);
        vm.prank(admin);
        oracle.setFeed(address(aapl), address(aaplFeed), address(sec), 1 days, 50, 0, 18, false);
        oracle.getMid(address(aapl), address(usdg)); // 0.29% < 0.5%
        sec.set(345e18);
        vm.expectRevert();
        oracle.getMid(address(aapl), address(usdg));
    }

    function test_highDecimalFeed() public {
        MockAggregator f = new MockAggregator(20, 340e20);
        vm.prank(admin);
        oracle.setFeed(address(aapl), address(f), address(0), 1 days, 0, 0, 18, false);
        (uint256 p,) = oracle.getMid(address(aapl), address(usdg));
        assertEq(p, MID);
    }

    function test_sequencerFeed() public {
        MockAggregator seq = new MockAggregator(0, 0);
        vm.prank(admin);
        oracle.setSequencerUptimeFeed(address(seq), 1 hours);
        vm.expectRevert(OracleAdapter.GracePeriodNotOver.selector);
        oracle.getMid(address(aapl), address(usdg));
        vm.warp(block.timestamp + 2 hours);
        aaplFeed.set(340e8);
        usdgFeed.set(1e8);
        oracle.getMid(address(aapl), address(usdg));
        seq.set(1);
        vm.expectRevert(OracleAdapter.SequencerDown.selector);
        oracle.getMid(address(aapl), address(usdg));
    }

    function test_admin() public {
        vm.startPrank(admin);
        vm.expectRevert(BlockroomBase.ZeroAddress.selector);
        oracle.setFeed(address(0), address(aaplFeed), address(0), 1, 0, 0, 18, false);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        oracle.setFeed(address(aapl), address(aaplFeed), address(0), 0, 0, 0, 18, false);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        oracle.setFeed(address(aapl), address(aaplFeed), address(0), 1, 0, 0, 37, false);
        MockAggregator big = new MockAggregator(40, 1);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        oracle.setFeed(address(aapl), address(big), address(0), 1, 0, 0, 18, false);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        oracle.setFeed(address(aapl), address(aaplFeed), address(big), 1, 0, 0, 18, false);
        oracle.removeFeed(address(aapl));
        vm.stopPrank();
        assertFalse(oracle.isSupported(address(aapl)));
        vm.expectRevert();
        oracle.removeFeed(address(usdg));
    }
}

contract PriceGuardTest is BaseTest {
    function test_band() public {
        assertEq(guard.checkPrice(address(aapl), address(usdg), 343.4e6), MID);
        vm.expectRevert();
        guard.checkPrice(address(aapl), address(usdg), 343.41e6);
        vm.expectRevert(PriceGuard.ZeroPrice.selector);
        guard.checkPrice(address(aapl), address(usdg), 0);
        vm.prank(admin);
        guard.setAssetBand(address(aapl), 500);
        assertEq(guard.bandBps(address(aapl)), 500);
        guard.checkPrice(address(aapl), address(usdg), 355e6);
    }

    function test_admin() public {
        vm.startPrank(admin);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        guard.setDefaultBand(0);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        guard.setDefaultBand(1_001);
        guard.setDefaultBand(50);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        guard.setAssetBand(address(aapl), 1_001);
        vm.expectRevert(BlockroomBase.ZeroAddress.selector);
        guard.setOracle(address(0));
        guard.setOracle(address(oracle));
        vm.stopPrank();
        vm.expectRevert(BlockroomBase.ZeroAddress.selector);
        new PriceGuard(admin, guardian, address(0), 1);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        new PriceGuard(admin, guardian, address(oracle), 0);
    }

    function testFuzz_guardSymmetric(uint256 price) public view {
        price = bound(price, 1, 1_000e6);
        uint256 diff = price > MID ? price - MID : MID - price;
        try guard.checkPrice(address(aapl), address(usdg), price) returns (uint256 mid) {
            assertEq(mid, MID);
            assertLe(diff * 10_000, MID * 100);
        } catch {
            assertGt(diff * 10_000, MID * 100);
        }
    }
}

contract MarketClockTest is BaseTest {
    function test_regularSession_EDT() public view {
        assertTrue(clock.isOpenAt(1_791_293_400)); // 09:30 EDT
        assertFalse(clock.isOpenAt(1_791_293_340)); // 09:29
        assertTrue(clock.isOpenAt(1_791_316_740)); // 15:59
        assertFalse(clock.isOpenAt(1_791_316_800)); // 16:00
        assertTrue(clock.isOpen());
    }

    function test_regularSession_EST() public view {
        assertTrue(clock.isOpenAt(1_767_709_800)); // 2026-01-06 14:30 UTC = 09:30 EST
        assertFalse(clock.isOpenAt(1_767_709_740));
    }

    function test_weekend() public view {
        assertFalse(clock.isOpenAt(1_791_644_400)); // Saturday
        assertFalse(clock.isOpenAt(1_791_644_400 + 1 days)); // Sunday
    }

    function test_dstBoundaries() public view {
        assertTrue(clock.isUsDst(1_772_953_200)); // 2026-03-08 07:00 UTC
        assertFalse(clock.isUsDst(1_772_953_140));
        assertFalse(clock.isUsDst(1_793_512_800)); // 2026-11-01 06:00 UTC
        assertTrue(clock.isUsDst(1_793_512_740));
        assertFalse(clock.isUsDst(1_709_208_000)); // leap day 2024, EST
        assertFalse(clock.isUsDst(4_107_542_400)); // 2100-03-01
    }

    function test_holiday_and_earlyClose() public {
        uint256 thanksgiving = clock.etDayIndex(1_795_705_200);
        uint256 dayAfter = thanksgiving + 1;
        uint256[] memory days_ = new uint256[](2);
        uint16[] memory closes = new uint16[](2);
        days_[0] = thanksgiving;
        closes[0] = clock.CLOSED();
        days_[1] = dayAfter;
        closes[1] = 780; // 13:00
        vm.prank(calendar);
        clock.setSessionOverrides(days_, closes);
        assertFalse(clock.isOpenAt(1_795_705_200));
        assertTrue(clock.isOpenAt(1_795_705_200 + 1 days)); // 10:00 EST Friday
        assertFalse(clock.isOpenAt(1_795_705_200 + 1 days + 3 hours)); // 13:00 EST
    }

    function test_override_cannotExtend() public {
        uint256[] memory d = new uint256[](1);
        uint16[] memory c = new uint16[](1);
        d[0] = 1;
        c[0] = 961;
        vm.prank(calendar);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        clock.setSessionOverrides(d, c);
        uint16[] memory c2 = new uint16[](2);
        vm.prank(calendar);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        clock.setSessionOverrides(d, c2);
    }

    function test_forceClosed_and_hours() public {
        vm.prank(guardian);
        clock.setForceClosed(true);
        assertFalse(clock.isOpen());
        vm.prank(guardian);
        clock.setForceClosed(false);
        vm.startPrank(admin);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        clock.setSessionHours(600, 600);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        clock.setSessionHours(0, 1441);
        clock.setSessionHours(240, 1200); // 04:00 - 20:00 ET extended
        vm.stopPrank();
        assertTrue(clock.isOpenAt(1_791_316_800)); // 16:00 now open
    }

    function testFuzz_weekendsAlwaysClosed(uint256 ts) public view {
        ts = bound(ts, 0, 4_102_444_800);
        uint256 local = clock.toEasternTime(ts + 6 hours) ;
        uint256 wd = (local / 1 days + 4) % 7;
        if (wd == 0 || wd == 6) assertFalse(clock.isOpenAt(ts + 6 hours));
    }
}

contract ComplianceAndTimelockTest is BaseTest {
    function test_compliance() public {
        assertTrue(compliance.isAllowed(taker, keccak256("X")));
        vm.prank(admin);
        compliance.setEnabled(true);
        assertFalse(compliance.isAllowed(taker, keccak256("X")));
        address[] memory a = new address[](1);
        a[0] = taker;
        vm.prank(complianceOp);
        compliance.setAllowed(a, true);
        assertTrue(compliance.isAllowed(taker, keccak256("X")));
        address[] memory big = new address[](201);
        vm.prank(complianceOp);
        vm.expectRevert(ComplianceRegistry.BatchTooLarge.selector);
        compliance.setAllowed(big, true);
        vm.expectRevert(ComplianceRegistry.ZeroAddress.selector);
        new ComplianceRegistry(address(0), address(0));
        vm.expectRevert(BlockroomBase.ZeroAddress.selector);
        new MarketClock(address(0), address(0), address(0));
    }

    function test_timelock_floor_and_flow() public {
        address[] memory p = new address[](1);
        p[0] = admin;
        vm.expectRevert(BlockroomTimelock.DelayTooShort.selector);
        new BlockroomTimelock(1 days, p, p);
        BlockroomTimelock tl = new BlockroomTimelock(48 hours, p, p);
        assertEq(tl.getMinDelay(), 48 hours);

        // hand ProjectTokenHooks admin to the timelock, then set token through it
        vm.startPrank(admin);
        hooks.grantRole(hooks.DEFAULT_ADMIN_ROLE(), address(tl));
        hooks.renounceRole(hooks.DEFAULT_ADMIN_ROLE(), admin);
        bytes memory data = abi.encodeCall(hooks.setProjectToken, (address(proj)));
        tl.schedule(address(hooks), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.expectRevert();
        tl.execute(address(hooks), 0, data, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 48 hours);
        tl.execute(address(hooks), 0, data, bytes32(0), bytes32(0));
        vm.stopPrank();
        assertEq(hooks.projectToken(), address(proj));

        // delay can never drop below 48h, even via self-call
        vm.prank(address(tl));
        tl.updateDelay(1);
        assertEq(tl.getMinDelay(), 48 hours);
    }
}
