// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TabbAccessControl} from "../access/TabbAccessControl.sol";
import {IOracleRouter} from "../interfaces/IOracleRouter.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @title OracleRouter
/// @notice Validated Chainlink reads for Phase 2: answer > 0, complete round, per-feed staleness (separate heartbeat
///         while the market is closed, for liquidations only) and L2 sequencer uptime + grace period. Market status
///         comes from a status feed when configured (answer 1 = open) or from a manual flag set by market keepers.
contract OracleRouter is IOracleRouter, TabbAccessControl {
    struct FeedConfig {
        IAggregatorV3 feed;
        uint32 heartbeatOpen;
        uint32 heartbeatClosed;
    }

    mapping(address => FeedConfig) public feeds;
    mapping(address => IAggregatorV3) public marketStatusFeed;
    mapping(address => bool) public manualMarketClosed; // default false = open
    mapping(address => bool) public isMarketKeeper;

    IAggregatorV3 public sequencerFeed;
    uint256 public sequencerGracePeriod = 3600;
    bool public sequencerCheckEnabled;

    event FeedSet(address indexed asset, address feed, uint32 heartbeatOpen, uint32 heartbeatClosed);
    event MarketStatusFeedSet(address indexed asset, address feed);
    event MarketStatusSet(address indexed asset, bool open, address by);
    event MarketKeeperSet(address indexed keeper, bool enabled);
    event SequencerSet(address feed, uint256 grace, bool enabled);

    error NoFeed();
    error InvalidPrice();
    error StalePrice();
    error SequencerDown();
    error GracePeriodNotOver();
    error NotMarketKeeper();
    error InvalidParam();

    constructor(address owner_, address guardian_) TabbAccessControl(owner_, guardian_) {}

    // ------------------------------------------------------------------ admin

    function setFeed(address asset, IAggregatorV3 feed, uint32 heartbeatOpen, uint32 heartbeatClosed)
        external
        onlyOwner
    {
        if (asset == address(0)) revert ZeroAddress();
        if (address(feed) != address(0) && (heartbeatOpen == 0 || heartbeatClosed < heartbeatOpen)) {
            revert InvalidParam();
        }
        feeds[asset] = FeedConfig(feed, heartbeatOpen, heartbeatClosed);
        emit FeedSet(asset, address(feed), heartbeatOpen, heartbeatClosed);
    }

    function setMarketStatusFeed(address asset, IAggregatorV3 feed) external onlyOwner {
        marketStatusFeed[asset] = feed;
        emit MarketStatusFeedSet(asset, address(feed));
    }

    function setMarketKeeper(address keeper, bool enabled) external onlyOwner {
        isMarketKeeper[keeper] = enabled;
        emit MarketKeeperSet(keeper, enabled);
    }

    /// @notice Manual market-status fallback (used when no status feed is configured).
    function setMarketOpen(address asset, bool open) external {
        if (!isMarketKeeper[msg.sender] && msg.sender != owner()) revert NotMarketKeeper();
        manualMarketClosed[asset] = !open;
        emit MarketStatusSet(asset, open, msg.sender);
    }

    function setSequencer(IAggregatorV3 feed, uint256 grace, bool enabled) external onlyOwner {
        if (enabled && address(feed) == address(0)) revert ZeroAddress();
        if (grace > 1 days) revert InvalidParam();
        sequencerFeed = feed;
        sequencerGracePeriod = grace;
        sequencerCheckEnabled = enabled;
        emit SequencerSet(address(feed), grace, enabled);
    }

    // ------------------------------------------------------------------ views

    function isSequencerHealthy() public view returns (bool) {
        if (!sequencerCheckEnabled) return true;
        (, int256 answer, uint256 startedAt,,) = sequencerFeed.latestRoundData();
        return answer == 0 && startedAt != 0 && block.timestamp - startedAt > sequencerGracePeriod;
    }

    function isMarketOpen(address asset) public view returns (bool) {
        IAggregatorV3 f = marketStatusFeed[asset];
        if (address(f) != address(0)) {
            if (address(f).code.length == 0) return false; // fail closed
            try f.latestRoundData() returns (uint80, int256 answer, uint256, uint256, uint80) {
                return answer == 1;
            } catch {
                return false; // fail closed
            }
        }
        return !manualMarketClosed[asset];
    }

    function getPrice(address asset, Purpose purpose) external view returns (uint256) {
        FeedConfig memory c = feeds[asset];
        if (address(c.feed) == address(0)) revert NoFeed();
        if (purpose != Purpose.VIEW && sequencerCheckEnabled) {
            (, int256 seq, uint256 startedAt,,) = sequencerFeed.latestRoundData();
            if (seq != 0) revert SequencerDown();
            if (block.timestamp - startedAt <= sequencerGracePeriod) revert GracePeriodNotOver();
        }
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = c.feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (updatedAt == 0 || answeredInRound < roundId) revert StalePrice();
        if (purpose != Purpose.VIEW) {
            uint256 hb = (purpose == Purpose.LIQUIDATION && !isMarketOpen(asset)) ? c.heartbeatClosed : c.heartbeatOpen;
            if (block.timestamp - updatedAt > hb) revert StalePrice();
        }
        uint8 dec = c.feed.decimals();
        return Math.mulDiv(uint256(answer), 1e18, 10 ** dec);
    }
}
