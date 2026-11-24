// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {TabManager} from "./TabManager.sol";

/// @title Liquidator
/// @notice Permissionless liquidation entrypoint for yield tabs with HF < 1. The caller must have approved USDG to the
///         TabManager; it repays up to the close factor and receives collateral in kind plus the liquidation bonus.
contract Liquidator {
    TabManager public immutable tabManager;

    constructor(TabManager tabManager_) {
        tabManager = tabManager_;
    }

    function liquidate(uint256 tabId, uint256 repayAmount)
        external
        returns (uint256 repaid, uint256 seized, uint256 badDebt)
    {
        return tabManager.liquidateFor(tabId, msg.sender, repayAmount);
    }
}
