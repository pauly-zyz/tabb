// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Phase 2: validated Chainlink reads (staleness, answer > 0, L2 sequencer uptime + grace).
interface IOracleRouter {
    enum Purpose {
        BORROW, // strict: normal heartbeat, sequencer up and past grace
        LIQUIDATION, // tolerant heartbeat while the market is closed
        VIEW
    }

    /// @return priceWad price of `asset` in USD, 18 decimals
    function getPrice(address asset, Purpose purpose) external view returns (uint256 priceWad);
    function isMarketOpen(address asset) external view returns (bool);
    function isSequencerHealthy() external view returns (bool);
}
