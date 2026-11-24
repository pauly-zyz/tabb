// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentCreditScore} from "../../src/agent/AgentCreditScore.sol";
import {AgentRiskConfig} from "../../src/agent/AgentRiskConfig.sol";
import {AgentRiskDefaults} from "../../src/agent/AgentRiskDefaults.sol";
import {OwnerStakeVault} from "../../src/agent/OwnerStakeVault.sol";
import {TabbAccessControl} from "../../src/access/TabbAccessControl.sol";
import {IAgentRiskConfig} from "../../src/interfaces/IAgentRiskConfig.sol";
import {IOwnerStakeVault} from "../../src/interfaces/IOwnerStakeVault.sol";
import {IAgentCreditScore} from "../../src/interfaces/IAgentCreditScore.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";

contract AgentCreditScoreTest is Test {
    MockUSDG usdg;
    AgentRiskConfig cfg;
    OwnerStakeVault vault;
    AgentCreditScore score;
    address owner = makeAddr("owner");
    address mgr = makeAddr("manager");
    address alice = makeAddr("alice");
    uint256 constant ID = 1;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdg = new MockUSDG();
        cfg = new AgentRiskConfig(owner, address(0), AgentRiskDefaults.params(), AgentRiskDefaults.tiers(), address(0));
        vault = new OwnerStakeVault(IERC20(address(usdg)), owner, address(0));
        score = new AgentCreditScore(cfg, IOwnerStakeVault(address(vault)), owner);
        vm.prank(owner);
        score.setManager(mgr);
        usdg.mint(alice, 10_000e6);
        vm.prank(alice);
        usdg.approve(address(vault), type(uint256).max);
    }

    function _stake(uint256 amt) internal {
        vm.prank(alice);
        vault.stake(ID, amt);
    }

    function _cycles(uint256 n) internal {
        vm.startPrank(mgr);
        for (uint256 i; i < n; ++i) score.onCycleCompleted(ID, true);
        vm.stopPrank();
    }

    function test_noStakeNoLimit() public view {
        assertEq(score.creditLimit(ID, alice), 0);
        assertEq(score.score(ID, alice), 0);
    }

    function test_belowMinStake() public {
        _stake(99e6);
        assertEq(score.creditLimit(ID, alice), 0);
    }

    function test_tier0LimitEqualsStakeCappedByBase() public {
        _stake(100e6);
        assertEq(score.creditLimit(ID, alice), 100e6);
        _stake(400e6); // stake 500, but capacity = baseLimit 100
        assertEq(score.creditLimit(ID, alice), 100e6);
    }

    function test_revenueRaisesCapacityUpToStake() public {
        _stake(500e6);
        vm.prank(mgr);
        score.recordRevenue(ID, 1_000e6); // 25% => 250
        assertEq(score.revenueInWindow(ID), 1_000e6);
        assertEq(score.creditLimit(ID, alice), 250e6);
        vm.prank(mgr);
        score.recordRevenue(ID, 2_000e6); // 3000 * 25% = 750 > stake 500 (tier0 1x)
        assertEq(score.creditLimit(ID, alice), 500e6);
    }

    function test_revenueWindowExpires() public {
        _stake(500e6);
        vm.prank(mgr);
        score.recordRevenue(ID, 1_000e6);
        skip(13 * 7 days);
        assertEq(score.revenueInWindow(ID), 0);
        assertEq(score.creditLimit(ID, alice), 100e6);
    }

    function test_revenueBucketsAccumulateAcrossEpochs() public {
        vm.startPrank(mgr);
        score.recordRevenue(ID, 100e6);
        score.recordRevenue(ID, 0); // no-op
        skip(7 days);
        score.recordRevenue(ID, 200e6);
        skip(26 * 7 days); // same ring slot reused for a new epoch
        score.recordRevenue(ID, 50e6);
        vm.stopPrank();
        assertEq(score.revenueInWindow(ID), 50e6);
    }

    function test_tiers() public {
        _stake(1_000e6);
        vm.prank(mgr);
        score.onFirstSeen(ID);
        vm.prank(mgr);
        score.recordRevenue(ID, 10_000e6); // capacity 2500
        assertEq(score.tierOf(ID), 0);
        assertEq(score.creditLimit(ID, alice), 1_000e6); // stake * 1x, also maxPerAgent

        // lower maxPerAgent influence: raise caps so leverage is visible
        IAgentRiskConfig.Params memory p = cfg.params();
        p.maxPerAgent = 5_000e6;
        p.maxPerOwner = 5_000e6;
        vm.prank(owner);
        cfg.setParams(p);

        _cycles(3);
        assertEq(score.tierOf(ID), 0); // too young
        skip(30 days);
        vm.prank(mgr);
        score.recordRevenue(ID, 10_000e6);
        assertEq(score.tierOf(ID), 1);
        assertEq(score.creditLimit(ID, alice), 1_500e6);

        _cycles(7);
        skip(60 days);
        vm.prank(mgr);
        score.recordRevenue(ID, 10_000e6);
        assertEq(score.tierOf(ID), 2);
        assertEq(score.creditLimit(ID, alice), 2_000e6);
    }

    function test_delinquencyDropsTier() public {
        vm.prank(mgr);
        score.onFirstSeen(ID);
        _cycles(3);
        skip(30 days);
        assertEq(score.tierOf(ID), 1);
        vm.prank(mgr);
        score.onDelinquent(ID);
        assertEq(score.tierOf(ID), 0);
        skip(90 days);
        assertEq(score.tierOf(ID), 1);
        (,, , , uint32 delinquencies,) = score.records(ID);
        assertEq(delinquencies, 1);
    }

    function test_unqualifiedCycleDoesNotCount() public {
        vm.prank(mgr);
        score.onCycleCompleted(ID, false);
        (,, uint32 q, uint32 total,,) = score.records(ID);
        assertEq(q, 0);
        assertEq(total, 1);
    }

    function test_defaultZeroesLimitAndScore() public {
        _stake(100e6);
        vm.startPrank(mgr);
        score.onFirstSeen(ID);
        score.onDefault(ID);
        vm.stopPrank();
        assertEq(score.creditLimit(ID, alice), 0);
        assertEq(score.score(ID, alice), 0);
    }

    function test_scoreDisplay() public {
        _stake(100e6);
        vm.prank(mgr);
        score.onFirstSeen(ID);
        assertEq(score.score(ID, alice), 0);
        skip(180 days);
        assertEq(score.score(ID, alice), 150);
        _cycles(20);
        vm.prank(mgr);
        score.recordRevenue(ID, 4_000e6);
        // tier2 (600) + age 150 + revenue 150 + cycles 100 = 1000
        assertEq(score.score(ID, alice), 1000);
        IAgentCreditScore.Breakdown memory b = score.breakdown(ID, alice);
        assertEq(b.tier, 2);
        assertEq(b.leverageBps, 20_000);
        assertEq(b.revenue, 4_000e6);
    }

    function test_firstSeenOnlyOnce() public {
        vm.prank(mgr);
        score.onFirstSeen(ID);
        (uint64 t0,,,,,) = score.records(ID);
        skip(10);
        vm.prank(mgr);
        score.onFirstSeen(ID);
        (uint64 t1,,,,,) = score.records(ID);
        assertEq(t0, t1);
    }

    function test_revert_onlyManager() public {
        vm.expectRevert(AgentCreditScore.NotManager.selector);
        score.recordRevenue(ID, 1);
        vm.expectRevert(AgentCreditScore.NotManager.selector);
        score.onFirstSeen(ID);
        vm.expectRevert(AgentCreditScore.NotManager.selector);
        score.onCycleCompleted(ID, true);
        vm.expectRevert(AgentCreditScore.NotManager.selector);
        score.onDelinquent(ID);
        vm.expectRevert(AgentCreditScore.NotManager.selector);
        score.onDefault(ID);
    }

    function test_revert_setManager() public {
        vm.prank(owner);
        vm.expectRevert(AgentCreditScore.ManagerAlreadySet.selector);
        score.setManager(address(1));
        AgentCreditScore s2 = new AgentCreditScore(cfg, IOwnerStakeVault(address(vault)), owner);
        vm.prank(owner);
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        s2.setManager(address(0));
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        new AgentCreditScore(IAgentRiskConfig(address(0)), IOwnerStakeVault(address(vault)), owner);
    }

    function testFuzz_limitNeverExceedsStakeLeverageOrCap(uint256 stakeAmt, uint256 revenue) public {
        stakeAmt = bound(stakeAmt, 0, 5_000e6);
        revenue = bound(revenue, 0, 1e15);
        if (stakeAmt > 0) _stake(stakeAmt);
        vm.prank(mgr);
        score.recordRevenue(ID, revenue);
        uint256 lim = score.creditLimit(ID, alice);
        assertLe(lim, stakeAmt); // tier 0 => 1x
        assertLe(lim, cfg.params().maxPerAgent);
    }
}
