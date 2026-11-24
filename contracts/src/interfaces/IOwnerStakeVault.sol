// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IOwnerStakeVault {
    function stakeOf(uint256 agentId, address staker) external view returns (uint256);
    function slash(uint256 agentId, address staker, uint256 amount, address to) external returns (uint256 slashed);
}
