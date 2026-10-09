// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./utils/BaseTest.sol";
import {MakerRegistry} from "../src/MakerRegistry.sol";
import {BlockroomBase} from "../src/base/BlockroomBase.sol";

contract MakerRegistryTest is BaseTest {
    address slasher = makeAddr("slasher");
    address victim = makeAddr("victim");

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        registry.grantRole(registry.SLASHER_ROLE(), slasher);
        vm.stopPrank();
    }

    function test_register_and_bond() public {
        _registerMaker(maker, MIN_BOND);
        assertTrue(registry.canQuote(maker));
        assertEq(registry.bondValueOf(maker), MIN_BOND);
        vm.prank(maker);
        vm.expectRevert(MakerRegistry.AlreadyRegistered.selector);
        registry.register();
    }

    function test_belowMinBond_cannotQuote() public {
        _registerMaker(maker, MIN_BOND - 1);
        assertFalse(registry.canQuote(maker));
    }

    function test_unregistered_reverts() public {
        vm.startPrank(maker);
        vm.expectRevert(MakerRegistry.NotRegistered.selector);
        registry.depositBond(1);
        vm.expectRevert(MakerRegistry.NotRegistered.selector);
        registry.requestWithdrawal(1, 0);
        vm.stopPrank();
        vm.prank(guardian);
        vm.expectRevert(MakerRegistry.NotRegistered.selector);
        registry.setSuspended(maker, true);
        vm.prank(slasher);
        vm.expectRevert(MakerRegistry.NotRegistered.selector);
        registry.slash(maker, victim, 1);
    }

    function test_withdrawal_flow_staysSlashable() public {
        _registerMaker(maker, MIN_BOND);
        vm.startPrank(maker);
        vm.expectRevert(MakerRegistry.ZeroAmount.selector);
        registry.requestWithdrawal(0, 0);
        vm.expectRevert(MakerRegistry.InsufficientBond.selector);
        registry.requestWithdrawal(MIN_BOND + 1, 0);
        registry.requestWithdrawal(MIN_BOND, 0);
        vm.stopPrank();
        // anti last-look: pending is still slashable and still counts for quoting
        assertEq(registry.slashableValue(maker), MIN_BOND);
        assertTrue(registry.canQuote(maker));
        assertEq(registry.bondValueOf(maker), 0);

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(MakerRegistry.StillUnbonding.selector, uint64(block.timestamp + 2 days)));
        registry.completeWithdrawal();

        vm.prank(slasher);
        (uint256 s,) = registry.slash(maker, victim, 1_000e6);
        assertEq(s, 1_000e6);
        assertEq(usdg.balanceOf(victim), 1_000e6);

        vm.warp(block.timestamp + 2 days);
        vm.prank(maker);
        registry.completeWithdrawal();
        assertEq(usdg.balanceOf(maker), MIN_BOND - 1_000e6);
        assertFalse(registry.canQuote(maker));
        vm.prank(maker);
        vm.expectRevert(MakerRegistry.NothingPending.selector);
        registry.completeWithdrawal();
    }

    function test_cancelWithdrawal() public {
        _registerMaker(maker, MIN_BOND);
        vm.startPrank(maker);
        vm.expectRevert(MakerRegistry.NothingPending.selector);
        registry.cancelWithdrawal();
        registry.requestWithdrawal(5_000e6, 0);
        registry.cancelWithdrawal();
        vm.stopPrank();
        assertEq(registry.bondValueOf(maker), MIN_BOND);
    }

    function test_slash_orderAndCaps() public {
        _registerMaker(maker, MIN_BOND);
        vm.prank(maker);
        registry.requestWithdrawal(4_000e6, 0);
        vm.prank(slasher);
        (uint256 s, uint256 p) = registry.slash(maker, victim, 20_000e6);
        assertEq(s, MIN_BOND);
        assertEq(p, 0);
        MakerRegistry.Maker memory m = registry.makerInfo(maker);
        assertEq(m.stableBond, 0);
        assertEq(m.pendingStable, 0);
        assertEq(m.defaults, 1);
        vm.prank(slasher);
        vm.expectRevert(BlockroomBase.ZeroAddress.selector);
        registry.slash(maker, address(0), 1);
    }

    function test_slash_onlySlasher() public {
        _registerMaker(maker, MIN_BOND);
        vm.expectRevert();
        registry.slash(maker, victim, 1);
    }

    function test_projectBond_disabledUntilTokenSet() public {
        vm.prank(maker);
        registry.register();
        vm.prank(maker);
        vm.expectRevert(MakerRegistry.TokenDisabled.selector);
        registry.depositProjectBond(1e18);
    }

    function test_projectBond_countsAtRatio_andSlashedForShortfall() public {
        vm.prank(admin);
        hooks.setProjectToken(address(proj));
        _registerMaker(maker, 2_000e6);
        proj.mint(maker, 20_000e18);
        vm.startPrank(maker);
        proj.approve(address(registry), type(uint256).max);
        vm.expectRevert(MakerRegistry.ZeroAmount.selector);
        registry.depositProjectBond(0);
        registry.depositProjectBond(16_000e18); // 16k * 0.5 = 8k USDG value
        vm.stopPrank();
        assertEq(registry.bondValueOf(maker), 10_000e6);
        assertTrue(registry.canQuote(maker));

        vm.prank(maker);
        registry.requestWithdrawal(0, 4_000e18);
        assertEq(registry.slashableValue(maker), 10_000e6);

        vm.prank(slasher);
        (uint256 s, uint256 p) = registry.slash(maker, victim, 9_000e6);
        assertEq(s, 2_000e6);
        assertEq(p, 14_000e18); // 7k shortfall / 0.5
        assertEq(proj.balanceOf(victim), 14_000e18);
        MakerRegistry.Maker memory m = registry.makerInfo(maker);
        assertEq(m.projectBond, 0);
        assertEq(m.pendingProject, 2_000e18);

        vm.warp(block.timestamp + 2 days);
        vm.prank(maker);
        registry.completeWithdrawal();
        assertEq(proj.balanceOf(maker), 4_000e18 + 2_000e18);
    }

    function test_suspend() public {
        _registerMaker(maker, MIN_BOND);
        vm.prank(guardian);
        registry.setSuspended(maker, true);
        assertFalse(registry.canQuote(maker));
    }

    function test_admin() public {
        vm.startPrank(admin);
        registry.setMinBond(1);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        registry.setUnbondingPeriod(59 minutes);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        registry.setUnbondingPeriod(31 days);
        registry.setUnbondingPeriod(3 days);
        vm.stopPrank();
        assertEq(registry.unbondingPeriod(), 3 days);
        vm.expectRevert(BlockroomBase.ZeroAddress.selector);
        new MakerRegistry(admin, guardian, address(0), address(hooks), 1, 1 days);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        new MakerRegistry(admin, guardian, address(usdg), address(hooks), 1, 1);
        vm.expectRevert(BlockroomBase.ZeroAddress.selector);
        new MakerRegistry(address(0), guardian, address(usdg), address(hooks), 1, 1 days);
    }

    function test_paused_blocksRegisterAndDeposit() public {
        vm.prank(guardian);
        registry.pause();
        vm.prank(maker);
        vm.expectRevert();
        registry.register();
    }

    function test_compliance_onRegister() public {
        vm.prank(admin);
        compliance.setEnabled(true);
        vm.prank(maker);
        vm.expectRevert();
        registry.register();
        bytes32 act = compliance.ACTION_MAKER_REGISTER();
        vm.prank(admin);
        compliance.setOpenAction(act, true);
        vm.prank(maker);
        registry.register();
    }

    function test_zeroDeposit() public {
        vm.prank(maker);
        registry.register();
        vm.prank(maker);
        vm.expectRevert(MakerRegistry.ZeroAmount.selector);
        registry.depositBond(0);
    }
}
