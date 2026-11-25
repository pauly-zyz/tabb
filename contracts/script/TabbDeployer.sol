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
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IClipYieldToken} from "../src/interfaces/IClipYieldToken.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {OracleRouter} from "../src/yield/OracleRouter.sol";
import {YieldRiskConfig} from "../src/yield/YieldRiskConfig.sol";
import {TabManager} from "../src/yield/TabManager.sol";
import {YieldHarvester} from "../src/yield/YieldHarvester.sol";
import {Liquidator} from "../src/yield/Liquidator.sol";
import {ERC4626ShareAdapter} from "../src/yield/ERC4626ShareAdapter.sol";
import {YieldTokenAdapter} from "../src/yield/YieldTokenAdapter.sol";
import {MockUSDG} from "../test/mocks/MockUSDG.sol";
import {MockERC4626Vault} from "../test/mocks/MockERC4626Vault.sol";
import {MockYieldToken} from "../test/mocks/MockYieldToken.sol";
import {MockAggregator} from "../test/mocks/MockAggregator.sol";

/// @notice Shared deployment logic for the local, testnet and mainnet scripts.
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
        return _deployCore(usdg, identityRegistry, deployer, guardian, treasury, SEED_DEPOSIT);
    }

    function _deployCore(
        address usdg,
        address identityRegistry,
        address deployer,
        address guardian,
        address treasury,
        uint256 seed
    ) internal returns (Core memory c) {
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
        IERC20(usdg).approve(address(pool), seed);
        pool.deposit(seed, address(0xdead));
    }

    struct YieldCore {
        address pool;
        address oracle;
        address risk;
        address tabManager;
        address harvester;
        address liquidator;
        address vault;
        address yieldToken;
        address ytFeed;
        address shareAdapter;
        address ytAdapter;
    }

    /// @dev Phase 2: separate yield-credit pool (Q-U1) + TabManager and keeper entrypoints.
    function _deployYieldCore(address usdg, address irm, address deployer, address guardian, address treasury)
        internal
        returns (YieldCore memory y)
    {
        _assertNotMainnet();
        TabbPool pool2 = new TabbPool(
            IERC20(usdg),
            "Tabb Yield Credit USDG",
            "tyUSDG",
            deployer,
            guardian,
            InterestRateModel(irm),
            treasury,
            RESERVE_FACTOR_BPS
        );
        y.pool = address(pool2);
        OracleRouter oracle = new OracleRouter(deployer, guardian);
        y.oracle = address(oracle);
        YieldRiskConfig risk = new YieldRiskConfig(deployer, guardian, _yieldGlobal());
        y.risk = address(risk);
        TabManager tm = new TabManager(IERC20(usdg), ITabbPool(address(pool2)), oracle, risk, deployer, guardian);
        y.tabManager = address(tm);
        y.harvester = address(new YieldHarvester(tm));
        y.liquidator = address(new Liquidator(tm));
        tm.setPeriphery(y.harvester, y.liquidator);
        pool2.setCreditLine(address(tm), 1_000_000e6, 0, true);
        IERC20(usdg).approve(address(pool2), SEED_DEPOSIT);
        pool2.deposit(SEED_DEPOSIT, address(0xdead));
    }

    function _yieldGlobal() internal pure returns (YieldRiskConfig.GlobalParams memory) {
        return YieldRiskConfig.GlobalParams({
            closeFactorBps: 5_000,
            fullLiquidationHfWad: 0.95e18,
            dustDebt: 100e6,
            minDebt: 10e6,
            harvestRewardBps: 50,
            maxHarvestReward: 25e6,
            minHarvest: 1e6
        });
    }

    /// @dev Local/testnet only: mock USDG vault + mock dividend YT + feed, adapters and DESIGN.md §9.3 parameters.
    function _deployYieldMocks(YieldCore memory y, address usdg) internal returns (YieldCore memory) {
        MockERC4626Vault vault = new MockERC4626Vault(IERC20(usdg));
        MockYieldToken ytk = new MockYieldToken(MockUSDG(usdg), block.timestamp + 730 days);
        MockAggregator feed = new MockAggregator(8, 10e8);
        y.vault = address(vault);
        y.yieldToken = address(ytk);
        y.ytFeed = address(feed);
        y.shareAdapter = address(new ERC4626ShareAdapter(IERC4626(address(vault)), y.tabManager));
        y.ytAdapter = address(
            new YieldTokenAdapter(
                IClipYieldToken(address(ytk)),
                IERC20(usdg),
                OracleRouter(y.oracle),
                y.tabManager,
                YieldTokenAdapter.Haircut({baseBps: 1_000, annualBps: 1_000, maxBps: 5_000, minTimeToMaturity: 30 days})
            )
        );
        // generous heartbeats: mock feeds are not pushed by a keeper
        OracleRouter(y.oracle).setFeed(address(ytk), IAggregatorV3(address(feed)), 365 days, 365 days);
        YieldRiskConfig risk = YieldRiskConfig(y.risk);
        risk.setCollateral(
            y.shareAdapter,
            YieldRiskConfig.CollateralParams({
                status: YieldRiskConfig.Status.Active,
                maxLtvBps: 8_000,
                liqThresholdBps: 8_500,
                liqBonusBps: 500,
                closedMarketLtvBps: 8_000,
                supplyCap: 1_000_000e6,
                borrowCap: 500_000e6
            })
        );
        risk.setCollateral(
            y.ytAdapter,
            YieldRiskConfig.CollateralParams({
                status: YieldRiskConfig.Status.Active,
                maxLtvBps: 4_000,
                liqThresholdBps: 5_000,
                liqBonusBps: 1_000,
                closedMarketLtvBps: 0,
                supplyCap: 250_000e6,
                borrowCap: 50_000e6
            })
        );
        return y;
    }

    function _writeYield(YieldCore memory y) internal {
        string memory k = "yield";
        vm.serializeAddress(k, "pool", y.pool);
        vm.serializeAddress(k, "oracle", y.oracle);
        vm.serializeAddress(k, "risk", y.risk);
        vm.serializeAddress(k, "tabManager", y.tabManager);
        vm.serializeAddress(k, "harvester", y.harvester);
        vm.serializeAddress(k, "liquidator", y.liquidator);
        vm.serializeAddress(k, "vault", y.vault);
        vm.serializeAddress(k, "yieldToken", y.yieldToken);
        vm.serializeAddress(k, "ytFeed", y.ytFeed);
        vm.serializeAddress(k, "shareAdapter", y.shareAdapter);
        string memory json = vm.serializeAddress(k, "ytAdapter", y.ytAdapter);
        vm.writeJson(json, string.concat("./deployments/", vm.toString(block.chainid), ".yield.json"));
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
