// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BlockroomBase} from "./base/BlockroomBase.sol";
import {Actions} from "./libraries/Actions.sol";
import {IFeeCollector, IProjectTokenHooks, IStakingSource} from "./interfaces/IBlockroom.sol";

/// @title FeeCollector
/// @notice Receives settlement fees. Without the project token every fee accrues to the treasury.
///         Once the project token is set, `stakerShareBps` of fees in reward tokens is streamed to project-token
///         stakers (MasterChef-style accumulator, bounded reward-token list, no unbounded loops).
///         Stake has an unstake cooldown so fee-discount tiers cannot be flash-borrowed.
contract FeeCollector is BlockroomBase, ReentrancyGuard, IFeeCollector, IStakingSource {
    using SafeERC20 for IERC20;

    bytes32 public constant NOTIFIER_ROLE = keccak256("NOTIFIER_ROLE");
    uint256 public constant BPS = 10_000;
    uint256 public constant PRECISION = 1e36;
    uint256 public constant MAX_REWARD_TOKENS = 4;
    uint64 public constant MAX_COOLDOWN = 30 days;

    struct Unstaking {
        uint128 amount;
        uint64 unlockTime;
    }

    IProjectTokenHooks public immutable hooks;
    address public treasury;
    uint64 public unstakeCooldown;

    address[] public rewardTokens;
    mapping(address token => bool) public isRewardToken;
    mapping(address token => uint256) public accRewardPerShare;
    mapping(address token => uint256) public treasuryAccrued;

    uint256 public totalStaked;
    mapping(address user => uint256) public stakedOf;
    mapping(address user => Unstaking) public unstaking;
    mapping(address user => mapping(address token => uint256)) public rewardDebt;
    mapping(address user => mapping(address token => uint256)) public pendingRewards;
    /// @dev Total reward tokens owed to stakers (claimed or not) - excluded from treasury sweeps.
    mapping(address token => uint256) public stakerLiability;

    error TokenDisabled();
    error TooManyRewardTokens();
    error AlreadyRewardToken();
    error InvalidRewardToken();
    error ZeroAmount();
    error CooldownActive(uint64 unlockTime);
    error InsufficientStake();

    event FeeNotified(address indexed token, uint256 amount, uint256 toStakers, uint256 toTreasury);
    event RewardTokenAdded(address indexed token);
    event TreasurySet(address indexed treasury);
    event CooldownSet(uint64 cooldown);
    event Staked(address indexed user, uint256 amount);
    event UnstakeRequested(address indexed user, uint256 amount, uint64 unlockTime);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, address indexed token, uint256 amount);
    event TreasurySwept(address indexed token, address indexed to, uint256 amount);

    constructor(address admin, address guardian, address hooks_, address treasury_, uint64 cooldown_)
        BlockroomBase(admin, guardian)
    {
        if (hooks_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (cooldown_ > MAX_COOLDOWN) revert InvalidParam();
        hooks = IProjectTokenHooks(hooks_);
        treasury = treasury_;
        unstakeCooldown = cooldown_;
        emit TreasurySet(treasury_);
        emit CooldownSet(cooldown_);
    }

    // ------------------------------------------------------------------ admin

    function addRewardToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (isRewardToken[token]) revert AlreadyRewardToken();
        if (rewardTokens.length >= MAX_REWARD_TOKENS) revert TooManyRewardTokens();
        if (token == hooks.projectToken()) revert InvalidRewardToken();
        isRewardToken[token] = true;
        rewardTokens.push(token);
        emit RewardTokenAdded(token);
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setUnstakeCooldown(uint64 cooldown_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cooldown_ > MAX_COOLDOWN) revert InvalidParam();
        unstakeCooldown = cooldown_;
        emit CooldownSet(cooldown_);
    }

    // ------------------------------------------------------------------ fees

    /// @notice Book a fee that the caller has ALREADY transferred to this contract.
    // slither-disable-start divide-before-multiply
    function notifyFee(address token, uint256 amount) external onlyRole(NOTIFIER_ROLE) {
        if (amount == 0) return;
        uint256 toStakers = 0;
        if (isRewardToken[token] && totalStaked > 0 && hooks.tokenEnabled()) {
            toStakers = (amount * hooks.stakerShareBps()) / BPS;
            if (toStakers > 0) {
                // The integer staker share must be computed first: it is the exact amount booked as liability.
                // Rounding loss is < 1 wei of reward token per notification (PRECISION = 1e36).
                accRewardPerShare[token] += (toStakers * PRECISION) / totalStaked;
                stakerLiability[token] += toStakers;
            }
        }
        uint256 toTreasury = amount - toStakers;
        treasuryAccrued[token] += toTreasury;
        emit FeeNotified(token, amount, toStakers, toTreasury);
    }
    // slither-disable-end divide-before-multiply

    /// @notice Permissionless: push accrued treasury fees to the treasury address.
    function sweepToTreasury(address token) external nonReentrant {
        uint256 amount = treasuryAccrued[token];
        if (amount == 0) revert ZeroAmount();
        treasuryAccrued[token] = 0;
        address to = treasury;
        IERC20(token).safeTransfer(to, amount);
        emit TreasurySwept(token, to, amount);
    }

    // ---------------------------------------------------------------- staking

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        address token = hooks.projectToken();
        if (token == address(0)) revert TokenDisabled();
        if (amount == 0) revert ZeroAmount();
        _requireCompliant(msg.sender, Actions.STAKE);
        _harvest(msg.sender);
        stakedOf[msg.sender] += amount;
        totalStaked += amount;
        _resetDebt(msg.sender);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function requestUnstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 s = stakedOf[msg.sender];
        if (amount > s) revert InsufficientStake();
        _harvest(msg.sender);
        stakedOf[msg.sender] = s - amount;
        totalStaked -= amount;
        _resetDebt(msg.sender);
        Unstaking storage u = unstaking[msg.sender];
        u.amount += SafeCast.toUint128(amount);
        u.unlockTime = uint64(block.timestamp) + unstakeCooldown;
        emit UnstakeRequested(msg.sender, amount, u.unlockTime);
    }

    function withdrawUnstaked() external nonReentrant {
        Unstaking memory u = unstaking[msg.sender];
        if (u.amount == 0) revert ZeroAmount();
        if (block.timestamp < u.unlockTime) revert CooldownActive(u.unlockTime);
        delete unstaking[msg.sender];
        IERC20(hooks.projectToken()).safeTransfer(msg.sender, u.amount);
        emit Unstaked(msg.sender, u.amount);
    }

    function claim() external nonReentrant {
        _harvest(msg.sender);
        _resetDebt(msg.sender);
        uint256 n = rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address token = rewardTokens[i];
            uint256 amt = pendingRewards[msg.sender][token];
            if (amt == 0) continue;
            pendingRewards[msg.sender][token] = 0;
            stakerLiability[token] -= amt;
            IERC20(token).safeTransfer(msg.sender, amt);
            emit RewardClaimed(msg.sender, token, amt);
        }
    }

    // ------------------------------------------------------------------ views

    function rewardTokenCount() external view returns (uint256) {
        return rewardTokens.length;
    }

    function claimable(address user, address token) external view returns (uint256) {
        uint256 accrued = Math.mulDiv(stakedOf[user], accRewardPerShare[token], PRECISION);
        uint256 debt = rewardDebt[user][token];
        return pendingRewards[user][token] + (accrued > debt ? accrued - debt : 0);
    }

    // --------------------------------------------------------------- internal

    function _harvest(address user) internal {
        uint256 s = stakedOf[user];
        uint256 n = rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address token = rewardTokens[i];
            uint256 accrued = Math.mulDiv(s, accRewardPerShare[token], PRECISION);
            uint256 debt = rewardDebt[user][token];
            if (accrued > debt) pendingRewards[user][token] += accrued - debt;
        }
    }

    function _resetDebt(address user) internal {
        uint256 s = stakedOf[user];
        uint256 n = rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address token = rewardTokens[i];
            rewardDebt[user][token] = Math.mulDiv(s, accRewardPerShare[token], PRECISION);
        }
    }
}
