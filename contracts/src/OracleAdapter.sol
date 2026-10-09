// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BlockroomBase} from "./base/BlockroomBase.sol";
import {AggregatorV3Interface, IOracleAdapter} from "./interfaces/IBlockroom.sol";

/// @title OracleAdapter (Chainlink Data Feeds)
/// @notice Reads Chainlink AggregatorV3 feeds on Robinhood Chain and returns a quote-denominated mid.
///         Price unit everywhere in Blockroom: quote-token base units per ONE WHOLE base token.
/// @dev Swappable: PriceGuard points at an IOracleAdapter and the Timelock can repoint it (e.g. to a
///      Data Streams adapter that exposes a true bid/ask mid). Checks: positive answer, non-future and
///      non-stale timestamp, optional secondary-feed deviation bound, optional quote-stablecoin peg bound,
///      optional L2 sequencer-uptime feed (none is published for Robinhood Chain yet - see docs/ORACLES.md).
contract OracleAdapter is BlockroomBase, IOracleAdapter {
    struct FeedConfig {
        AggregatorV3Interface primary;
        AggregatorV3Interface secondary; // optional cross-check feed
        uint32 maxStaleness; // seconds
        uint16 maxDeviationBps; // primary vs secondary
        uint16 pegToleranceBps; // for quote tokens only: |price - $1| bound
        uint8 feedDecimals;
        uint8 tokenDecimals;
        bool isQuote;
    }

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    mapping(address asset => FeedConfig) internal _feeds;
    AggregatorV3Interface public sequencerUptimeFeed;
    uint32 public sequencerGracePeriod;

    error UnsupportedAsset(address asset);
    error InvalidAnswer(address feed);
    error StalePrice(address feed, uint256 updatedAt);
    error FeedDeviation(address asset, uint256 primary, uint256 secondary);
    error Depegged(address quote, uint256 price);
    error SequencerDown();
    error GracePeriodNotOver();

    event FeedSet(
        address indexed asset,
        address primary,
        address secondary,
        uint32 maxStaleness,
        uint16 maxDeviationBps,
        uint16 pegToleranceBps,
        uint8 tokenDecimals,
        bool isQuote
    );
    event FeedRemoved(address indexed asset);
    event SequencerFeedSet(address feed, uint32 gracePeriod);

    constructor(address admin, address guardian) BlockroomBase(admin, guardian) {}

    // ------------------------------------------------------------------ admin

    function setFeed(
        address asset,
        address primary,
        address secondary,
        uint32 maxStaleness,
        uint16 maxDeviationBps,
        uint16 pegToleranceBps,
        uint8 tokenDecimals,
        bool isQuote
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0) || primary == address(0)) revert ZeroAddress();
        if (maxStaleness == 0 || maxDeviationBps > BPS || pegToleranceBps > BPS || tokenDecimals > 36) {
            revert InvalidParam();
        }
        uint8 feedDecimals = AggregatorV3Interface(primary).decimals();
        if (feedDecimals > 36) revert InvalidParam();
        if (secondary != address(0) && AggregatorV3Interface(secondary).decimals() > 36) revert InvalidParam();
        _feeds[asset] = FeedConfig({
            primary: AggregatorV3Interface(primary),
            secondary: AggregatorV3Interface(secondary),
            maxStaleness: maxStaleness,
            maxDeviationBps: maxDeviationBps,
            pegToleranceBps: pegToleranceBps,
            feedDecimals: feedDecimals,
            tokenDecimals: tokenDecimals,
            isQuote: isQuote
        });
        emit FeedSet(asset, primary, secondary, maxStaleness, maxDeviationBps, pegToleranceBps, tokenDecimals, isQuote);
    }

    function removeFeed(address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        delete _feeds[asset];
        emit FeedRemoved(asset);
    }

    function setSequencerUptimeFeed(address feed, uint32 gracePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        sequencerUptimeFeed = AggregatorV3Interface(feed);
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedSet(feed, gracePeriod);
    }

    // ------------------------------------------------------------------ views

    function feedConfig(address asset) external view returns (FeedConfig memory) {
        return _feeds[asset];
    }

    function isSupported(address asset) external view returns (bool) {
        return address(_feeds[asset].primary) != address(0);
    }

    /// @notice Mid price of `base` in `quote` units per one whole base token.
    function getMid(address base, address quote) external view returns (uint256 price, uint256 updatedAt) {
        _checkSequencer();
        FeedConfig memory b = _feeds[base];
        FeedConfig memory q = _feeds[quote];
        if (address(b.primary) == address(0) || b.isQuote) revert UnsupportedAsset(base);
        if (address(q.primary) == address(0) || !q.isQuote) revert UnsupportedAsset(quote);

        (uint256 baseUsd, uint256 tB) = _read(base, b); // 1e18-scaled USD
        (uint256 quoteUsd, uint256 tQ) = _read(quote, q); // 1e18-scaled USD
        uint256 pegDiff = quoteUsd > WAD ? quoteUsd - WAD : WAD - quoteUsd;
        if (pegDiff * BPS > WAD * q.pegToleranceBps) revert Depegged(quote, quoteUsd);

        price = Math.mulDiv(baseUsd, 10 ** q.tokenDecimals, quoteUsd);
        updatedAt = tB < tQ ? tB : tQ;
    }

    // --------------------------------------------------------------- internal

    // Unused latestRoundData() members are intentionally ignored (startedAt for price feeds; round ids for the
    // uptime feed), per Chainlink's documented usage.
    // slither-disable-start unused-return

    function _read(address asset, FeedConfig memory c) internal view returns (uint256 wad, uint256 updatedAt) {
        (wad, updatedAt) = _readFeed(c.primary, c.feedDecimals, c.maxStaleness);
        if (address(c.secondary) != address(0)) {
            (uint256 wad2,) = _readFeed(c.secondary, c.secondary.decimals(), c.maxStaleness);
            uint256 diff = wad > wad2 ? wad - wad2 : wad2 - wad;
            if (diff * BPS > wad * c.maxDeviationBps) revert FeedDeviation(asset, wad, wad2);
        }
    }

    function _readFeed(AggregatorV3Interface feed, uint8 decimals, uint32 maxStaleness)
        internal
        view
        returns (uint256 wad, uint256 updatedAt)
    {
        // startedAt is irrelevant for price feeds (only used for the sequencer-uptime feed).
        (uint80 roundId, int256 answer,, uint256 ts, uint80 answeredInRound) = feed.latestRoundData();
        if (answer <= 0 || answeredInRound < roundId) revert InvalidAnswer(address(feed));
        if (ts == 0 || ts > block.timestamp) revert InvalidAnswer(address(feed));
        if (block.timestamp - ts > maxStaleness) revert StalePrice(address(feed), ts);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 raw = uint256(answer);
        wad = decimals <= 18 ? raw * 10 ** (18 - decimals) : raw / 10 ** (decimals - 18);
        if (wad == 0) revert InvalidAnswer(address(feed));
        updatedAt = ts;
    }

    function _checkSequencer() internal view {
        AggregatorV3Interface feed = sequencerUptimeFeed;
        if (address(feed) == address(0)) return;
        // Chainlink L2 sequencer-uptime feed: answer 0 = up; startedAt = last status change.
        (, int256 answer, uint256 startedAt,,) = feed.latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (block.timestamp - startedAt <= sequencerGracePeriod) revert GracePeriodNotOver();
    }
    // slither-disable-end unused-return
}
