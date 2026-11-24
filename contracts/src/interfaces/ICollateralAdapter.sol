// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Phase 2: abstraction over a yield-bearing collateral asset (custody per tab, valuation, harvest).
interface ICollateralAdapter {
    function asset() external view returns (address);
    function usdg() external view returns (address);

    function balanceOf(uint256 tabId) external view returns (uint256);
    /// @notice Collateral value in USDG units, haircut applied, rounded down.
    function valueInUSDG(uint256 tabId) external view returns (uint256);
    function valueOfAmount(uint256 amount) external view returns (uint256);
    function amountForValue(uint256 usdgValue) external view returns (uint256);
    /// @notice USDG that harvest(tabId) would currently realize.
    function pendingYield(uint256 tabId) external view returns (uint256);
    /// @notice True if subject to "market closed" restrictions (equity-linked).
    function isEquityLinked() external view returns (bool);

    // onlyTabManager
    function deposit(uint256 tabId, address from, uint256 amount) external;
    function withdraw(uint256 tabId, address to, uint256 amount) external;
    function seize(uint256 tabId, address to, uint256 amount) external;
    function harvest(uint256 tabId, address to) external returns (uint256 usdgOut);
}
