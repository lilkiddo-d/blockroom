// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Compliance action identifiers shared by all gated contracts.
library Actions {
    bytes32 internal constant RFQ_TAKE = keccak256("RFQ_TAKE");
    bytes32 internal constant RFQ_MAKE = keccak256("RFQ_MAKE");
    bytes32 internal constant MAKER_REGISTER = keccak256("MAKER_REGISTER");
    bytes32 internal constant MIDPOINT = keccak256("MIDPOINT");
    bytes32 internal constant STAKE = keccak256("STAKE");
}
