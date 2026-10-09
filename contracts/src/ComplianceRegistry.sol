// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IComplianceHook} from "./interfaces/IBlockroom.sol";

/// @title ComplianceRegistry
/// @notice Pluggable allowlist hook. OFF by default: while `enabled == false` every account is allowed.
///         When enabled, an action is permitted only for allowlisted accounts, unless that action has been
///         explicitly marked as open. Operators (COMPLIANCE_ROLE) manage the list; the Timelock flips the switch.
contract ComplianceRegistry is AccessControl, IComplianceHook {
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    bytes32 public constant ACTION_RFQ_TAKE = keccak256("RFQ_TAKE");
    bytes32 public constant ACTION_RFQ_MAKE = keccak256("RFQ_MAKE");
    bytes32 public constant ACTION_MAKER_REGISTER = keccak256("MAKER_REGISTER");
    bytes32 public constant ACTION_MIDPOINT = keccak256("MIDPOINT");
    bytes32 public constant ACTION_STAKE = keccak256("STAKE");

    uint256 public constant MAX_BATCH = 200;

    bool public enabled;
    mapping(address account => bool) public allowed;
    mapping(bytes32 action => bool) public openAction;

    error ZeroAddress();
    error BatchTooLarge();

    event EnabledSet(bool enabled);
    event AllowedSet(address indexed account, bool allowed);
    event OpenActionSet(bytes32 indexed action, bool open);

    constructor(address admin, address operator) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (operator != address(0)) _grantRole(COMPLIANCE_ROLE, operator);
    }

    function setEnabled(bool enabled_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        enabled = enabled_;
        emit EnabledSet(enabled_);
    }

    function setOpenAction(bytes32 action, bool open) external onlyRole(DEFAULT_ADMIN_ROLE) {
        openAction[action] = open;
        emit OpenActionSet(action, open);
    }

    function setAllowed(address[] calldata accounts, bool allowed_) external onlyRole(COMPLIANCE_ROLE) {
        uint256 n = accounts.length;
        if (n > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i; i < n; ++i) {
            allowed[accounts[i]] = allowed_;
            emit AllowedSet(accounts[i], allowed_);
        }
    }

    function isAllowed(address account, bytes32 action) external view returns (bool) {
        if (!enabled) return true;
        return allowed[account] || openAction[action];
    }
}
