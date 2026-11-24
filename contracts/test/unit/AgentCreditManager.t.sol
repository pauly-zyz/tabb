// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AgentFixture} from "../utils/AgentFixture.sol";
import {AgentCreditManager} from "../../src/agent/AgentCreditManager.sol";
import {PolicyAccount} from "../../src/agent/PolicyAccount.sol";
import {RepaymentSplitter} from "../../src/agent/RepaymentSplitter.sol";
import {OwnerStakeVault} from "../../src/agent/OwnerStakeVault.sol";
import {TabbAccessControl} from "../../src/access/TabbAccessControl.sol";
import {IAgentRiskConfig} from "../../src/interfaces/IAgentRiskConfig.sol";
import {IAgentCreditManager} from "../../src/interfaces/IAgentCreditManager.sol";
import {AgentCreditManager as ACM} from "../../src/agent/AgentCreditManager.sol";
import {ITabbPool} from "../../src/interfaces/ITabbPool.sol";

contract AgentCreditManagerTest is AgentFixture {
    // ------------------------------------------------------------------ openTab

    function test_openTab() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        ACM.AgentTab memory t = mgr.tabOf(id);
        assertEq(t.owner, alice);
        assertEq(t.payout, alice);
        assertEq(uint8(t.status), uint8(ACM.Status.Active));
        assertEq(t.splitBps, 2_000);
        assertTrue(t.policyAccount != address(0));
        assertTrue(t.splitter != address(0));
        assertEq(PolicyAccount(payable(t.policyAccount)).operator(), operator);
        assertEq(PolicyAccount(payable(t.policyAccount)).agentId(), id);
        assertEq(RepaymentSplitter(t.splitter).agentId(), id);
        assertEq(mgr.agentCount(), 1);
        assertEq(mgr.agentIds(0), id);
        assertEq(mgr.creditLimitOf(id), 100 * ONE);
        assertEq(mgr.pool(), address(pool));
        assertEq(mgr.creditLineKind(), mgr.KIND());
    }

    function test_openTabCustomPayout() public {
        uint256 id = _register(alice);
        _stake(id, alice, 100 * ONE);
        vm.prank(alice);
        mgr.openTab(id, operator, address(0xBEEF));
        assertEq(mgr.payoutOf(id), address(0xBEEF));
    }

    function test_revert_openTab() public {
        uint256 id = _register(alice);
        vm.prank(bob);
        vm.expectRevert(ACM.NotAgentOwner.selector);
        mgr.openTab(id, operator, address(0));

        vm.prank(alice);
        vm.expectRevert(ACM.InsufficientStake.selector);
        mgr.openTab(id, operator, address(0));

        _stake(id, alice, 100 * ONE);
        _open(id, alice);
        vm.prank(alice);
        vm.expectRevert(ACM.TabExists.selector);
        mgr.openTab(id, operator, address(0));
    }

    function test_revert_openTabAllowlist() public {
        vm.prank(owner);
        cfg.setOwnerAllowlistEnabled(true);
        uint256 id = _register(alice);
        _stake(id, alice, 100 * ONE);
        vm.prank(alice);
        vm.expectRevert(ACM.NotAllowed.selector);
        mgr.openTab(id, operator, address(0));
        vm.prank(owner);
        cfg.setOwnerAllowlisted(alice, true);
        _open(id, alice);
    }

    function test_revert_openTabPaused() public {
        uint256 id = _register(alice);
        _stake(id, alice, 100 * ONE);
        uint256 flag = mgr.PAUSE_OPEN();
        vm.prank(guardian);
        mgr.pause(flag);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TabbAccessControl.ActionPaused.selector, flag));
        mgr.openTab(id, operator, address(0));
    }

    // ------------------------------------------------------------------ draw

    function test_draw() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 60 * ONE);
        assertEq(usdg.balanceOf(address(_pa(id))), 60 * ONE);
        assertEq(mgr.debtOf(id), 60 * ONE);
        assertEq(mgr.ownerPrincipal(alice), 60 * ONE);
        assertEq(mgr.totalScaledDebt(), pool.scaledDebtOf(address(mgr)));
        assertEq(mgr.availableCredit(id), 40 * ONE);
        ACM.AgentTab memory t = mgr.tabOf(id);
        assertEq(t.periodBase, 60 * ONE);
        assertEq(t.periodStart, block.timestamp);
        assertEq(t.cyclePeak, 60 * ONE);
    }

    function test_revert_drawLimit() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        vm.prank(alice);
        vm.expectRevert(ACM.LimitExceeded.selector);
        mgr.draw(id, 101 * ONE);
    }

    function test_revert_drawMinDebt() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        vm.prank(alice);
        vm.expectRevert(ACM.BelowMinDebt.selector);
        mgr.draw(id, 9 * ONE);
    }

    function test_revert_drawZeroAndNotOwner() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        vm.prank(alice);
        vm.expectRevert(ACM.ZeroAmount.selector);
        mgr.draw(id, 0);
        vm.prank(bob);
        vm.expectRevert(ACM.NotAgentOwner.selector);
        mgr.draw(id, 10 * ONE);
    }

    function test_revert_drawOwnerChanged() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 50 * ONE);
        vm.prank(alice);
        idReg.transferFrom(alice, bob, id);
        vm.prank(alice);
        vm.expectRevert(ACM.OwnerChanged.selector);
        mgr.draw(id, 10 * ONE);
        // spending is frozen too
        assertFalse(mgr.canSpend(id));
        // old owner's stake stays locked
        assertTrue(mgr.stakeLocked(id, alice));
    }

    function test_revert_drawOwnerCap() public {
        _setBaseLimit(1_000 * ONE);
        uint256 a1 = _newAgent(alice, 1_000 * ONE);
        uint256 a2 = _newAgent(alice, 1_000 * ONE);
        uint256 a3 = _newAgent(alice, 1_000 * ONE);
        uint256 a4 = _newAgent(alice, 1_000 * ONE);
        _draw(a1, alice, 1_000 * ONE);
        _draw(a2, alice, 1_000 * ONE);
        _draw(a3, alice, 1_000 * ONE);
        assertEq(mgr.availableCredit(a4), 0);
        vm.prank(alice);
        vm.expectRevert(ACM.OwnerCapExceeded.selector);
        mgr.draw(a4, 10 * ONE);
    }

    function test_revert_drawPaused() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        uint256 flag = mgr.PAUSE_DRAW();
        vm.prank(guardian);
        mgr.pause(flag);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TabbAccessControl.ActionPaused.selector, flag));
        mgr.draw(id, 10 * ONE);
    }

    function test_revert_drawPastDue() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 50 * ONE);
        skip(30 days);
        vm.prank(alice);
        vm.expectRevert(ACM.PastDue.selector);
        mgr.draw(id, 10 * ONE);
    }

    function test_revert_drawPoolCap() public {
        vm.prank(owner);
        pool.setCreditLine(address(mgr), 50 * ONE, 800, true);
        uint256 id = _newAgent(alice, 100 * ONE);
        vm.prank(alice);
        vm.expectRevert();
        mgr.draw(id, 60 * ONE);
    }

    // ------------------------------------------------------------------ repay

    function test_repayInterestFirst() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 100 * ONE);
        skip(180 days);
        uint256 debt = mgr.debtOf(id);
        uint256 interest = debt - 100 * ONE;
        assertGt(interest, 0);
        vm.prank(bob);
        uint256 paid = mgr.repay(id, interest);
        assertApproxEqAbs(paid, interest, 1);
        assertEq(mgr.tabOf(id).principal, 100 * ONE); // only interest paid
        vm.prank(bob);
        mgr.repay(id, 10 * ONE);
        assertApproxEqAbs(mgr.tabOf(id).principal, 90 * ONE, 2);
    }

    function test_repayFullClosesCycle() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 60 * ONE);
        skip(8 days);
        uint256 balBefore = usdg.balanceOf(alice);
        uint256 debt = mgr.debtOf(id);
        vm.prank(alice);
        uint256 paid = mgr.repay(id, 1_000 * ONE); // over-pay is capped
        assertEq(paid, debt);
        assertEq(usdg.balanceOf(alice), balBefore - debt);
        assertEq(mgr.debtOf(id), 0);
        assertEq(mgr.ownerPrincipal(alice), 0);
        ACM.AgentTab memory t = mgr.tabOf(id);
        assertEq(t.principal, 0);
        assertEq(t.periodStart, 0);
        assertEq(t.zeroDebtAt, block.timestamp);
        (,, uint32 q, uint32 total,,) = score.records(id);
        assertEq(q, 1); // >= 7 days, peak >= 50
        assertEq(total, 1);
        assertEq(pool.scaledDebtOf(address(mgr)), 0);
    }

    function test_cycleUnqualifiedIfTooShort() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 60 * ONE);
        skip(1 days);
        vm.prank(alice);
        mgr.repay(id, 1_000 * ONE);
        (,, uint32 q, uint32 total,,) = score.records(id);
        assertEq(q, 0);
        assertEq(total, 1);
    }

    function test_revert_repay() public {
        uint256 id = _register(alice);
        vm.expectRevert(ACM.InvalidStatus.selector);
        mgr.repay(id, 1);
        id = _newAgent(alice, 100 * ONE);
        vm.expectRevert(ACM.ZeroAmount.selector);
        mgr.repay(id, 0);
        // nothing owed => 0 paid
        vm.prank(alice);
        assertEq(mgr.repay(id, 5 * ONE), 0);
    }

    function test_repayDustReturnsZero() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 50 * ONE);
        skip(365 days);
        // index > 1 so 1 wei converts to 0 scaled
        vm.prank(alice);
        assertEq(mgr.repay(id, 1), 0);
    }

    function test_repayFromPolicyAccount() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 50 * ONE);
        vm.prank(operator);
        uint256 paid = mgr.repayFromPolicyAccount(id, 30 * ONE);
        assertEq(paid, 30 * ONE);
        assertEq(usdg.balanceOf(address(_pa(id))), 20 * ONE);
        // more than the debt: surplus goes back to the PolicyAccount
        usdg.mint(address(_pa(id)), 100 * ONE);
        vm.prank(alice);
        paid = mgr.repayFromPolicyAccount(id, type(uint256).max);
        assertEq(paid, 20 * ONE);
        assertEq(usdg.balanceOf(address(_pa(id))), 100 * ONE);
        vm.prank(bob);
        vm.expectRevert(ACM.NotAgentOwner.selector);
        mgr.repayFromPolicyAccount(id, 1);
    }

    // ------------------------------------------------------------------ revenue

    function test_revenueSplit() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 100 * ONE);
        uint256 before = usdg.balanceOf(alice);
        _earn(id, 100 * ONE);
        assertEq(usdg.balanceOf(alice) - before, 80 * ONE);
        assertApproxEqAbs(mgr.debtOf(id), 80 * ONE, 1);
        assertEq(mgr.tabOf(id).revenueRepaid, 20 * ONE);
        assertEq(score.revenueInWindow(id), 100 * ONE);
        assertEq(_splitter(id).totalRevenue(), 100 * ONE);
    }

    function test_revenueWithoutDebtGoesToPayout() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        uint256 before = usdg.balanceOf(alice);
        _earn(id, 100 * ONE);
        assertEq(usdg.balanceOf(alice) - before, 100 * ONE);
        assertEq(score.revenueInWindow(id), 100 * ONE);
    }

    function test_revenueFee() public {
        IAgentRiskConfig.Params memory p = cfg.params();
        p.distributeFeeBps = 100; // 1%
        vm.prank(owner);
        cfg.setParams(p);
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 100 * ONE);
        _earn(id, 100 * ONE);
        assertEq(usdg.balanceOf(treasury), 1 * ONE);
        // repay 20% of net 99
        assertEq(mgr.tabOf(id).revenueRepaid, 19_800_000);
    }

    function test_revenueSelfRepaysToZero() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 100 * ONE);
        for (uint256 i; i < 10; ++i) {
            skip(1 days);
            _earn(id, 100 * ONE);
        }
        assertEq(mgr.debtOf(id), 0);
        assertEq(mgr.tabOf(id).periodStart, 0);
    }

    function test_revert_processRevenueNotSplitter() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        vm.expectRevert(ACM.NotSplitter.selector);
        mgr.processRevenue(id, 1);
        vm.expectRevert(ACM.NotSplitter.selector);
        mgr.processRevenue(999, 1);
    }

    function test_higherSplitAndValidation() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 100 * ONE);
        vm.prank(alice);
        mgr.setSplitBps(id, 5_000);
        _earn(id, 100 * ONE);
        assertApproxEqAbs(mgr.debtOf(id), 50 * ONE, 1);
        vm.startPrank(alice);
        vm.expectRevert(ACM.InvalidSplit.selector);
        mgr.setSplitBps(id, 999);
        vm.expectRevert(ACM.InvalidSplit.selector);
        mgr.setSplitBps(id, 10_001);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(ACM.NotAgentOwner.selector);
        mgr.setSplitBps(id, 5_000);
    }

    // ------------------------------------------------------------------ periods / delinquency / default

    function test_minPaymentKeepsTabCurrent() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 100 * ONE);
        ACM.PaymentStatus memory s = mgr.paymentStatus(id);
        assertEq(s.minPaymentDue, 12 * ONE);
        assertEq(s.periodEnd, block.timestamp + 30 days);
        vm.prank(alice);
        mgr.repay(id, 12 * ONE);
        skip(30 days);
        s = mgr.paymentStatus(id);
        assertFalse(s.pastDue);
        // next period starts from the debt at roll time
        assertGt(s.minPaymentDue, 10 * ONE);
        _draw(id, alice, 5 * ONE); // allowed, current
        skip(30 days);
        assertTrue(mgr.paymentStatus(id).pastDue);
    }

    function test_markDelinquentTiming() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 100 * ONE);
        vm.expectRevert(ACM.NotPastDue.selector);
        mgr.markDelinquent(id);
        skip(30 days);
        vm.expectRevert(ACM.TooEarly.selector);
        mgr.markDelinquent(id);
        skip(7 days);
        vm.prank(keeper);
        mgr.markDelinquent(id);
        assertEq(uint8(_status(id)), uint8(ACM.Status.Delinquent));
        assertFalse(mgr.canSpend(id));
        vm.expectRevert(ACM.InvalidStatus.selector);
        mgr.markDelinquent(id);
        // draw blocked
        vm.prank(alice);
        vm.expectRevert(ACM.InvalidStatus.selector);
        mgr.draw(id, 10 * ONE);
        ACM.PaymentStatus memory s = mgr.paymentStatus(id);
        assertEq(s.defaultEligibleAt, block.timestamp + 30 days);
    }

    function test_delinquentSplitIs100AndCure() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 100 * ONE);
        skip(37 days);
        mgr.markDelinquent(id);
        uint256 before = usdg.balanceOf(alice);
        _earn(id, 5 * ONE); // 100% to debt, not enough to cure
        assertEq(usdg.balanceOf(alice), before);
        assertEq(uint8(_status(id)), uint8(ACM.Status.Delinquent));
        _earn(id, 10 * ONE); // paid 15 >= 12 due -> period rolls; new period already over? (started day 30)
        // period 2 runs day 30..60, now day 37 -> current => cured
        assertEq(uint8(_status(id)), uint8(ACM.Status.Active));
        (,,,, uint32 delinquencies,) = score.records(id);
        assertEq(delinquencies, 1);
        // the cycle is dirty: repaying fully does not count as qualified
        vm.prank(alice);
        mgr.repay(id, 1_000 * ONE);
        (,, uint32 q,,,) = score.records(id);
        assertEq(q, 0);
    }

    function test_cureByFullRepay() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 100 * ONE);
        skip(37 days);
        mgr.markDelinquent(id);
        vm.prank(alice);
        mgr.repay(id, 1_000 * ONE);
        assertEq(uint8(_status(id)), uint8(ACM.Status.Active));
        assertEq(mgr.debtOf(id), 0);
    }

    function test_defaultWaterfall() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 100 * ONE);
        PolicyAccount pa = _pa(id);
        // agent spends 70, 30 left in PolicyAccount
        vm.prank(operator);
        pa.pay(address(usdg), provider, 25 * ONE);
        skip(1 days);
        vm.prank(operator);
        pa.pay(address(usdg), provider, 25 * ONE);
        skip(1 days);
        vm.prank(operator);
        pa.pay(address(usdg), provider, 20 * ONE);
        // some revenue sits undistributed in the splitter
        address sp = address(_splitter(id));
        vm.prank(client);
        usdg.transfer(sp, 5 * ONE);

        skip(37 days);
        mgr.markDelinquent(id);
        vm.expectRevert(ACM.TooEarly.selector);
        mgr.markDefault(id);
        skip(30 days);

        uint256 debt = mgr.debtOf(id);
        uint256 lenderBefore = pool.previewRedeem(pool.balanceOf(lender));
        uint256 treasuryBefore = pool.treasuryAssets();
        vm.prank(keeper);
        mgr.markDefault(id);

        ACM.AgentTab memory t = mgr.tabOf(id);
        assertEq(uint8(t.status), uint8(ACM.Status.Defaulted));
        assertEq(mgr.debtOf(id), 0);
        assertEq(usdg.balanceOf(address(_pa(id))), 0);
        assertEq(usdg.balanceOf(address(_splitter(id))), 0);
        // 30 + 5 recovered, rest (debt - 35) slashed from 100 stake
        uint256 slashed = debt - 35 * ONE;
        assertApproxEqAbs(vault.stakeOf(id, alice), 100 * ONE - slashed, 2);
        assertEq(t.lossWrittenOff, 0); // fully covered by stake
        assertTrue(mgr.blacklistedAgent(id));
        assertTrue(mgr.blacklistedOwner(alice));
        assertEq(mgr.ownerPrincipal(alice), 0);
        assertEq(pool.scaledDebtOf(address(mgr)), 0);
        // lenders + treasury made whole (interest included)
        assertGe(pool.previewRedeem(pool.balanceOf(lender)) + 2, lenderBefore);
        assertGe(pool.treasuryAssets() + 2, treasuryBefore);
        // remaining stake is withdrawable after default
        assertFalse(mgr.stakeLocked(id, alice));
        uint256 rest = vault.stakeOf(id, alice);
        vm.prank(alice);
        vault.withdraw(id, rest, alice);
        // blacklisted: cannot reopen
        vm.prank(alice);
        vm.expectRevert(ACM.Blacklisted.selector);
        mgr.openTab(id, operator, address(0));
        (,,,,, bool defaulted) = score.records(id);
        assertTrue(defaulted);
    }

    function test_defaultWithWriteOffAndRecovery() public {
        IAgentRiskConfig.Params memory p = cfg.params();
        IAgentRiskConfig.Tier[] memory tiers = new IAgentRiskConfig.Tier[](1);
        tiers[0] = IAgentRiskConfig.Tier(0, 0, 0, 20_000); // 2x leverage => unsecured exposure
        vm.startPrank(owner);
        cfg.setTiers(tiers);
        p.baseLimit = 200 * ONE;
        cfg.setParams(p);
        vm.stopPrank();

        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 200 * ONE);
        PolicyAccount pa = _pa(id);
        // agent spends everything over 8 days (cap = 25% of 200 = 50/day)
        for (uint256 i; i < 4; ++i) {
            vm.prank(operator);
            pa.pay(address(usdg), provider, 50 * ONE);
            skip(1 days);
        }
        skip(33 days);
        mgr.markDelinquent(id);
        skip(30 days);
        uint256 debt = mgr.debtOf(id);
        uint256 taBefore = pool.totalAssets();
        mgr.markDefault(id);
        ACM.AgentTab memory t = mgr.tabOf(id);
        assertEq(vault.stakeOf(id, alice), 0);
        assertApproxEqAbs(t.lossWrittenOff, debt - 100 * ONE, 2);
        // pool lost exactly the written-off amount
        assertApproxEqAbs(pool.totalAssets(), taBefore - t.lossWrittenOff, 2);

        // late revenue: 100% recovery until loss is covered, then to payout
        uint256 taMid = pool.totalAssets();
        _earn(id, 50 * ONE);
        assertEq(pool.totalAssets(), taMid + 50 * ONE);
        assertEq(mgr.tabOf(id).recovered, 50 * ONE);
        uint256 aliceBefore = usdg.balanceOf(alice);
        _earn(id, 100 * ONE);
        uint256 remainingLoss = t.lossWrittenOff - 50 * ONE;
        assertEq(mgr.tabOf(id).recovered, t.lossWrittenOff);
        assertEq(usdg.balanceOf(alice) - aliceBefore, 100 * ONE - remainingLoss);
    }

    function test_revert_markDefaultNotDelinquent() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        vm.expectRevert(ACM.InvalidStatus.selector);
        mgr.markDefault(id);
    }

    // ------------------------------------------------------------------ close / reopen / settings

    function test_closeAndReopen() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 50 * ONE);
        vm.prank(alice);
        vm.expectRevert(ACM.HasDebt.selector);
        mgr.closeTab(id);
        vm.prank(alice);
        mgr.repay(id, 1_000 * ONE);
        uint256 paBal = usdg.balanceOf(address(_pa(id)));
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        mgr.closeTab(id);
        assertEq(uint8(_status(id)), uint8(ACM.Status.Closed));
        assertEq(usdg.balanceOf(alice) - before, paBal);
        address pa = mgr.tabOf(id).policyAccount;
        vm.prank(alice);
        mgr.openTab(id, bob, address(0));
        assertEq(mgr.tabOf(id).policyAccount, pa); // reused
        assertEq(_pa(id).operator(), bob);
        assertEq(mgr.agentCount(), 1);
    }

    function test_revert_closeTab() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        vm.prank(bob);
        vm.expectRevert(ACM.NotAgentOwner.selector);
        mgr.closeTab(id);
        vm.prank(alice);
        mgr.closeTab(id);
        vm.prank(alice);
        vm.expectRevert(ACM.InvalidStatus.selector);
        mgr.closeTab(id);
    }

    function test_newOwnerTakesOverAfterClose() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        vm.prank(alice);
        mgr.closeTab(id);
        vm.prank(alice);
        idReg.transferFrom(alice, bob, id);
        _stake(id, bob, 100 * ONE);
        vm.prank(bob);
        mgr.openTab(id, operator, address(0));
        assertEq(mgr.tabOf(id).owner, bob);
        // alice's old stake is free
        assertFalse(mgr.stakeLocked(id, alice));
    }

    function test_settings() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        vm.startPrank(alice);
        mgr.setOperator(id, bob);
        mgr.setPayout(id, bob);
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        mgr.setPayout(id, address(0));
        vm.stopPrank();
        assertEq(_pa(id).operator(), bob);
        assertEq(mgr.payoutOf(id), bob);
        vm.startPrank(bob);
        vm.expectRevert(ACM.NotAgentOwner.selector);
        mgr.setOperator(id, bob);
        vm.expectRevert(ACM.NotAgentOwner.selector);
        mgr.setPayout(id, bob);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ stake lock

    function test_stakeLockAndCooldown() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        assertFalse(mgr.stakeLocked(id, alice));
        _draw(id, alice, 50 * ONE);
        assertTrue(mgr.stakeLocked(id, alice));
        vm.prank(alice);
        vm.expectRevert(OwnerStakeVault.StakeLocked.selector);
        vault.withdraw(id, 1, alice);
        vm.prank(alice);
        mgr.repay(id, 1_000 * ONE);
        assertTrue(mgr.stakeLocked(id, alice)); // cooldown
        skip(7 days);
        assertFalse(mgr.stakeLocked(id, alice));
        vm.prank(alice);
        vault.withdraw(id, 100 * ONE, alice);
        assertFalse(mgr.stakeLocked(id, bob));
    }

    function test_constructorZeroChecks() public {
        ACM.Deps memory d = ACM.Deps({
            usdg: usdg_(),
            pool: ITabbPool(address(pool)),
            registry: registry_(),
            config: cfg_(),
            score: score_(),
            vault: vault_(),
            payees: payees_(),
            policyAccountImpl: address(1),
            splitterImpl: address(0)
        });
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        new AgentCreditManager(d, owner, guardian);
    }

    function usdg_() internal view returns (IERC20Like) {
        return IERC20Like(address(usdg));
    }

    function registry_() internal view returns (IAgentRegistryLike) {
        return IAgentRegistryLike(address(registry));
    }

    function cfg_() internal view returns (IAgentRiskConfigLike) {
        return IAgentRiskConfigLike(address(cfg));
    }

    function score_() internal view returns (IAgentCreditScoreLike) {
        return IAgentCreditScoreLike(address(score));
    }

    function vault_() internal view returns (IOwnerStakeVaultLike) {
        return IOwnerStakeVaultLike(address(vault));
    }

    function payees_() internal view returns (IPayeeRegistryLike) {
        return IPayeeRegistryLike(address(payees));
    }
}

import {IERC20 as IERC20Like} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAgentRegistry as IAgentRegistryLike} from "../../src/interfaces/IAgentRegistry.sol";
import {IAgentRiskConfig as IAgentRiskConfigLike} from "../../src/interfaces/IAgentRiskConfig.sol";
import {IAgentCreditScore as IAgentCreditScoreLike} from "../../src/interfaces/IAgentCreditScore.sol";
import {IOwnerStakeVault as IOwnerStakeVaultLike} from "../../src/interfaces/IOwnerStakeVault.sol";
import {IPayeeRegistry as IPayeeRegistryLike} from "../../src/interfaces/IPayeeRegistry.sol";
