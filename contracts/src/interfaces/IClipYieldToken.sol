// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice ASSUMED interface of a Clipt stock-dividend yield token (Q-Y2 in docs/DESIGN.md). Dividends are assumed to
///         be paid in USDG and claimable per holder. Adjust YieldTokenAdapter once Clipt's real spec is available.
interface IClipYieldToken {
    function claimable(address holder) external view returns (uint256);
    function claim() external returns (uint256 amount);
    function maturity() external view returns (uint256);
}
