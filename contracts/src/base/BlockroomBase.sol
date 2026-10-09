// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IComplianceHook} from "../interfaces/IBlockroom.sol";

/// @title BlockroomBase
/// @notice Shared access control, guardian pause and pluggable compliance gate.
/// @dev DEFAULT_ADMIN_ROLE is handed to the 48h Timelock by the deploy script. GUARDIAN_ROLE can only
///      pause/unpause; it can never move funds or change parameters.
abstract contract BlockroomBase is AccessControl, Pausable {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Optional compliance hook. address(0) = disabled (default).
    IComplianceHook public compliance;

    error ZeroAddress();
    error NotCompliant(address account, bytes32 action);
    error InvalidParam();

    event ComplianceHookSet(address indexed hook);

    constructor(address admin, address guardian) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (guardian != address(0)) _grantRole(GUARDIAN_ROLE, guardian);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    function setCompliance(address hook) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = IComplianceHook(hook);
        emit ComplianceHookSet(hook);
    }

    function _requireCompliant(address account, bytes32 action) internal view {
        IComplianceHook hook = compliance;
        if (address(hook) != address(0) && !hook.isAllowed(account, action)) revert NotCompliant(account, action);
    }
}
