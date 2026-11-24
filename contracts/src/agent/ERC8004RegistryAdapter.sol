// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IAgentRegistry} from "../interfaces/IAgentRegistry.sol";

/// @notice Subset of the ERC-8004 Identity Registry used by Tabb. The standard is still evolving; only this
///         adapter depends on it. `ownerOf` (ERC-721) is required; `getMetadata` is optional.
interface IERC8004IdentityRegistry {
    function ownerOf(uint256 agentId) external view returns (address);
    function getMetadata(uint256 agentId, string calldata key) external view returns (bytes memory);
}

/// @title ERC8004RegistryAdapter
/// @notice Read-only adapter from an ERC-8004 Identity Registry to Tabb's IAgentRegistry.
contract ERC8004RegistryAdapter is IAgentRegistry {
    IERC8004IdentityRegistry public immutable identityRegistry;
    string public constant AGENT_WALLET_KEY = "agentWallet";

    error ZeroAddress();

    constructor(IERC8004IdentityRegistry identityRegistry_) {
        if (address(identityRegistry_) == address(0)) revert ZeroAddress();
        identityRegistry = identityRegistry_;
    }

    function ownerOf(uint256 agentId) public view returns (address owner) {
        try identityRegistry.ownerOf(agentId) returns (address o) {
            owner = o;
        } catch {
            owner = address(0);
        }
    }

    function exists(uint256 agentId) external view returns (bool) {
        return ownerOf(agentId) != address(0);
    }

    function agentWallet(uint256 agentId) external view returns (address wallet) {
        try identityRegistry.getMetadata(agentId, AGENT_WALLET_KEY) returns (bytes memory b) {
            if (b.length == 32) {
                wallet = abi.decode(b, (address));
            } else if (b.length == 20) {
                wallet = address(bytes20(b));
            }
        } catch {
            wallet = address(0);
        }
    }
}
