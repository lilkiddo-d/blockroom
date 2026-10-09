// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";

/// @title SetProjectToken
/// @notice Wires the separately-launched $BLKR token through the 48h Timelock, in one batch:
///           1. ProjectTokenHooks.setProjectToken(token)              (one-shot)
///           2. ProjectTokenHooks.setBondValuePerToken(value)         (maker bond haircut ratio)
///           3. ProjectTokenHooks.setTiers(tiers)                     (taker fee discounts)
///         Step A: `schedule(token, bondValuePerToken)`  -> wait 48h ->  Step B: `execute(token, bondValuePerToken)`.
///         Both must be called with identical arguments. Signs with the proposer/executor keystore.
contract SetProjectToken is Script {
    bytes32 internal constant SALT = keccak256("blockroom.setProjectToken.v1");

    function schedule(address token, uint256 bondValuePerToken) external {
        (TimelockController tl, address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _batch(token, bondValuePerToken);
        vm.startBroadcast();
        tl.scheduleBatch(targets, values, payloads, bytes32(0), SALT, tl.getMinDelay());
        vm.stopBroadcast();
        bytes32 id = tl.hashOperationBatch(targets, values, payloads, bytes32(0), SALT);
        console2.log("Scheduled. Executable after (unix):", block.timestamp + tl.getMinDelay());
        console2.logBytes32(id);
    }

    function execute(address token, uint256 bondValuePerToken) external {
        (TimelockController tl, address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _batch(token, bondValuePerToken);
        vm.startBroadcast();
        tl.executeBatch(targets, values, payloads, bytes32(0), SALT);
        vm.stopBroadcast();
        ProjectTokenHooks hooks = ProjectTokenHooks(targets[0]);
        require(hooks.projectToken() == token, "not set");
        console2.log("Project token enabled:", token);
    }

    function _batch(address token, uint256 bondValuePerToken)
        internal
        view
        returns (TimelockController tl, address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        require(token != address(0) && token.code.length > 0, "token has no code");
        string memory json = vm.readFile(
            string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json")
        );
        tl = TimelockController(payable(vm.parseJsonAddress(json, ".Timelock")));
        address hooks = vm.parseJsonAddress(json, ".ProjectTokenHooks");

        ProjectTokenHooks.Tier[] memory tiers = new ProjectTokenHooks.Tier[](3);
        tiers[0] = ProjectTokenHooks.Tier({minStake: 10_000e18, discountBps: 1_000});
        tiers[1] = ProjectTokenHooks.Tier({minStake: 100_000e18, discountBps: 2_500});
        tiers[2] = ProjectTokenHooks.Tier({minStake: 1_000_000e18, discountBps: 5_000});

        targets = new address[](3);
        values = new uint256[](3);
        payloads = new bytes[](3);
        targets[0] = hooks;
        targets[1] = hooks;
        targets[2] = hooks;
        payloads[0] = abi.encodeCall(ProjectTokenHooks.setProjectToken, (token));
        payloads[1] = abi.encodeCall(ProjectTokenHooks.setBondValuePerToken, (bondValuePerToken));
        payloads[2] = abi.encodeCall(ProjectTokenHooks.setTiers, (tiers));
    }
}
