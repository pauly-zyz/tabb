// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IInterestRateModel {
    /// @param utilizationWad pool utilization, 1e18 = 100%
    /// @return ratePerYearWad annual borrow rate, 1e18 = 100%
    function borrowRate(uint256 utilizationWad) external view returns (uint256 ratePerYearWad);
}
