// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./utils/BaseTest.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {BlockroomBase} from "../src/base/BlockroomBase.sol";
import {MockERC20} from "./utils/Mocks.sol";

contract FeeAndTokenTest is BaseTest {
    address notifier = makeAddr("notifier");
    address s1 = makeAddr("staker1");
    address s2 = makeAddr("staker2");

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        fc.grantRole(fc.NOTIFIER_ROLE(), notifier);
        vm.stopPrank();
    }

    function _notify(uint256 amt) internal {
        usdg.mint(address(fc), amt);
        vm.prank(notifier);
        fc.notifyFee(address(usdg), amt);
    }

    function _enable() internal {
        vm.prank(admin);
        hooks.setProjectToken(address(proj));
        proj.mint(s1, 1_000e18);
        proj.mint(s2, 1_000e18);
        vm.prank(s1);
        proj.approve(address(fc), type(uint256).max);
        vm.prank(s2);
        proj.approve(address(fc), type(uint256).max);
    }

    // ---------------------------------------------------------------- hooks

    function test_hooks_disabledByDefault() public view {
        assertFalse(hooks.tokenEnabled());
        assertEq(hooks.bondValue(1e18), 0);
        assertEq(hooks.projectAmountForValue(1), type(uint256).max);
        assertEq(hooks.feeDiscountBps(s1), 0);
    }

    function test_hooks_setProjectToken_once_adminOnly() public {
        vm.expectRevert();
        hooks.setProjectToken(address(proj));
        vm.startPrank(admin);
        vm.expectRevert(ProjectTokenHooks.ZeroAddress.selector);
        hooks.setProjectToken(address(0));
        hooks.setProjectToken(address(proj));
        vm.expectRevert(ProjectTokenHooks.AlreadySet.selector);
        hooks.setProjectToken(address(usdg));
        vm.stopPrank();
        assertTrue(hooks.tokenEnabled());
        assertEq(hooks.bondValue(2e18), 1e6);
        assertEq(hooks.projectAmountForValue(1e6), 2e18);
    }

    function test_hooks_params() public {
        vm.startPrank(admin);
        vm.expectRevert(ProjectTokenHooks.InvalidParam.selector);
        hooks.setStakerShareBps(8_001);
        hooks.setStakerShareBps(5_000);
        hooks.setBondValuePerToken(0);
        hooks.setProjectToken(address(proj));
        assertEq(hooks.projectAmountForValue(1), type(uint256).max);
        vm.expectRevert(ProjectTokenHooks.ZeroAddress.selector);
        hooks.setStakingSource(address(0));

        ProjectTokenHooks.Tier[] memory t = new ProjectTokenHooks.Tier[](5);
        vm.expectRevert(ProjectTokenHooks.InvalidParam.selector);
        hooks.setTiers(t);
        t = new ProjectTokenHooks.Tier[](2);
        t[0] = ProjectTokenHooks.Tier(100, 100);
        t[1] = ProjectTokenHooks.Tier(100, 200);
        vm.expectRevert(ProjectTokenHooks.InvalidParam.selector);
        hooks.setTiers(t);
        t[1] = ProjectTokenHooks.Tier(200, 100);
        vm.expectRevert(ProjectTokenHooks.InvalidParam.selector);
        hooks.setTiers(t);
        t[1] = ProjectTokenHooks.Tier(200, 5_001);
        vm.expectRevert(ProjectTokenHooks.InvalidParam.selector);
        hooks.setTiers(t);
        t[0] = ProjectTokenHooks.Tier(0, 1);
        vm.expectRevert(ProjectTokenHooks.InvalidParam.selector);
        hooks.setTiers(t);
        t[0] = ProjectTokenHooks.Tier(100, 100);
        t[1] = ProjectTokenHooks.Tier(200, 300);
        hooks.setTiers(t);
        vm.stopPrank();
        assertEq(hooks.tiers().length, 2);
        assertEq(hooks.feeDiscountBps(s1), 0);
        vm.expectRevert(ProjectTokenHooks.ZeroAddress.selector);
        new ProjectTokenHooks(address(0), 1, 1);
        vm.expectRevert(ProjectTokenHooks.InvalidParam.selector);
        new ProjectTokenHooks(admin, 1, 9_000);
    }

    function test_hooks_noTiers_zeroDiscount() public {
        vm.prank(admin);
        hooks.setProjectToken(address(proj));
        assertEq(hooks.feeDiscountBps(s1), 0);
    }

    // ------------------------------------------------------------ collector

    function test_fees_allTreasury_whenTokenDisabled() public {
        _notify(100e6);
        assertEq(fc.treasuryAccrued(address(usdg)), 100e6);
        fc.sweepToTreasury(address(usdg));
        assertEq(usdg.balanceOf(treasury), 100e6);
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        fc.sweepToTreasury(address(usdg));
    }

    function test_fees_zeroIgnored() public {
        vm.prank(notifier);
        fc.notifyFee(address(usdg), 0);
        assertEq(fc.treasuryAccrued(address(usdg)), 0);
    }

    function test_notify_onlyNotifier() public {
        vm.expectRevert();
        fc.notifyFee(address(usdg), 1);
    }

    function test_stake_disabled() public {
        vm.prank(s1);
        vm.expectRevert(FeeCollector.TokenDisabled.selector);
        fc.stake(1);
    }

    function test_staking_rewards_split() public {
        _enable();
        vm.prank(s1);
        fc.stake(100e18);
        _notify(1_000e6); // 30% -> stakers
        assertEq(fc.treasuryAccrued(address(usdg)), 700e6);
        assertEq(fc.claimable(s1, address(usdg)), 300e6);

        vm.prank(s2);
        fc.stake(300e18);
        _notify(1_000e6);
        assertEq(fc.claimable(s1, address(usdg)), 300e6 + 75e6);
        assertEq(fc.claimable(s2, address(usdg)), 225e6);

        vm.prank(s1);
        fc.claim();
        assertEq(usdg.balanceOf(s1), 375e6);
        assertEq(fc.claimable(s1, address(usdg)), 0);
        vm.prank(s2);
        fc.claim();
        assertEq(usdg.balanceOf(s2), 225e6);
        assertEq(fc.stakerLiability(address(usdg)), 0);
        // claim with nothing pending is a no-op
        vm.prank(s2);
        fc.claim();
    }

    function test_unstake_cooldown_and_noRewardsWhileUnbonding() public {
        _enable();
        vm.startPrank(s1);
        fc.stake(100e18);
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        fc.stake(0);
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        fc.requestUnstake(0);
        vm.expectRevert(FeeCollector.InsufficientStake.selector);
        fc.requestUnstake(101e18);
        fc.requestUnstake(100e18);
        vm.expectRevert(abi.encodeWithSelector(FeeCollector.CooldownActive.selector, uint64(block.timestamp + 7 days)));
        fc.withdrawUnstaked();
        vm.stopPrank();
        assertEq(fc.stakedOf(s1), 0);
        _notify(1_000e6); // nobody staked -> all treasury
        assertEq(fc.treasuryAccrued(address(usdg)), 1_000e6);
        vm.warp(block.timestamp + 7 days);
        vm.startPrank(s1);
        fc.withdrawUnstaked();
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        fc.withdrawUnstaked();
        vm.stopPrank();
        assertEq(proj.balanceOf(s1), 1_000e18);
    }

    function test_nonRewardToken_allTreasury() public {
        _enable();
        vm.prank(s1);
        fc.stake(1e18);
        MockERC20 other = new MockERC20("o", "o", 18);
        other.mint(address(fc), 5e18);
        vm.prank(notifier);
        fc.notifyFee(address(other), 5e18);
        assertEq(fc.treasuryAccrued(address(other)), 5e18);
    }

    function test_rewardToken_admin() public {
        vm.startPrank(admin);
        vm.expectRevert(FeeCollector.AlreadyRewardToken.selector);
        fc.addRewardToken(address(usdg));
        vm.expectRevert(BlockroomBase.ZeroAddress.selector);
        fc.addRewardToken(address(0));
        fc.addRewardToken(address(1));
        fc.addRewardToken(address(2));
        fc.addRewardToken(address(3));
        vm.expectRevert(FeeCollector.TooManyRewardTokens.selector);
        fc.addRewardToken(address(4));
        assertEq(fc.rewardTokenCount(), 4);
        vm.expectRevert(BlockroomBase.ZeroAddress.selector);
        fc.setTreasury(address(0));
        fc.setTreasury(address(5));
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        fc.setUnstakeCooldown(31 days);
        fc.setUnstakeCooldown(1 days);
        vm.stopPrank();
    }

    function test_projectToken_cannotBeRewardToken() public {
        vm.startPrank(admin);
        hooks.setProjectToken(address(proj));
        vm.expectRevert(FeeCollector.InvalidRewardToken.selector);
        fc.addRewardToken(address(proj));
        vm.stopPrank();
    }

    function test_constructor_guards() public {
        vm.expectRevert(BlockroomBase.ZeroAddress.selector);
        new FeeCollector(admin, guardian, address(0), treasury, 1);
        vm.expectRevert(BlockroomBase.InvalidParam.selector);
        new FeeCollector(admin, guardian, address(hooks), treasury, 31 days);
    }

    function test_stake_paused() public {
        _enable();
        vm.prank(guardian);
        fc.pause();
        vm.prank(s1);
        vm.expectRevert();
        fc.stake(1);
    }

    function testFuzz_rewardsNeverExceedStakerShare(uint96 a1, uint96 a2, uint96 f1, uint96 f2) public {
        _enable();
        a1 = uint96(bound(a1, 1, 1_000e18));
        a2 = uint96(bound(a2, 1, 1_000e18));
        f1 = uint96(bound(f1, 0, 1e15));
        f2 = uint96(bound(f2, 0, 1e15));
        vm.prank(s1);
        fc.stake(a1);
        _notify(f1);
        vm.prank(s2);
        fc.stake(a2);
        _notify(f2);
        uint256 owed = fc.claimable(s1, address(usdg)) + fc.claimable(s2, address(usdg));
        assertLe(owed, fc.stakerLiability(address(usdg)));
        assertEq(fc.stakerLiability(address(usdg)) + fc.treasuryAccrued(address(usdg)), uint256(f1) + f2);
    }
}
