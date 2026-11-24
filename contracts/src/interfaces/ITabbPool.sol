// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Credit-line facing API of TabbPool.
interface ITabbPool {
    function accrue() external;
    /// @notice Borrow `amount` of asset to `to`. Returns the scaled debt added (rounded up).
    function draw(uint256 amount, address to) external returns (uint256 scaledAdded);
    /// @notice Burn `scaled` debt; pool pulls the corresponding asset amount (rounded up) from the caller.
    function repay(uint256 scaled) external returns (uint256 assetsPaid);
    /// @notice Write off `scaled` debt as bad debt. Returns the asset value of the loss.
    function writeOff(uint256 scaled) external returns (uint256 loss);
    function indexOf(address line) external view returns (uint256);
    function scaledDebtOf(address line) external view returns (uint256);
    function debtOf(address line) external view returns (uint256);
    function availableLiquidity() external view returns (uint256);
}
