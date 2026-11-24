// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOwnerStakeVault} from "../../src/interfaces/IOwnerStakeVault.sol";

/// @notice Stands in for AgentCreditManager when testing the vault in isolation.
contract MockStakeLocker {
    mapping(uint256 => mapping(address => bool)) public locked;

    function setLocked(uint256 agentId, address staker, bool v) external {
        locked[agentId][staker] = v;
    }

    function stakeLocked(uint256 agentId, address staker) external view returns (bool) {
        return locked[agentId][staker];
    }

    function canSpend(uint256) external pure returns (bool) {
        return true;
    }

    function dailySpendCap(uint256) external pure returns (uint256) {
        return type(uint256).max;
    }

    function payoutOf(uint256) external pure returns (address) {
        return address(0);
    }

    function processRevenue(uint256, uint256) external pure returns (address) {
        return address(0);
    }

    function slash(IOwnerStakeVault vault, uint256 agentId, address staker, uint256 amount, address to)
        external
        returns (uint256)
    {
        return vault.slash(agentId, staker, amount, to);
    }
}
