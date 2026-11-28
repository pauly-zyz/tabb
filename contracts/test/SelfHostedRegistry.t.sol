// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RegistryBootstrap} from "../src/external/erc8004/RegistryBootstrap.sol";
import {IdentityRegistryUpgradeable} from "../src/external/erc8004/IdentityRegistryUpgradeable.sol";
import {ERC8004RegistryAdapter, IERC8004IdentityRegistry} from "../src/agent/ERC8004RegistryAdapter.sol";

/// @notice Self-hosted ERC-8004 registry (used on Elysium) is wired exactly like DeployElysium and works with Tabb's
///         registry adapter.
contract SelfHostedRegistryTest is Test {
    address deployer = makeAddr("deployer");
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    IdentityRegistryUpgradeable reg;
    ERC8004RegistryAdapter adapter;

    function setUp() public {
        vm.startPrank(deployer);
        address bootstrap = address(new RegistryBootstrap());
        address impl = address(new IdentityRegistryUpgradeable());
        address proxy = address(new ERC1967Proxy(bootstrap, abi.encodeCall(RegistryBootstrap.initialize, (deployer))));
        RegistryBootstrap(proxy).upgradeToAndCall(impl, abi.encodeCall(IdentityRegistryUpgradeable.initialize, ()));
        reg = IdentityRegistryUpgradeable(proxy);
        reg.register("ipfs://tabb-reserved-agent-0");
        reg.transferFrom(deployer, owner, 0);
        reg.transferOwnership(owner);
        vm.stopPrank();
        adapter = new ERC8004RegistryAdapter(IERC8004IdentityRegistry(address(reg)));
    }

    function test_InitAndOwnership() public view {
        assertEq(reg.name(), "AgentIdentity");
        assertEq(reg.symbol(), "AGENT");
        assertEq(reg.owner(), owner);
        assertEq(reg.ownerOf(0), owner);
        assertEq(reg.getVersion(), "2.0.0");
    }

    function test_PublicIdsStartAtOne_AdapterReadsOwnerAndWallet() public {
        vm.prank(alice);
        uint256 id = reg.register("ipfs://alice-agent");
        assertEq(id, 1);
        assertEq(adapter.ownerOf(1), alice);
        assertTrue(adapter.exists(1));
        assertEq(adapter.agentWallet(1), alice); // 20-byte packed metadata
        assertEq(adapter.ownerOf(999), address(0));
        assertFalse(adapter.exists(999));
    }

    function test_TransferMovesOwnershipAndClearsWallet() public {
        vm.prank(alice);
        reg.register();
        vm.prank(alice);
        reg.transferFrom(alice, bob, 1);
        assertEq(adapter.ownerOf(1), bob);
        assertEq(adapter.agentWallet(1), address(0));
    }

    function test_OnlyOwnerCanUpgrade_ImplsLocked() public {
        address newImpl = address(new IdentityRegistryUpgradeable());
        vm.prank(deployer);
        vm.expectRevert();
        reg.upgradeToAndCall(newImpl, "");
        vm.prank(owner);
        reg.upgradeToAndCall(newImpl, "");
        // implementation contracts cannot be initialized directly
        RegistryBootstrap fresh = new RegistryBootstrap();
        vm.expectRevert();
        fresh.initialize(alice);
    }

    function test_ReinitializeBlocked() public {
        vm.prank(owner);
        vm.expectRevert();
        reg.initialize();
    }
}
