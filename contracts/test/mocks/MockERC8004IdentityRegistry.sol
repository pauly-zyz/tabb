// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Minimal ERC-8004-style Identity Registry (ERC-721 agent identities + key/value metadata).
///         Local/test only — the real registry address must be configured per chain.
contract MockERC8004IdentityRegistry is ERC721 {
    uint256 public nextId = 1;
    mapping(uint256 => mapping(string => bytes)) internal _metadata;
    mapping(uint256 => string) internal _uris;

    event Registered(uint256 indexed agentId, string tokenURI, address indexed owner);

    constructor() ERC721("Mock ERC-8004 Agent", "AGENT") {}

    function register(string calldata uri) external returns (uint256 agentId) {
        agentId = nextId++;
        _mint(msg.sender, agentId);
        _uris[agentId] = uri;
        emit Registered(agentId, uri, msg.sender);
    }

    function tokenURI(uint256 agentId) public view override returns (string memory) {
        _requireOwned(agentId);
        return _uris[agentId];
    }

    function setMetadata(uint256 agentId, string calldata key, bytes calldata value) external {
        require(ownerOf(agentId) == msg.sender, "not owner");
        _metadata[agentId][key] = value;
    }

    function getMetadata(uint256 agentId, string calldata key) external view returns (bytes memory) {
        return _metadata[agentId][key];
    }
}

/// @notice Registry without getMetadata (to test the adapter's graceful fallback).
contract MockBareERC721Registry is ERC721 {
    constructor() ERC721("Bare", "BARE") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}
