// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title BlockroomTimelock
/// @notice OpenZeppelin TimelockController with a hard 48h minimum delay. Holds DEFAULT_ADMIN_ROLE on every
///         Blockroom contract after deployment. Self-administered (no external admin).
contract BlockroomTimelock is TimelockController {
    uint256 public constant MIN_DELAY_FLOOR = 48 hours;

    error DelayTooShort();

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors)
        TimelockController(minDelay, proposers, executors, address(0))
    {
        if (minDelay < MIN_DELAY_FLOOR) revert DelayTooShort();
    }

    /// @dev The floor also binds later `updateDelay` calls: the effective delay can never drop below 48h.
    function getMinDelay() public view override returns (uint256) {
        uint256 d = super.getMinDelay();
        return d < MIN_DELAY_FLOOR ? MIN_DELAY_FLOOR : d;
    }
}
