// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BlockroomBase} from "./base/BlockroomBase.sol";
import {Actions} from "./libraries/Actions.sol";
import {IMakerRegistry, IProjectTokenHooks} from "./interfaces/IBlockroom.sol";

/// @title MakerRegistry
/// @notice Market makers post a stablecoin bond (or, once enabled, the project token at a haircut ratio).
///         The bond backs every quote they sign: if a maker cannot deliver on a signed, in-band, unexpired
///         quote (insufficient balance / allowance), Settlement slashes the bond and pays the taker.
/// @dev Withdrawals go through an unbonding period that must exceed Settlement.maxQuoteTtl, and pending
///      withdrawals remain slashable until completed - so a maker cannot dodge a slash by front-running a fill
///      with a withdrawal (anti last-look).
contract MakerRegistry is BlockroomBase, ReentrancyGuard, IMakerRegistry {
    using SafeERC20 for IERC20;

    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    uint64 public constant MIN_UNBONDING = 1 hours;
    uint64 public constant MAX_UNBONDING = 30 days;

    struct Maker {
        bool registered;
        bool suspended;
        uint32 defaults;
        uint64 unlockTime;
        uint256 stableBond;
        uint256 projectBond;
        uint256 pendingStable;
        uint256 pendingProject;
    }

    IERC20 public immutable bondToken;
    IProjectTokenHooks public immutable hooks;
    uint256 public minBond;
    uint64 public unbondingPeriod;

    mapping(address maker => Maker) internal _makers;

    error NotRegistered();
    error AlreadyRegistered();
    error ZeroAmount();
    error TokenDisabled();
    error InsufficientBond();
    error NothingPending();
    error StillUnbonding(uint64 unlockTime);

    event MakerRegistered(address indexed maker);
    event BondDeposited(address indexed maker, bool project, uint256 amount);
    event WithdrawalRequested(address indexed maker, uint256 stable, uint256 project, uint64 unlockTime);
    event WithdrawalCancelled(address indexed maker, uint256 stable, uint256 project);
    event WithdrawalCompleted(address indexed maker, uint256 stable, uint256 project);
    event MakerSlashed(
        address indexed maker, address indexed recipient, uint256 value, uint256 stablePaid, uint256 projectPaid
    );
    event MakerSuspended(address indexed maker, bool suspended);
    event MinBondSet(uint256 minBond);
    event UnbondingPeriodSet(uint64 period);

    constructor(
        address admin,
        address guardian,
        address bondToken_,
        address hooks_,
        uint256 minBond_,
        uint64 unbondingPeriod_
    ) BlockroomBase(admin, guardian) {
        if (bondToken_ == address(0) || hooks_ == address(0)) revert ZeroAddress();
        if (unbondingPeriod_ < MIN_UNBONDING || unbondingPeriod_ > MAX_UNBONDING) revert InvalidParam();
        bondToken = IERC20(bondToken_);
        hooks = IProjectTokenHooks(hooks_);
        minBond = minBond_;
        unbondingPeriod = unbondingPeriod_;
        emit MinBondSet(minBond_);
        emit UnbondingPeriodSet(unbondingPeriod_);
    }

    // ------------------------------------------------------------------ admin

    function setMinBond(uint256 minBond_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minBond = minBond_;
        emit MinBondSet(minBond_);
    }

    function setUnbondingPeriod(uint64 period) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (period < MIN_UNBONDING || period > MAX_UNBONDING) revert InvalidParam();
        unbondingPeriod = period;
        emit UnbondingPeriodSet(period);
    }

    /// @notice Guardian circuit breaker for a misbehaving maker (blocks new fills of its quotes).
    function setSuspended(address maker, bool suspended) external onlyRole(GUARDIAN_ROLE) {
        if (!_makers[maker].registered) revert NotRegistered();
        _makers[maker].suspended = suspended;
        emit MakerSuspended(maker, suspended);
    }

    // ------------------------------------------------------------------ maker

    function register() external whenNotPaused {
        _requireCompliant(msg.sender, Actions.MAKER_REGISTER);
        Maker storage m = _makers[msg.sender];
        if (m.registered) revert AlreadyRegistered();
        m.registered = true;
        emit MakerRegistered(msg.sender);
    }

    function depositBond(uint256 amount) external nonReentrant whenNotPaused {
        Maker storage m = _requireMaker(msg.sender);
        if (amount == 0) revert ZeroAmount();
        uint256 received = _pull(bondToken, amount);
        m.stableBond += received;
        emit BondDeposited(msg.sender, false, received);
    }

    function depositProjectBond(uint256 amount) external nonReentrant whenNotPaused {
        Maker storage m = _requireMaker(msg.sender);
        address token = hooks.projectToken();
        if (token == address(0)) revert TokenDisabled();
        if (amount == 0) revert ZeroAmount();
        uint256 received = _pull(IERC20(token), amount);
        m.projectBond += received;
        emit BondDeposited(msg.sender, true, received);
    }

    /// @notice Start unbonding. Funds stay slashable until `completeWithdrawal`.
    function requestWithdrawal(uint256 stable, uint256 project) external {
        Maker storage m = _requireMaker(msg.sender);
        if (stable == 0 && project == 0) revert ZeroAmount();
        if (stable > m.stableBond || project > m.projectBond) revert InsufficientBond();
        m.stableBond -= stable;
        m.projectBond -= project;
        m.pendingStable += stable;
        m.pendingProject += project;
        m.unlockTime = uint64(block.timestamp) + unbondingPeriod;
        emit WithdrawalRequested(msg.sender, stable, project, m.unlockTime);
    }

    function cancelWithdrawal() external {
        Maker storage m = _requireMaker(msg.sender);
        uint256 s = m.pendingStable;
        uint256 p = m.pendingProject;
        if (s == 0 && p == 0) revert NothingPending();
        m.pendingStable = 0;
        m.pendingProject = 0;
        m.stableBond += s;
        m.projectBond += p;
        emit WithdrawalCancelled(msg.sender, s, p);
    }

    function completeWithdrawal() external nonReentrant {
        Maker storage m = _requireMaker(msg.sender);
        uint256 s = m.pendingStable;
        uint256 p = m.pendingProject;
        if (s == 0 && p == 0) revert NothingPending();
        if (block.timestamp < m.unlockTime) revert StillUnbonding(m.unlockTime);
        m.pendingStable = 0;
        m.pendingProject = 0;
        if (s > 0) bondToken.safeTransfer(msg.sender, s);
        if (p > 0) IERC20(hooks.projectToken()).safeTransfer(msg.sender, p);
        emit WithdrawalCompleted(msg.sender, s, p);
    }

    // --------------------------------------------------------------- slashing

    /// @notice Slash up to `value` (bond-token units) from `maker` and pay it to `recipient`.
    ///         Stablecoin is taken first (active, then pending); any shortfall is covered by project token.
    function slash(address maker, address recipient, uint256 value)
        external
        nonReentrant
        onlyRole(SLASHER_ROLE)
        returns (uint256 stablePaid, uint256 projectPaid)
    {
        if (recipient == address(0)) revert ZeroAddress();
        Maker storage m = _makers[maker];
        if (!m.registered) revert NotRegistered();

        uint256 remaining = value;
        uint256 take = _min(remaining, m.stableBond);
        m.stableBond -= take;
        remaining -= take;
        stablePaid = take;
        take = _min(remaining, m.pendingStable);
        m.pendingStable -= take;
        remaining -= take;
        stablePaid += take;

        if (remaining > 0 && (m.projectBond | m.pendingProject) != 0) {
            uint256 need = hooks.projectAmountForValue(remaining);
            take = _min(need, m.projectBond);
            m.projectBond -= take;
            projectPaid = take;
            need -= take;
            take = _min(need, m.pendingProject);
            m.pendingProject -= take;
            projectPaid += take;
        }
        unchecked {
            ++m.defaults;
        }

        if (stablePaid > 0) bondToken.safeTransfer(recipient, stablePaid);
        if (projectPaid > 0) IERC20(hooks.projectToken()).safeTransfer(recipient, projectPaid);
        emit MakerSlashed(maker, recipient, value, stablePaid, projectPaid);
    }

    // ------------------------------------------------------------------ views

    function makerInfo(address maker) external view returns (Maker memory) {
        return _makers[maker];
    }

    function bondValueOf(address maker) public view returns (uint256) {
        Maker storage m = _makers[maker];
        return m.stableBond + hooks.bondValue(m.projectBond);
    }

    function slashableValue(address maker) public view returns (uint256) {
        Maker storage m = _makers[maker];
        return m.stableBond + m.pendingStable + hooks.bondValue(m.projectBond + m.pendingProject);
    }

    function canQuote(address maker) external view returns (bool) {
        Maker storage m = _makers[maker];
        return m.registered && !m.suspended && slashableValue(maker) >= minBond;
    }

    // --------------------------------------------------------------- internal

    function _requireMaker(address maker) internal view returns (Maker storage m) {
        m = _makers[maker];
        if (!m.registered) revert NotRegistered();
    }

    function _pull(IERC20 token, uint256 amount) internal returns (uint256 received) {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - before;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
