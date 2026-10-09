// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

/// @notice DEV ONLY (local fork). Prints the storage slot holding `balanceOf(account)` for `token`, so a local
///         anvil fork can be funded with `cast rpc anvil_setStorageAt`. Never used against mainnet.
contract FindBalanceSlot is Script {
    using stdStorage for StdStorage;

    function run(address token, address account) external returns (bytes32 slot) {
        slot = bytes32(stdstore.target(token).sig("balanceOf(address)").with_key(account).find());
        console2.logBytes32(slot);
    }
}
