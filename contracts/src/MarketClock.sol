// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockroomBase} from "./base/BlockroomBase.sol";
import {IMarketClock} from "./interfaces/IBlockroom.sol";

/// @title MarketClock
/// @notice US equity regular-session clock (default 09:30-16:00 America/New_York, Mon-Fri) computed fully
///         on-chain, including the US daylight-saving rule (2nd Sunday of March -> 1st Sunday of November).
/// @dev Exchange holidays and early closes are pushed ahead of time by CALENDAR_ROLE as per-day overrides.
///      Overrides can only SHORTEN a session (close earlier or close the day), so a compromised calendar key
///      can at worst halt midpoint matching - it can never open the market outside the configured window.
///      The guardian can force-close instantly (circuit breaker).
contract MarketClock is BlockroomBase, IMarketClock {
    bytes32 public constant CALENDAR_ROLE = keccak256("CALENDAR_ROLE");

    uint16 public constant CLOSED = type(uint16).max;
    uint256 public constant MAX_OVERRIDES_PER_CALL = 64;

    uint16 public openMinute = 570; // 09:30 ET
    uint16 public closeMinute = 960; // 16:00 ET
    bool public forceClosed;

    /// @dev key = ET calendar day index (days since 1970-01-01 in ET), value = close minute or CLOSED.
    mapping(uint256 day => uint16 closeOverride) public sessionOverride;

    event SessionHoursSet(uint16 openMinute, uint16 closeMinute);
    event SessionOverrideSet(uint256 indexed day, uint16 closeMinute);
    event ForceClosedSet(bool closed);

    constructor(address admin, address guardian, address calendar) BlockroomBase(admin, guardian) {
        if (calendar != address(0)) _grantRole(CALENDAR_ROLE, calendar);
    }

    function setSessionHours(uint16 open_, uint16 close_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (open_ >= close_ || close_ > 1440) revert InvalidParam();
        openMinute = open_;
        closeMinute = close_;
        emit SessionHoursSet(open_, close_);
    }

    /// @param days_ ET day indexes (see `etDayIndex`)
    /// @param closes_ new close minute (must be <= regular close) or CLOSED; 0 clears the override
    function setSessionOverrides(uint256[] calldata days_, uint16[] calldata closes_)
        external
        onlyRole(CALENDAR_ROLE)
    {
        uint256 n = days_.length;
        if (n != closes_.length || n > MAX_OVERRIDES_PER_CALL) revert InvalidParam();
        for (uint256 i; i < n; ++i) {
            uint16 c = closes_[i];
            if (c != 0 && c != CLOSED && c > closeMinute) revert InvalidParam();
            sessionOverride[days_[i]] = c;
            emit SessionOverrideSet(days_[i], c);
        }
    }

    function setForceClosed(bool closed) external onlyRole(GUARDIAN_ROLE) {
        forceClosed = closed;
        emit ForceClosedSet(closed);
    }

    // ------------------------------------------------------------------ views

    function isOpen() external view returns (bool) {
        return isOpenAt(block.timestamp);
    }

    /// @dev Slither's weak-prng / incorrect-equality detectors fire on the calendar modulo arithmetic below;
    ///      no randomness is involved (pure date math on block.timestamp).
    // slither-disable-start weak-prng,incorrect-equality,divide-before-multiply
    function isOpenAt(uint256 ts) public view returns (bool) {
        if (forceClosed) return false;
        uint256 local = toEasternTime(ts);
        uint256 day = local / 1 days;
        uint256 weekday = (day + 4) % 7; // 0 = Sunday (1970-01-01 was a Thursday)
        if (weekday == 0 || weekday == 6) return false;
        uint16 ov = sessionOverride[day];
        if (ov == CLOSED) return false;
        uint256 close = ov == 0 ? closeMinute : ov;
        uint256 minute = (local % 1 days) / 60;
        return minute >= openMinute && minute < close;
    }

    /// @notice ET day index for a timestamp (use this to compute override keys).
    function etDayIndex(uint256 ts) external pure returns (uint256) {
        return toEasternTime(ts) / 1 days;
    }

    /// @notice Seconds since epoch shifted to America/New_York wall-clock.
    function toEasternTime(uint256 ts) public pure returns (uint256) {
        return isUsDst(ts) ? ts - 4 hours : ts - 5 hours;
    }

    /// @notice US DST: from 2nd Sunday of March 02:00 EST (07:00 UTC) to 1st Sunday of November 02:00 EDT (06:00 UTC).
    function isUsDst(uint256 ts) public pure returns (bool) {
        uint256 year = _yearOf(ts / 1 days);
        uint256 mar1 = _daysFromCivil(year, 3, 1);
        uint256 dstStart = (_nextSunday(mar1) + 7) * 1 days + 7 hours;
        uint256 nov1 = _daysFromCivil(year, 11, 1);
        uint256 dstEnd = _nextSunday(nov1) * 1 days + 6 hours;
        return ts >= dstStart && ts < dstEnd;
    }

    function _nextSunday(uint256 day) private pure returns (uint256) {
        uint256 wd = (day + 4) % 7;
        return day + ((7 - wd) % 7);
    }

    /// @dev Howard Hinnant's days_from_civil, restricted to years >= 1970.
    function _daysFromCivil(uint256 y, uint256 m, uint256 d) private pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146_097 + doe - 719_468;
    }

    /// @dev Inverse of _daysFromCivil (year component only).
    function _yearOf(uint256 z) private pure returns (uint256) {
        z += 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        uint256 y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;
        return m <= 2 ? y + 1 : y;
    }
    // slither-disable-end weak-prng,incorrect-equality,divide-before-multiply
}
