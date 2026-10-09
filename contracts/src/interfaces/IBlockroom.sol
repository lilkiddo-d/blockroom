// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Chainlink-compatible aggregator (subset). Robinhood Chain feeds implement this interface.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Swappable price source. All prices are "quote-token units per one whole base token".
interface IOracleAdapter {
    function getMid(address base, address quote) external view returns (uint256 price, uint256 updatedAt);
    function isSupported(address asset) external view returns (bool);
}

interface IPriceGuard {
    function getMid(address base, address quote) external view returns (uint256 mid);
    function checkPrice(address base, address quote, uint256 price) external view returns (uint256 mid);
    function bandBps(address base) external view returns (uint256);
}

interface IMarketClock {
    function isOpen() external view returns (bool);
    function isOpenAt(uint256 timestamp) external view returns (bool);
}

interface IComplianceHook {
    function isAllowed(address account, bytes32 action) external view returns (bool);
}

interface IStakingSource {
    function stakedOf(address account) external view returns (uint256);
}

interface IProjectTokenHooks {
    function projectToken() external view returns (address);
    function tokenEnabled() external view returns (bool);
    function bondValue(uint256 projectAmount) external view returns (uint256);
    function projectAmountForValue(uint256 value) external view returns (uint256);
    function feeDiscountBps(address account) external view returns (uint256);
    function stakerShareBps() external view returns (uint256);
}

interface IFeeCollector {
    function notifyFee(address token, uint256 amount) external;
}

interface IMakerRegistry {
    function canQuote(address maker) external view returns (bool);
    function slash(address maker, address recipient, uint256 value)
        external
        returns (uint256 stablePaid, uint256 projectPaid);
    function slashableValue(address maker) external view returns (uint256);
}
