// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TabbMath
/// @notice Fixed-point helpers. RAY = 1e27 (interest indexes), WAD = 1e18 (rates/prices), BPS = 1e4.
library TabbMath {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;

    /// @dev Scaled -> assets, rounding up (used for debt, protocol-favourable).
    function toAssetsUp(uint256 scaled, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(scaled, index, RAY, Math.Rounding.Ceil);
    }

    /// @dev Scaled -> assets, rounding down.
    function toAssetsDown(uint256 scaled, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(scaled, index, RAY, Math.Rounding.Floor);
    }

    /// @dev Assets -> scaled, rounding up (used when adding debt).
    function toScaledUp(uint256 assets, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(assets, RAY, index, Math.Rounding.Ceil);
    }

    /// @dev Assets -> scaled, rounding down (used when burning debt from a payment).
    function toScaledDown(uint256 assets, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(assets, RAY, index, Math.Rounding.Floor);
    }

    function bps(uint256 amount, uint256 bpsValue) internal pure returns (uint256) {
        return Math.mulDiv(amount, bpsValue, BPS);
    }

    /// @dev Linear growth factor over `dt` for an annual WAD rate, expressed in RAY.
    function growthFactor(uint256 ratePerYearWad, uint256 dt) internal pure returns (uint256) {
        return RAY + Math.mulDiv(ratePerYearWad * 1e9, dt, YEAR);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
