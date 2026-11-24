// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TabbPool} from "../../src/pool/TabbPool.sol";
import {InterestRateModel} from "../../src/pool/InterestRateModel.sol";
import {ERC8004RegistryAdapter, IERC8004IdentityRegistry} from "../../src/agent/ERC8004RegistryAdapter.sol";
import {AgentRiskConfig} from "../../src/agent/AgentRiskConfig.sol";
import {AgentRiskDefaults} from "../../src/agent/AgentRiskDefaults.sol";
import {OwnerStakeVault} from "../../src/agent/OwnerStakeVault.sol";
import {AgentCreditScore} from "../../src/agent/AgentCreditScore.sol";
import {PayeeRegistry} from "../../src/agent/PayeeRegistry.sol";
import {PolicyAccount} from "../../src/agent/PolicyAccount.sol";
import {RepaymentSplitter} from "../../src/agent/RepaymentSplitter.sol";
import {AgentCreditManager} from "../../src/agent/AgentCreditManager.sol";
import {ITabbPool} from "../../src/interfaces/ITabbPool.sol";
import {IAgentRegistry} from "../../src/interfaces/IAgentRegistry.sol";
import {IAgentRiskConfig} from "../../src/interfaces/IAgentRiskConfig.sol";
import {IAgentCreditScore} from "../../src/interfaces/IAgentCreditScore.sol";
import {IOwnerStakeVault} from "../../src/interfaces/IOwnerStakeVault.sol";
import {IPayeeRegistry} from "../../src/interfaces/IPayeeRegistry.sol";
import {IAgentCreditManager} from "../../src/interfaces/IAgentCreditManager.sol";

import {MockUSDG} from "../mocks/MockUSDG.sol";
import {MockERC8004IdentityRegistry} from "../mocks/MockERC8004IdentityRegistry.sol";
import {MockService} from "../mocks/MockService.sol";

contract AgentFixture is Test {
    uint256 internal constant ONE = 1e6;

    MockUSDG internal usdg;
    InterestRateModel internal irm;
    TabbPool internal pool;
    MockERC8004IdentityRegistry internal idReg;
    ERC8004RegistryAdapter internal registry;
    AgentRiskConfig internal cfg;
    OwnerStakeVault internal vault;
    AgentCreditScore internal score;
    PayeeRegistry internal payees;
    AgentCreditManager internal mgr;
    MockService internal service;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal lender = makeAddr("lender");
    address internal alice = makeAddr("alice"); // agent owner
    address internal bob = makeAddr("bob"); // another agent owner
    address internal operator = makeAddr("operator"); // agent key
    address internal provider = makeAddr("provider"); // curated payee
    address internal client = makeAddr("client"); // pays the agent
    address internal keeper = makeAddr("keeper");

    uint256 internal constant LENDER_DEPOSIT = 100_000 * ONE;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        usdg = new MockUSDG();
        irm = new InterestRateModel(0, 0.06e18, 0.8e18, 0.6e18);
        pool = new TabbPool(IERC20(address(usdg)), "Tabb Agent Pool USDG", "tabUSDG", owner, guardian, irm, treasury, 1_000);
        idReg = new MockERC8004IdentityRegistry();
        registry = new ERC8004RegistryAdapter(IERC8004IdentityRegistry(address(idReg)));
        cfg = new AgentRiskConfig(owner, guardian, AgentRiskDefaults.params(), AgentRiskDefaults.tiers(), treasury);
        vault = new OwnerStakeVault(IERC20(address(usdg)), owner, guardian);
        score = new AgentCreditScore(IAgentRiskConfig(address(cfg)), IOwnerStakeVault(address(vault)), owner);
        payees = new PayeeRegistry(owner, guardian);
        mgr = new AgentCreditManager(
            AgentCreditManager.Deps({
                usdg: IERC20(address(usdg)),
                pool: ITabbPool(address(pool)),
                registry: IAgentRegistry(address(registry)),
                config: IAgentRiskConfig(address(cfg)),
                score: IAgentCreditScore(address(score)),
                vault: IOwnerStakeVault(address(vault)),
                payees: IPayeeRegistry(address(payees)),
                policyAccountImpl: address(new PolicyAccount()),
                splitterImpl: address(new RepaymentSplitter())
            }),
            owner,
            guardian
        );
        service = new MockService(IERC20(address(usdg)));

        vm.startPrank(owner);
        pool.setCreditLine(address(mgr), 50_000 * ONE, 800, true);
        vault.setManager(IAgentCreditManager(address(mgr)));
        score.setManager(address(mgr));
        payees.setPayee(provider, true, "compute provider");
        payees.setPayee(address(service), true, "service");
        payees.setAllowedCall(address(service), MockService.buyCredits.selector, true);
        payees.setAllowedCall(address(service), MockService.ping.selector, true);
        payees.setAllowedCall(address(service), MockService.boom.selector, true);
        vm.stopPrank();

        usdg.mint(lender, LENDER_DEPOSIT);
        vm.startPrank(lender);
        usdg.approve(address(pool), type(uint256).max);
        pool.deposit(LENDER_DEPOSIT, lender);
        vm.stopPrank();

        _fund(alice, 100_000 * ONE);
        _fund(bob, 100_000 * ONE);
        _fund(client, 1_000_000 * ONE);
    }

    function _fund(address who, uint256 amt) internal {
        usdg.mint(who, amt);
        vm.startPrank(who);
        usdg.approve(address(vault), type(uint256).max);
        usdg.approve(address(mgr), type(uint256).max);
        vm.stopPrank();
    }

    function _register(address who) internal returns (uint256 id) {
        vm.prank(who);
        id = idReg.register("ipfs://agent-card");
    }

    function _stake(uint256 id, address who, uint256 amt) internal {
        vm.prank(who);
        vault.stake(id, amt);
    }

    function _open(uint256 id, address who) internal {
        vm.prank(who);
        mgr.openTab(id, operator, address(0));
    }

    /// @dev registers + stakes + opens a tab for `who`
    function _newAgent(address who, uint256 stakeAmt) internal returns (uint256 id) {
        id = _register(who);
        _stake(id, who, stakeAmt);
        _open(id, who);
    }

    function _draw(uint256 id, address who, uint256 amt) internal {
        vm.prank(who);
        mgr.draw(id, amt);
    }

    function _pa(uint256 id) internal view returns (PolicyAccount) {
        return PolicyAccount(payable(mgr.tabOf(id).policyAccount));
    }

    function _splitter(uint256 id) internal view returns (RepaymentSplitter) {
        return RepaymentSplitter(mgr.tabOf(id).splitter);
    }

    /// @dev a client pays the agent `amt` and someone distributes
    function _earn(uint256 id, uint256 amt) internal {
        RepaymentSplitter sp = _splitter(id);
        vm.prank(client);
        usdg.transfer(address(sp), amt);
        vm.prank(keeper);
        sp.distribute();
    }

    function _status(uint256 id) internal view returns (AgentCreditManager.Status) {
        return mgr.tabOf(id).status;
    }

    /// @dev raise base limit so tests can draw larger amounts with tier-0 agents
    function _setBaseLimit(uint256 base) internal {
        IAgentRiskConfig.Params memory p = cfg.params();
        p.baseLimit = base;
        vm.prank(owner);
        cfg.setParams(p);
    }
}
