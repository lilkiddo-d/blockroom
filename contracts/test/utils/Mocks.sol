// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AggregatorV3Interface} from "../../src/interfaces/IBlockroom.sol";

/// @dev TEST-ONLY mock token. Blockroom never deploys an ERC-20 in production.
contract MockERC20 is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @dev Token returning false instead of reverting (non-standard ERC20).
contract FalseReturnERC20 is MockERC20 {
    constructor() MockERC20("False", "FALSE", 18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (allowance(from, msg.sender) < amount || balanceOf(from) < amount) return false;
        return super.transferFrom(from, to, amount);
    }
}

/// @dev Fee-on-transfer token (1%) to exercise balance-delta checks.
contract FeeOnTransferERC20 is MockERC20 {
    constructor() MockERC20("FoT", "FOT", 18) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xdead), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

contract MockAggregator is AggregatorV3Interface {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint256 public startedAt;
    uint80 public roundId = 1;

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
        startedAt = block.timestamp;
    }

    function set(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
        roundId++;
    }

    function setWithTime(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
        roundId++;
    }

    function setStartedAt(uint256 t) external {
        startedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, roundId);
    }
}

/// @dev Smart-contract maker wallet (ERC-1271) controlled by an EOA signer.
contract MockSmartWallet is IERC1271 {
    address public immutable signer;

    constructor(address s) {
        signer = s;
    }

    function isValidSignature(bytes32 hash, bytes memory sig) external view returns (bytes4) {
        (address rec, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, sig);
        return err == ECDSA.RecoverError.NoError && rec == signer ? IERC1271.isValidSignature.selector : bytes4(0);
    }

    function call(address target, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == signer, "only signer");
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "call failed");
        return ret;
    }
}
