// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IInterestRateModel} from "../interfaces/IInterestRateModel.sol";

/// @title InterestRateModel
/// @notice Kinked (two-slope) borrow-rate model. All values are annual, WAD (1e18 = 100%). Immutable: to change
///         parameters deploy a new model and point the pool at it.
contract InterestRateModel is IInterestRateModel {
    uint256 internal constant WAD = 1e18;
    uint256 public constant MAX_RATE = 10 * WAD; // 1000% APR hard ceiling

    uint256 public immutable baseRate;
    uint256 public immutable slope1;
    uint256 public immutable optimalUtilization;
    uint256 public immutable slope2;

    error InvalidParams();

    constructor(uint256 baseRate_, uint256 slope1_, uint256 optimalUtilization_, uint256 slope2_) {
        if (optimalUtilization_ == 0 || optimalUtilization_ >= WAD) revert InvalidParams();
        if (baseRate_ + slope1_ + slope2_ > MAX_RATE) revert InvalidParams();
        baseRate = baseRate_;
        slope1 = slope1_;
        optimalUtilization = optimalUtilization_;
        slope2 = slope2_;
    }

    function borrowRate(uint256 utilizationWad) external view returns (uint256) {
        uint256 u = utilizationWad > WAD ? WAD : utilizationWad;
        if (u <= optimalUtilization) {
            return baseRate + (slope1 * u) / optimalUtilization;
        }
        return baseRate + slope1 + (slope2 * (u - optimalUtilization)) / (WAD - optimalUtilization);
    }
}
