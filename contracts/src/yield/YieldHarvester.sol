// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {TabManager} from "./TabManager.sol";

/// @title YieldHarvester
/// @notice Permissionless keeper entrypoint: harvest a tab's yield, earn a small reward, repay interest then principal.
contract YieldHarvester {
    TabManager public immutable tabManager;

    event HarvestFailed(uint256 indexed tabId, bytes reason);

    constructor(TabManager tabManager_) {
        tabManager = tabManager_;
    }

    function harvest(uint256 tabId)
        external
        returns (uint256 yield_, uint256 reward, uint256 repaid, uint256 credited)
    {
        return tabManager.harvestFor(tabId, msg.sender);
    }

    /// @notice Best-effort batch harvest; failures (e.g. below min harvest) are skipped.
    function harvestMany(uint256[] calldata tabIds) external returns (uint256 succeeded, uint256 totalReward) {
        for (uint256 i; i < tabIds.length; ++i) {
            try tabManager.harvestFor(tabIds[i], msg.sender) returns (uint256, uint256 reward, uint256, uint256) {
                succeeded++;
                totalReward += reward;
            } catch (bytes memory reason) {
                emit HarvestFailed(tabIds[i], reason);
            }
        }
    }
}
