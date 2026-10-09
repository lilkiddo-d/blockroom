// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BlockroomTimelock} from "../src/BlockroomTimelock.sol";

contract TimelockTest is Test {
    BlockroomTimelock tl;
    address proposer = makeAddr("proposer");

    function setUp() public {
        address[] memory p = new address[](1);
        p[0] = proposer;
        tl = new BlockroomTimelock(48 hours, p, p);
    }

    function test_constructorFloor() public {
        address[] memory p = new address[](1);
        p[0] = proposer;
        vm.expectRevert(BlockroomTimelock.DelayTooShort.selector);
        new BlockroomTimelock(48 hours - 1, p, p);
        BlockroomTimelock longer = new BlockroomTimelock(72 hours, p, p);
        assertEq(longer.getMinDelay(), 72 hours);
    }

    function _selfUpdate(uint256 newDelay) internal {
        bytes memory data = abi.encodeCall(tl.updateDelay, (newDelay));
        vm.startPrank(proposer);
        tl.schedule(address(tl), 0, data, bytes32(0), keccak256(abi.encode(newDelay)), tl.getMinDelay());
        vm.warp(block.timestamp + tl.getMinDelay());
        tl.execute(address(tl), 0, data, bytes32(0), keccak256(abi.encode(newDelay)));
        vm.stopPrank();
    }

    function test_delayCanIncrease() public {
        _selfUpdate(96 hours);
        assertEq(tl.getMinDelay(), 96 hours);
    }

    function test_delayNeverBelowFloor() public {
        _selfUpdate(1 hours);
        assertEq(tl.getMinDelay(), 48 hours, "floor enforced");
        vm.prank(proposer);
        vm.expectRevert();
        tl.schedule(address(1), 0, "", bytes32(0), bytes32(0), 1 hours);
    }

    function test_onlyProposerSchedules() public {
        vm.expectRevert();
        tl.schedule(address(1), 0, "", bytes32(0), bytes32(0), 48 hours);
    }
}
