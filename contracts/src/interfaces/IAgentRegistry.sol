// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Tabb's view of an agent identity registry (ERC-8004 Identity Registry behind an adapter).
interface IAgentRegistry {
    function exists(uint256 agentId) external view returns (bool);
    /// @return owner current owner of the agent identity (address(0) if unknown)
    function ownerOf(uint256 agentId) external view returns (address owner);
    /// @return wallet the agent's operational wallet if published by the registry, else address(0)
    function agentWallet(uint256 agentId) external view returns (address wallet);
}
