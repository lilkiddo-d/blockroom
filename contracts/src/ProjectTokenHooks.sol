// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IProjectTokenHooks, IStakingSource} from "./interfaces/IBlockroom.sol";

/// @title ProjectTokenHooks
/// @notice The single switchboard for the (separately launched) $BLKR project token. Blockroom does NOT
///         deploy any ERC-20. Until `setProjectToken` is called (once, by the Timelock) every token feature
///         is disabled and all views return neutral values, so the protocol runs fully without it.
///
///         Token features:
///           1. Makers may bond the project token instead of stablecoin, valued at `bondValuePerToken`
///              (bond-token units per 1e18 project-token units; a deliberately conservative haircut ratio).
///           2. Stakers (FeeCollector) receive `stakerShareBps` of settlement fees.
///           3. Takers whose stake meets a tier get a fee discount.
contract ProjectTokenHooks is AccessControl, IProjectTokenHooks {
    struct Tier {
        uint128 minStake;
        uint16 discountBps;
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_TIERS = 4;
    uint256 public constant MAX_DISCOUNT_BPS = 5_000;
    uint256 public constant MAX_STAKER_SHARE_BPS = 8_000;

    address public projectToken;
    uint256 public bondValuePerToken; // bond-token units per 1e18 project-token units
    uint256 public stakerShareBps;
    IStakingSource public stakingSource;
    Tier[] internal _tiers;

    error ZeroAddress();
    error AlreadySet();
    error InvalidParam();

    event ProjectTokenSet(address indexed token);
    event BondValueSet(uint256 bondValuePerToken);
    event StakerShareSet(uint256 bps);
    event StakingSourceSet(address indexed source);
    event TiersSet(uint256 count);

    constructor(address admin, uint256 bondValuePerToken_, uint256 stakerShareBps_) {
        if (admin == address(0)) revert ZeroAddress();
        if (stakerShareBps_ > MAX_STAKER_SHARE_BPS) revert InvalidParam();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        bondValuePerToken = bondValuePerToken_;
        stakerShareBps = stakerShareBps_;
        emit BondValueSet(bondValuePerToken_);
        emit StakerShareSet(stakerShareBps_);
    }

    /// @notice One-shot. Callable only by DEFAULT_ADMIN_ROLE (the 48h Timelock after deployment).
    function setProjectToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (projectToken != address(0)) revert AlreadySet();
        projectToken = token;
        emit ProjectTokenSet(token);
    }

    function setBondValuePerToken(uint256 v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bondValuePerToken = v;
        emit BondValueSet(v);
    }

    function setStakerShareBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_STAKER_SHARE_BPS) revert InvalidParam();
        stakerShareBps = bps;
        emit StakerShareSet(bps);
    }

    function setStakingSource(address source) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (source == address(0)) revert ZeroAddress();
        stakingSource = IStakingSource(source);
        emit StakingSourceSet(source);
    }

    /// @notice Replace discount tiers. Must be strictly ascending in both stake and discount.
    function setTiers(Tier[] calldata newTiers) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 n = newTiers.length;
        if (n > MAX_TIERS) revert InvalidParam();
        delete _tiers;
        for (uint256 i; i < n; ++i) {
            Tier calldata t = newTiers[i];
            if (t.discountBps > MAX_DISCOUNT_BPS || t.minStake == 0) revert InvalidParam();
            if (i > 0 && (t.minStake <= newTiers[i - 1].minStake || t.discountBps <= newTiers[i - 1].discountBps)) {
                revert InvalidParam();
            }
            _tiers.push(t);
        }
        emit TiersSet(n);
    }

    // ------------------------------------------------------------------ views

    function tiers() external view returns (Tier[] memory) {
        return _tiers;
    }

    function tokenEnabled() public view returns (bool) {
        return projectToken != address(0);
    }

    function bondValue(uint256 projectAmount) external view returns (uint256) {
        if (!tokenEnabled()) return 0;
        return Math.mulDiv(projectAmount, bondValuePerToken, 1e18);
    }

    /// @notice Project-token amount (rounded up) covering `value` bond-token units. Max uint if unpriced.
    function projectAmountForValue(uint256 value) external view returns (uint256) {
        if (!tokenEnabled() || bondValuePerToken == 0) return type(uint256).max;
        return Math.mulDiv(value, 1e18, bondValuePerToken, Math.Rounding.Ceil);
    }

    function feeDiscountBps(address account) external view returns (uint256 discount) {
        if (!tokenEnabled() || address(stakingSource) == address(0)) return 0;
        uint256 n = _tiers.length;
        if (n == 0) return 0;
        uint256 staked = stakingSource.stakedOf(account);
        for (uint256 i; i < n; ++i) {
            if (staked >= _tiers[i].minStake) discount = _tiers[i].discountBps;
            else break;
        }
    }
}
