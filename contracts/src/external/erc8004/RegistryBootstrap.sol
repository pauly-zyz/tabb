// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title RegistryBootstrap
/// @notice First implementation behind a self-hosted ERC-8004 IdentityRegistry proxy. Sets the owner (initializer
///         version 1) so the owner can upgrade to `IdentityRegistryUpgradeable` and call its `initialize()`
///         (reinitializer(2), onlyOwner). Mirrors upstream MinimalUUPS without the hard-coded owner. Storage slot 0
///         is left unused, exactly like MinimalUUPS' `_identityRegistry` slot.
contract RegistryBootstrap is OwnableUpgradeable, UUPSUpgradeable {
    address private _unusedSlot0;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
