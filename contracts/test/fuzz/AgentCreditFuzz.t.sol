// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AgentFixture} from "../utils/AgentFixture.sol";
import {AgentCreditManager as ACM} from "../../src/agent/AgentCreditManager.sol";
import {PolicyAccount} from "../../src/agent/PolicyAccount.sol";
import {IAgentRiskConfig} from "../../src/interfaces/IAgentRiskConfig.sol";

contract AgentCreditFuzzTest is AgentFixture {
    function setUp() public override {
        super.setUp();
        _setBaseLimit(1_000 * ONE);
    }

    function testFuzz_drawRepay(uint256 stakeAmt, uint256 drawAmt, uint256 repayAmt, uint256 dt) public {
        stakeAmt = bound(stakeAmt, 100 * ONE, 1_000 * ONE);
        uint256 id = _newAgent(alice, stakeAmt);
        uint256 lim = mgr.creditLimitOf(id);
        drawAmt = bound(drawAmt, 10 * ONE, lim);
        _draw(id, alice, drawAmt);
        assertLe(mgr.debtOf(id), lim);
        dt = bound(dt, 0, 60 days);
        skip(dt);
        uint256 debtBefore = mgr.debtOf(id);
        repayAmt = bound(repayAmt, 1, 2 * debtBefore);
        uint256 balBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        uint256 paid = mgr.repay(id, repayAmt);
        assertLe(paid, repayAmt);
        assertEq(balBefore - usdg.balanceOf(bob), paid);
        assertLe(mgr.debtOf(id), debtBefore);
        assertApproxEqAbs(mgr.debtOf(id) + paid, debtBefore, 2);
        assertEq(mgr.totalScaledDebt(), pool.scaledDebtOf(address(mgr)));
        assertLe(pool.totalDebt(), pool.totalAssets());
    }

    function testFuzz_drawAboveLimitReverts(uint256 stakeAmt, uint256 extra) public {
        stakeAmt = bound(stakeAmt, 100 * ONE, 1_000 * ONE);
        uint256 id = _newAgent(alice, stakeAmt);
        uint256 lim = mgr.creditLimitOf(id);
        extra = bound(extra, 1, 1_000_000 * ONE);
        vm.prank(alice);
        vm.expectRevert(ACM.LimitExceeded.selector);
        mgr.draw(id, lim + extra);
    }

    function testFuzz_revenueSplitConservesFunds(uint256 drawAmt, uint256 revenue, uint16 splitBps, uint256 dt)
        public
    {
        uint256 id = _newAgent(alice, 1_000 * ONE);
        drawAmt = bound(drawAmt, 10 * ONE, 1_000 * ONE);
        _draw(id, alice, drawAmt);
        splitBps = uint16(bound(splitBps, 1_000, 10_000));
        vm.prank(alice);
        mgr.setSplitBps(id, splitBps);
        skip(bound(dt, 0, 29 days));
        revenue = bound(revenue, 1, 10_000 * ONE);
        uint256 debtBefore = mgr.debtOf(id);
        uint256 payoutBefore = usdg.balanceOf(alice);
        _earn(id, revenue);
        uint256 debtAfter = mgr.debtOf(id);
        uint256 toPayout = usdg.balanceOf(alice) - payoutBefore;
        uint256 repaid = debtBefore - debtAfter;
        assertLe(debtAfter, debtBefore); // revenue never increases debt
        assertApproxEqAbs(repaid + toPayout, revenue, 2);
        uint256 expectedRepay = revenue * splitBps / 10_000;
        if (expectedRepay > debtBefore) expectedRepay = debtBefore;
        assertApproxEqAbs(repaid, expectedRepay, 2);
        assertEq(usdg.balanceOf(address(_splitter(id))), 0);
    }

    function testFuzz_delinquencyTiming(uint256 drawAmt, uint256 paidAmt, uint256 dt) public {
        uint256 id = _newAgent(alice, 1_000 * ONE);
        drawAmt = bound(drawAmt, 10 * ONE, 1_000 * ONE);
        _draw(id, alice, drawAmt);
        uint256 due = drawAmt * 1_200 / 10_000;
        paidAmt = bound(paidAmt, 0, drawAmt / 2);
        if (paidAmt > 0) {
            vm.prank(alice);
            mgr.repay(id, paidAmt);
        }
        dt = bound(dt, 0, 90 days);
        skip(dt);
        // an unpaid period becomes delinquent-eligible after end + grace; a satisfied first period rolls over
        // and the (unpaid) second period becomes eligible at day 60 + 7
        bool shouldBeEligible = (paidAmt < due && dt >= 37 days) || (paidAmt >= due && dt >= 67 days);
        if (shouldBeEligible) {
            mgr.markDelinquent(id);
            assertEq(uint8(_status(id)), uint8(ACM.Status.Delinquent));
        } else {
            vm.expectRevert();
            mgr.markDelinquent(id);
        }
    }

    function testFuzz_defaultLossAccounting(uint256 stakeAmt, uint256 spend, uint256 leverage) public {
        leverage = bound(leverage, 10_000, 30_000);
        IAgentRiskConfig.Tier[] memory t = new IAgentRiskConfig.Tier[](1);
        t[0] = IAgentRiskConfig.Tier(0, 0, 0, uint32(leverage));
        IAgentRiskConfig.Params memory p = cfg.params();
        p.dailySpendCapBps = 10_000;
        vm.startPrank(owner);
        cfg.setTiers(t);
        cfg.setParams(p);
        vm.stopPrank();

        stakeAmt = bound(stakeAmt, 100 * ONE, 1_000 * ONE);
        uint256 id = _newAgent(alice, stakeAmt);
        uint256 lim = mgr.creditLimitOf(id);
        _draw(id, alice, lim);
        spend = bound(spend, 0, lim);
        if (spend > 0) {
            PolicyAccount pa = _pa(id);
            vm.prank(operator);
            pa.pay(address(usdg), provider, spend);
        }
        skip(37 days);
        mgr.markDelinquent(id);
        skip(30 days);
        uint256 debt = mgr.debtOf(id);
        uint256 covered = lim - spend > debt ? debt : lim - spend;
        uint256 taBefore = pool.totalAssets();
        mgr.markDefault(id);
        ACM.AgentTab memory tab = mgr.tabOf(id);
        assertEq(mgr.debtOf(id), 0);
        // waterfall identity: debt = leftover funds + slashed + writtenOff (rounding)
        assertApproxEqAbs(covered + (stakeAmt - vault.stakeOf(id, alice)) + tab.lossWrittenOff, debt, 3);
        // pool assets drop exactly by the written-off amount
        assertApproxEqAbs(pool.totalAssets(), taBefore - tab.lossWrittenOff, 3);
        // lender exposure bounded by debt - stake
        assertLe(tab.lossWrittenOff, debt > stakeAmt ? debt - stakeAmt + 3 : 3);
    }
}
