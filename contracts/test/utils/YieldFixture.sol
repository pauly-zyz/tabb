// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {TabbPool} from "../../src/pool/TabbPool.sol";
import {InterestRateModel} from "../../src/pool/InterestRateModel.sol";
import {ITabbPool} from "../../src/interfaces/ITabbPool.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IClipYieldToken} from "../../src/interfaces/IClipYieldToken.sol";
import {OracleRouter} from "../../src/yield/OracleRouter.sol";
import {YieldRiskConfig} from "../../src/yield/YieldRiskConfig.sol";
import {TabManager} from "../../src/yield/TabManager.sol";
import {YieldHarvester} from "../../src/yield/YieldHarvester.sol";
import {Liquidator} from "../../src/yield/Liquidator.sol";
import {ERC4626ShareAdapter} from "../../src/yield/ERC4626ShareAdapter.sol";
import {YieldTokenAdapter} from "../../src/yield/YieldTokenAdapter.sol";

import {MockUSDG} from "../mocks/MockUSDG.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockERC4626Vault} from "../mocks/MockERC4626Vault.sol";
import {MockYieldToken} from "../mocks/MockYieldToken.sol";

contract YieldFixture is Test {
    uint256 internal constant ONE = 1e6;

    MockUSDG internal usdg;
    TabbPool internal pool;
    OracleRouter internal oracle;
    YieldRiskConfig internal risk;
    TabManager internal tm;
    YieldHarvester internal harvester;
    Liquidator internal liquidator;
    MockERC4626Vault internal vault;
    MockYieldToken internal yt;
    ERC4626ShareAdapter internal shareAdapter;
    YieldTokenAdapter internal ytAdapter;
    MockAggregator internal ytFeed;
    MockAggregator internal seqFeed;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal lender = makeAddr("lender");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");
    address internal liq = makeAddr("liq");

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        usdg = new MockUSDG();
        InterestRateModel irm = new InterestRateModel(0, 0.06e18, 0.8e18, 0.6e18);
        pool = new TabbPool(IERC20(address(usdg)), "Tabb Yield USDG", "tyUSDG", owner, guardian, irm, treasury, 1_000);
        oracle = new OracleRouter(owner, guardian);
        risk = new YieldRiskConfig(owner, guardian, _defaultGlobal());
        tm = new TabManager(IERC20(address(usdg)), ITabbPool(address(pool)), oracle, risk, owner, guardian);
        harvester = new YieldHarvester(tm);
        liquidator = new Liquidator(tm);

        vault = new MockERC4626Vault(IERC20(address(usdg)));
        yt = new MockYieldToken(usdg, block.timestamp + 730 days);
        shareAdapter = new ERC4626ShareAdapter(IERC4626(address(vault)), address(tm));
        ytAdapter = new YieldTokenAdapter(
            IClipYieldToken(address(yt)),
            IERC20(address(usdg)),
            oracle,
            address(tm),
            YieldTokenAdapter.Haircut({baseBps: 1_000, annualBps: 1_000, maxBps: 5_000, minTimeToMaturity: 30 days})
        );
        ytFeed = new MockAggregator(8, 10e8); // $10 per YT
        seqFeed = new MockAggregator(0, 0); // up
        seqFeed.setStartedAt(block.timestamp - 2 days);

        vm.startPrank(owner);
        pool.setCreditLine(address(tm), 1_000_000 * ONE, 0, true);
        tm.setPeriphery(address(harvester), address(liquidator));
        oracle.setFeed(address(yt), IAggregatorV3(address(ytFeed)), 1 hours, 80 hours);
        oracle.setSequencer(IAggregatorV3(address(seqFeed)), 3600, true);
        risk.setCollateral(
            address(shareAdapter),
            YieldRiskConfig.CollateralParams({
                status: YieldRiskConfig.Status.Active,
                maxLtvBps: 8_000,
                liqThresholdBps: 8_500,
                liqBonusBps: 500,
                closedMarketLtvBps: 8_000,
                supplyCap: 1_000_000 * ONE,
                borrowCap: 500_000 * ONE
            })
        );
        risk.setCollateral(
            address(ytAdapter),
            YieldRiskConfig.CollateralParams({
                status: YieldRiskConfig.Status.Active,
                maxLtvBps: 4_000,
                liqThresholdBps: 5_000,
                liqBonusBps: 1_000,
                closedMarketLtvBps: 0,
                supplyCap: 250_000 * ONE,
                borrowCap: 50_000 * ONE
            })
        );
        vm.stopPrank();

        // lender liquidity
        usdg.mint(lender, 1_000_000 * ONE);
        vm.startPrank(lender);
        usdg.approve(address(pool), type(uint256).max);
        pool.deposit(500_000 * ONE, lender);
        vm.stopPrank();

        _setupUser(alice);
        _setupUser(bob);
        _setupUser(liq);
    }

    function _defaultGlobal() internal pure returns (YieldRiskConfig.GlobalParams memory) {
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

    function _setupUser(address who) internal {
        usdg.mint(who, 1_000_000 * ONE);
        vm.startPrank(who);
        usdg.approve(address(vault), type(uint256).max);
        usdg.approve(address(tm), type(uint256).max);
        vault.deposit(100_000 * ONE, who);
        vault.approve(address(shareAdapter), type(uint256).max);
        yt.approve(address(ytAdapter), type(uint256).max);
        vm.stopPrank();
        yt.mint(who, 100_000e18);
    }

    function _shareTab(address who, uint256 shares) internal returns (uint256 id) {
        vm.startPrank(who);
        id = tm.openTab(address(shareAdapter));
        tm.addCollateral(id, shares);
        vm.stopPrank();
    }

    function _ytTab(address who, uint256 amount) internal returns (uint256 id) {
        vm.startPrank(who);
        id = tm.openTab(address(ytAdapter));
        tm.addCollateral(id, amount);
        vm.stopPrank();
    }

    function _borrow(uint256 id, address who, uint256 amt) internal {
        vm.prank(who);
        tm.borrow(id, amt);
    }

    function _harvest(uint256 id) internal returns (uint256 y, uint256 reward, uint256 repaid, uint256 credited) {
        vm.prank(keeper);
        return harvester.harvest(id);
    }

    /// @dev refresh the YT price feed (keeps it fresh after time skips)
    function _ytPrice(int256 px8) internal {
        ytFeed.set(px8);
    }
}
