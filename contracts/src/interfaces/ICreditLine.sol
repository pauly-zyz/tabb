// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Common surface of every credit line that borrows from a TabbPool
///         (Phase 1: AgentCreditManager, Phase 2: TabManager).
interface ICreditLine {
    function pool() external view returns (address);
    /// @notice Sum of the scaled debt of all positions managed by this credit line.
    function totalScaledDebt() external view returns (uint256);
    function creditLineKind() external pure returns (bytes32);
}
