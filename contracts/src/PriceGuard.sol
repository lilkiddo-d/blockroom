// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockroomBase} from "./base/BlockroomBase.sol";
import {IOracleAdapter, IPriceGuard} from "./interfaces/IBlockroom.sol";

/// @title PriceGuard
/// @notice Single source of "mid" for the protocol and the band check for RFQ settlement: a quote whose price
///         is more than `bandBps` away from the oracle mid is rejected. This protects takers from off-market
///         quotes and makers from being filled on quotes that went stale while the market moved.
contract PriceGuard is BlockroomBase, IPriceGuard {
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_BAND_BPS = 1_000; // 10% hard cap

    IOracleAdapter public oracle;
    uint16 public defaultBandBps;
    mapping(address base => uint16) public assetBandBps; // 0 = use default

    error PriceOutsideGuard(uint256 price, uint256 mid, uint256 bandBps);
    error ZeroPrice();

    event OracleSet(address indexed oracle);
    event DefaultBandSet(uint16 bps);
    event AssetBandSet(address indexed base, uint16 bps);

    constructor(address admin, address guardian, address oracle_, uint16 defaultBandBps_)
        BlockroomBase(admin, guardian)
    {
        if (oracle_ == address(0)) revert ZeroAddress();
        if (defaultBandBps_ == 0 || defaultBandBps_ > MAX_BAND_BPS) revert InvalidParam();
        oracle = IOracleAdapter(oracle_);
        defaultBandBps = defaultBandBps_;
        emit OracleSet(oracle_);
        emit DefaultBandSet(defaultBandBps_);
    }

    function setOracle(address oracle_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = IOracleAdapter(oracle_);
        emit OracleSet(oracle_);
    }

    function setDefaultBand(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps == 0 || bps > MAX_BAND_BPS) revert InvalidParam();
        defaultBandBps = bps;
        emit DefaultBandSet(bps);
    }

    function setAssetBand(address base, uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_BAND_BPS) revert InvalidParam();
        assetBandBps[base] = bps;
        emit AssetBandSet(base, bps);
    }

    function bandBps(address base) public view returns (uint256) {
        uint16 b = assetBandBps[base];
        return b == 0 ? defaultBandBps : b;
    }

    function getMid(address base, address quote) public view returns (uint256 mid) {
        // Freshness is enforced inside the adapter (it reverts on stale data); re-check the basics defensively
        // in case the adapter is swapped for a less strict implementation.
        uint256 updatedAt;
        (mid, updatedAt) = oracle.getMid(base, quote);
        if (mid == 0 || updatedAt == 0 || updatedAt > block.timestamp) revert ZeroPrice();
    }

    /// @return mid the oracle mid used for the check
    function checkPrice(address base, address quote, uint256 price) external view returns (uint256 mid) {
        if (price == 0) revert ZeroPrice();
        mid = getMid(base, quote);
        uint256 band = bandBps(base);
        uint256 diff = price > mid ? price - mid : mid - price;
        if (diff * BPS > mid * band) revert PriceOutsideGuard(price, mid, band);
    }
}
