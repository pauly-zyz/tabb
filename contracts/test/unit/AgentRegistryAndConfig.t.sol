// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC8004RegistryAdapter, IERC8004IdentityRegistry} from "../../src/agent/ERC8004RegistryAdapter.sol";
import {AgentRiskConfig} from "../../src/agent/AgentRiskConfig.sol";
import {IAgentRiskConfig} from "../../src/interfaces/IAgentRiskConfig.sol";
import {AgentRiskDefaults} from "../../src/agent/AgentRiskDefaults.sol";
import {MockERC8004IdentityRegistry, MockBareERC721Registry} from "../mocks/MockERC8004IdentityRegistry.sol";

contract ERC8004RegistryAdapterTest is Test {
    MockERC8004IdentityRegistry reg;
    ERC8004RegistryAdapter adapter;
    address alice = makeAddr("alice");

    function setUp() public {
        reg = new MockERC8004IdentityRegistry();
        adapter = new ERC8004RegistryAdapter(IERC8004IdentityRegistry(address(reg)));
    }

    function test_existsAndOwner() public {
        vm.prank(alice);
        uint256 id = reg.register("ipfs://agent");
        assertTrue(adapter.exists(id));
        assertEq(adapter.ownerOf(id), alice);
        assertFalse(adapter.exists(999));
        assertEq(adapter.ownerOf(999), address(0));
        assertEq(reg.tokenURI(id), "ipfs://agent");
    }

    function test_agentWalletEncodings() public {
        vm.startPrank(alice);
        uint256 id = reg.register("x");
        assertEq(adapter.agentWallet(id), address(0));
        reg.setMetadata(id, "agentWallet", abi.encode(address(0xBEEF)));
        assertEq(adapter.agentWallet(id), address(0xBEEF));
        reg.setMetadata(id, "agentWallet", abi.encodePacked(address(0xCAFE)));
        assertEq(adapter.agentWallet(id), address(0xCAFE));
        reg.setMetadata(id, "agentWallet", hex"01");
        assertEq(adapter.agentWallet(id), address(0));
        vm.stopPrank();
    }

    function test_registryWithoutMetadata() public {
        MockBareERC721Registry bare = new MockBareERC721Registry();
        ERC8004RegistryAdapter a2 = new ERC8004RegistryAdapter(IERC8004IdentityRegistry(address(bare)));
        bare.mint(alice, 7);
        assertEq(a2.ownerOf(7), alice);
        assertEq(a2.agentWallet(7), address(0));
    }

    function test_revert_zero() public {
        vm.expectRevert(ERC8004RegistryAdapter.ZeroAddress.selector);
        new ERC8004RegistryAdapter(IERC8004IdentityRegistry(address(0)));
    }
}

contract AgentRiskConfigTest is Test {
    AgentRiskConfig cfg;
    address owner = makeAddr("owner");

    function setUp() public {
        cfg = new AgentRiskConfig(owner, address(0), AgentRiskDefaults.params(), AgentRiskDefaults.tiers(), address(0xFEE));
    }

    function test_defaults() public view {
        IAgentRiskConfig.Params memory p = cfg.params();
        assertEq(p.minStake, 100e6);
        assertEq(p.maxPerAgent, 1_000e6);
        assertEq(p.defaultSplitBps, 2_000);
        assertEq(cfg.tierCount(), 3);
        assertEq(cfg.tier(2).leverageBps, 20_000);
        assertEq(cfg.feeRecipient(), address(0xFEE));
        assertTrue(cfg.isOwnerAllowed(address(1)));
    }

    function _expectInvalid(IAgentRiskConfig.Params memory p) internal {
        vm.prank(owner);
        vm.expectRevert(AgentRiskConfig.InvalidParams.selector);
        cfg.setParams(p);
    }

    function test_paramValidation() public {
        IAgentRiskConfig.Params memory p = cfg.params();
        IAgentRiskConfig.Params memory q;
        q = p; q.minStake = 0; _expectInvalid(q);
        q = cfg.params(); q.baseLimit = 0; _expectInvalid(q);
        q = cfg.params(); q.maxPerAgent = q.maxPerOwner + 1; _expectInvalid(q);
        q = cfg.params(); q.maxPerAgent = 0; _expectInvalid(q);
        q = cfg.params(); q.minDebt = q.maxPerAgent + 1; _expectInvalid(q);
        q = cfg.params(); q.revenueAdvanceBps = 10_001; _expectInvalid(q);
        q = cfg.params(); q.minSplitBps = 400; _expectInvalid(q);
        q = cfg.params(); q.minSplitBps = q.defaultSplitBps + 1; _expectInvalid(q);
        q = cfg.params(); q.defaultSplitBps = 10_001; q.minSplitBps = 1000; _expectInvalid(q);
        q = cfg.params(); q.minPaymentBps = 99; _expectInvalid(q);
        q = cfg.params(); q.minPaymentBps = 10_001; _expectInvalid(q);
        q = cfg.params(); q.dailySpendCapBps = 0; _expectInvalid(q);
        q = cfg.params(); q.dailySpendCapBps = 10_001; _expectInvalid(q);
        q = cfg.params(); q.distributeFeeBps = 501; _expectInvalid(q);
        q = cfg.params(); q.paymentPeriod = 1 hours; _expectInvalid(q);
        q = cfg.params(); q.gracePeriod = q.paymentPeriod + 1; _expectInvalid(q);
        q = cfg.params(); q.defaultDelay = 6 days; _expectInvalid(q);
        q = cfg.params(); q.windowEpochs = 0; _expectInvalid(q);
        q = cfg.params(); q.windowEpochs = 27; _expectInvalid(q);
        q = cfg.params(); q.minStake = 1; 
        vm.prank(owner);
        cfg.setParams(q);
        assertEq(cfg.params().minStake, 1);
    }

    function _expectInvalidTiers(IAgentRiskConfig.Tier[] memory t) internal {
        vm.prank(owner);
        vm.expectRevert(AgentRiskConfig.InvalidParams.selector);
        cfg.setTiers(t);
    }

    function test_tierValidation() public {
        IAgentRiskConfig.Tier[] memory t = new IAgentRiskConfig.Tier[](0);
        _expectInvalidTiers(t);
        t = new IAgentRiskConfig.Tier[](4);
        _expectInvalidTiers(t);
        t = new IAgentRiskConfig.Tier[](1);
        t[0] = IAgentRiskConfig.Tier(0, 0, 0, 0);
        _expectInvalidTiers(t);
        t[0] = IAgentRiskConfig.Tier(0, 0, 0, 50_001);
        _expectInvalidTiers(t);
        t[0] = IAgentRiskConfig.Tier(1, 0, 0, 10_000);
        _expectInvalidTiers(t);
        t = new IAgentRiskConfig.Tier[](2);
        t[0] = IAgentRiskConfig.Tier(0, 0, 0, 20_000);
        t[1] = IAgentRiskConfig.Tier(1, 1, 0, 10_000);
        _expectInvalidTiers(t);
        t[1] = IAgentRiskConfig.Tier(1, 1, 0, 30_000);
        vm.prank(owner);
        cfg.setTiers(t);
        assertEq(cfg.tierCount(), 2);
    }

    function test_allowlistAndFee() public {
        vm.startPrank(owner);
        cfg.setOwnerAllowlistEnabled(true);
        assertFalse(cfg.isOwnerAllowed(address(1)));
        cfg.setOwnerAllowlisted(address(1), true);
        assertTrue(cfg.isOwnerAllowed(address(1)));
        cfg.setFeeRecipient(address(2));
        assertEq(cfg.feeRecipient(), address(2));
        vm.stopPrank();
    }

    function test_revert_onlyOwner() public {
        IAgentRiskConfig.Params memory p = cfg.params();
        vm.expectRevert();
        cfg.setParams(p);
    }
}

