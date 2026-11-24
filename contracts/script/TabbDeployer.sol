// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TabbPool} from "../src/pool/TabbPool.sol";
import {InterestRateModel} from "../src/pool/InterestRateModel.sol";
import {ERC8004RegistryAdapter, IERC8004IdentityRegistry} from "../src/agent/ERC8004RegistryAdapter.sol";
import {AgentRiskConfig} from "../src/agent/AgentRiskConfig.sol";
import {AgentRiskDefaults} from "../src/agent/AgentRiskDefaults.sol";
import {OwnerStakeVault} from "../src/agent/OwnerStakeVault.sol";
import {AgentCreditScore} from "../src/agent/AgentCreditScore.sol";
import {PayeeRegistry} from "../src/agent/PayeeRegistry.sol";
import {PolicyAccount} from "../src/agent/PolicyAccount.sol";
import {RepaymentSplitter} from "../src/agent/RepaymentSplitter.sol";
import {AgentCreditManager} from "../src/agent/AgentCreditManager.sol";
import {ITabbPool} from "../src/interfaces/ITabbPool.sol";
import {IAgentRegistry} from "../src/interfaces/IAgentRegistry.sol";
import {IAgentRiskConfig} from "../src/interfaces/IAgentRiskConfig.sol";
import {IAgentCreditScore} from "../src/interfaces/IAgentCreditScore.sol";
import {IOwnerStakeVault} from "../src/interfaces/IOwnerStakeVault.sol";
import {IPayeeRegistry} from "../src/interfaces/IPayeeRegistry.sol";
import {IAgentCreditManager} from "../src/interfaces/IAgentCreditManager.sol";

/// @notice Shared deployment logic for local and testnet scripts. Mainnet is intentionally NOT supported.
abstract contract TabbDeployer is Script {
    uint256 internal constant MAINNET_CHAIN_ID = 4663;
    uint256 internal constant SEED_DEPOSIT = 1_000e6;
    uint256 internal constant AGENT_LINE_CAP = 50_000e6;
    uint256 internal constant AGENT_SPREAD_BPS = 800;
    uint256 internal constant RESERVE_FACTOR_BPS = 1_000;

    struct Core {
        address usdg;
        address identityRegistry;
        address irm;
        address pool;
        address registryAdapter;
        address riskConfig;
        address stakeVault;
        address creditScore;
        address payeeRegistry;
        address policyAccountImpl;
        address splitterImpl;
        address agentCreditManager;
    }

    function _assertNotMainnet() internal view {
        require(block.chainid != MAINNET_CHAIN_ID, "Tabb: mainnet deploys are manual, post-audit");
    }

    /// @dev Deploys and wires the Phase 1 protocol. Caller (broadcaster) must hold >= SEED_DEPOSIT USDG and must be
    ///      the owner for wiring; ownership can be handed to a timelock afterwards (Ownable2Step).
    function _deployCore(address usdg, address identityRegistry, address deployer, address guardian, address treasury)
        internal
        returns (Core memory c)
    {
        _assertNotMainnet();
        c.usdg = usdg;
        c.identityRegistry = identityRegistry;
        c.irm = address(new InterestRateModel(0, 0.06e18, 0.8e18, 0.6e18));
        TabbPool pool = new TabbPool(
            IERC20(usdg),
            "Tabb Agent Credit USDG",
            "tabUSDG",
            deployer,
            guardian,
            InterestRateModel(c.irm),
            treasury,
            RESERVE_FACTOR_BPS
        );
        c.pool = address(pool);
        c.registryAdapter = address(new ERC8004RegistryAdapter(IERC8004IdentityRegistry(identityRegistry)));
        AgentRiskConfig cfg =
            new AgentRiskConfig(deployer, guardian, AgentRiskDefaults.params(), AgentRiskDefaults.tiers(), treasury);
        c.riskConfig = address(cfg);
        OwnerStakeVault vault = new OwnerStakeVault(IERC20(usdg), deployer, guardian);
        c.stakeVault = address(vault);
        AgentCreditScore score =
            new AgentCreditScore(IAgentRiskConfig(address(cfg)), IOwnerStakeVault(address(vault)), deployer);
        c.creditScore = address(score);
        PayeeRegistry payees = new PayeeRegistry(deployer, guardian);
        c.payeeRegistry = address(payees);
        c.policyAccountImpl = address(new PolicyAccount());
        c.splitterImpl = address(new RepaymentSplitter());
        AgentCreditManager mgr = new AgentCreditManager(
            AgentCreditManager.Deps({
                usdg: IERC20(usdg),
                pool: ITabbPool(address(pool)),
                registry: IAgentRegistry(c.registryAdapter),
                config: IAgentRiskConfig(address(cfg)),
                score: IAgentCreditScore(address(score)),
                vault: IOwnerStakeVault(address(vault)),
                payees: IPayeeRegistry(address(payees)),
                policyAccountImpl: c.policyAccountImpl,
                splitterImpl: c.splitterImpl
            }),
            deployer,
            guardian
        );
        c.agentCreditManager = address(mgr);

        pool.setCreditLine(address(mgr), AGENT_LINE_CAP, AGENT_SPREAD_BPS, true);
        vault.setManager(IAgentCreditManager(address(mgr)));
        score.setManager(address(mgr));

        // Seed deposit to a dead address (inflation-attack hardening on top of the virtual offset).
        IERC20(usdg).approve(address(pool), SEED_DEPOSIT);
        pool.deposit(SEED_DEPOSIT, address(0xdead));
    }

    function _writeDeployment(Core memory c, string memory extraKey, address extraValue) internal {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "usdg", c.usdg);
        vm.serializeAddress(k, "identityRegistry", c.identityRegistry);
        vm.serializeAddress(k, "interestRateModel", c.irm);
        vm.serializeAddress(k, "pool", c.pool);
        vm.serializeAddress(k, "registryAdapter", c.registryAdapter);
        vm.serializeAddress(k, "riskConfig", c.riskConfig);
        vm.serializeAddress(k, "stakeVault", c.stakeVault);
        vm.serializeAddress(k, "creditScore", c.creditScore);
        vm.serializeAddress(k, "payeeRegistry", c.payeeRegistry);
        vm.serializeAddress(k, "policyAccountImpl", c.policyAccountImpl);
        vm.serializeAddress(k, "splitterImpl", c.splitterImpl);
        if (bytes(extraKey).length > 0) vm.serializeAddress(k, extraKey, extraValue);
        string memory json = vm.serializeAddress(k, "agentCreditManager", c.agentCreditManager);
        vm.writeJson(json, string.concat("./deployments/", vm.toString(block.chainid), ".json"));
    }
}
