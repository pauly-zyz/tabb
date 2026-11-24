// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {TabbAccessControl} from "../access/TabbAccessControl.sol";

/// @title YieldRiskConfig
/// @notice Phase 2 risk parameters per collateral adapter plus global liquidation / harvest parameters.
contract YieldRiskConfig is TabbAccessControl {
    enum Status {
        None,
        Active, // all actions
        Frozen, // no new borrows / opens; repay, add collateral, withdraw (if healthy), harvest, liquidation allowed
        Disabled // only repay, harvest and liquidation
    }

    struct CollateralParams {
        Status status;
        uint16 maxLtvBps;
        uint16 liqThresholdBps;
        uint16 liqBonusBps;
        uint16 closedMarketLtvBps; // 0 = borrowing frozen while the market is closed
        uint256 supplyCap; // collateral value cap, USDG units
        uint256 borrowCap; // principal cap, USDG units
    }

    struct GlobalParams {
        uint16 closeFactorBps;
        uint64 fullLiquidationHfWad; // below this HF the whole debt can be liquidated
        uint256 dustDebt; // below this debt the whole debt can be liquidated
        uint256 minDebt;
        uint16 harvestRewardBps;
        uint256 maxHarvestReward;
        uint256 minHarvest;
    }

    mapping(address adapter => CollateralParams) internal _collateral;
    address[] public adapters;
    GlobalParams internal _global;

    event CollateralSet(address indexed adapter, CollateralParams p);
    event GlobalSet(GlobalParams p);

    error InvalidParams();

    constructor(address owner_, address guardian_, GlobalParams memory g) TabbAccessControl(owner_, guardian_) {
        _setGlobal(g);
    }

    function defaultGlobal() external pure returns (GlobalParams memory) {
        return GlobalParams({
            closeFactorBps: 5_000,
            fullLiquidationHfWad: 0.95e18,
            dustDebt: 100e6,
            minDebt: 10e6,
            harvestRewardBps: 50,
            maxHarvestReward: 25e6,
            minHarvest: 1e6
        });
    }

    function collateral(address adapter) external view returns (CollateralParams memory) {
        return _collateral[adapter];
    }

    function global() external view returns (GlobalParams memory) {
        return _global;
    }

    function adapterCount() external view returns (uint256) {
        return adapters.length;
    }

    function setCollateral(address adapter, CollateralParams calldata p) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        if (p.status == Status.None) revert InvalidParams();
        if (p.maxLtvBps == 0 || p.maxLtvBps >= p.liqThresholdBps || p.liqThresholdBps > 9_500) revert InvalidParams();
        if (p.liqBonusBps > 2_000) revert InvalidParams();
        // LT * (1 + bonus) < 100% so a liquidation never seizes more than the position is worth at the threshold
        if (uint256(p.liqThresholdBps) * (10_000 + p.liqBonusBps) >= 10_000 * 10_000) revert InvalidParams();
        if (p.closedMarketLtvBps > p.maxLtvBps) revert InvalidParams();
        if (_collateral[adapter].status == Status.None) adapters.push(adapter);
        _collateral[adapter] = p;
        emit CollateralSet(adapter, p);
    }

    function setGlobal(GlobalParams calldata g) external onlyOwner {
        _setGlobal(g);
    }

    function _setGlobal(GlobalParams memory g) internal {
        if (g.closeFactorBps == 0 || g.closeFactorBps > 10_000) revert InvalidParams();
        if (g.fullLiquidationHfWad > 1e18) revert InvalidParams();
        if (g.harvestRewardBps > 500) revert InvalidParams();
        _global = g;
        emit GlobalSet(g);
    }
}
