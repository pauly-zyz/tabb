// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AgentFixture} from "../utils/AgentFixture.sol";
import {AgentCreditManager as ACM} from "../../src/agent/AgentCreditManager.sol";
import {PolicyAccount} from "../../src/agent/PolicyAccount.sol";
import {IAgentRiskConfig} from "../../src/interfaces/IAgentRiskConfig.sol";

contract AgentScenariosTest is AgentFixture {
    /// E2E: lender deposit -> stake -> openTab -> draw -> agent pays provider -> clients pay splitter ->
    /// several distributions -> debt paid by revenue -> qualified cycles -> tier up -> limit up -> stake withdrawn.
    function test_e2e_selfRepayingAgentTab() public {
        uint256 lenderShares = pool.balanceOf(lender);
        uint256 id = _newAgent(alice, 1_000 * ONE);
        assertEq(mgr.creditLimitOf(id), 100 * ONE); // base limit, tier 0
        assertEq(score.tierOf(id), 0);

        for (uint256 cycle; cycle < 3; ++cycle) {
            uint256 avail = mgr.availableCredit(id);
            _draw(id, alice, avail);
            PolicyAccount pa = _pa(id);
            // spend a bit on compute
            uint256 spendAmt = 15 * ONE;
            vm.prank(operator);
            pa.pay(address(usdg), provider, spendAmt);
            // daily client revenue repays the tab automatically (20% split)
            for (uint256 d; d < 60 && mgr.debtOf(id) > 0; ++d) {
                skip(1 days);
                _earn(id, 60 * ONE);
            }
            assertEq(mgr.debtOf(id), 0, "self-repaid");
            // return leftover funds to owner by closing/reopening later; for now just continue
        }
        (,, uint32 q,,,) = score.records(id);
        assertEq(q, 3);
        // revenue lifted capacity above the base limit: 25% of windowed revenue
        assertGt(mgr.creditLimitOf(id), 100 * ONE);
        skip(30 days);
        assertEq(score.tierOf(id), 1);
        assertGt(mgr.tabOf(id).revenueRepaid, 0);

        // lender earned interest
        assertGt(pool.previewRedeem(lenderShares), LENDER_DEPOSIT);

        // close and withdraw stake after cooldown
        vm.prank(alice);
        mgr.closeTab(id);
        skip(7 days);
        vm.prank(alice);
        vault.withdraw(id, 1_000 * ONE, alice);
        assertEq(vault.stakeOf(id, alice), 0);
    }

    /// Stress (a): agent stops paying -> delinquent -> default -> waterfall; lender loss == net write-off.
    function test_stress_agentStopsPaying() public {
        _unsecuredTier(20_000);
        uint256 id = _newAgent(alice, 500 * ONE);
        _draw(id, alice, 1_000 * ONE);
        PolicyAccount pa = _pa(id);
        for (uint256 i; i < 4; ++i) {
            vm.prank(operator);
            pa.pay(address(usdg), provider, 200 * ONE);
            skip(1 days);
        }
        // 200 left in PolicyAccount; agent goes silent
        skip(33 days);
        mgr.markDelinquent(id);
        skip(30 days);
        uint256 debt = mgr.debtOf(id);
        uint256 lenderValueBefore = pool.previewRedeem(pool.balanceOf(lender));
        uint256 treasuryBefore = pool.treasuryAssets();
        mgr.markDefault(id);
        ACM.AgentTab memory t = mgr.tabOf(id);
        assertApproxEqAbs(t.lossWrittenOff, debt - 200 * ONE - 500 * ONE, 3);
        uint256 lenderLoss = lenderValueBefore - pool.previewRedeem(pool.balanceOf(lender));
        uint256 treasuryCover = treasuryBefore - pool.treasuryAssets();
        assertApproxEqAbs(lenderLoss + treasuryCover, t.lossWrittenOff, 5);
    }

    /// Stress (b): 10 agents of one owner default together -> loss bounded by owner cap minus stakes.
    function test_stress_sybilOwnerMassDefault() public {
        _unsecuredTier(20_000);
        address sybil = makeAddr("sybil");
        _fund(sybil, 100_000 * ONE);
        uint256[] memory ids = new uint256[](10);
        uint256 totalDrawn;
        uint256 totalStake;
        for (uint256 i; i < 10; ++i) {
            ids[i] = _newAgent(sybil, 150 * ONE);
            totalStake += 150 * ONE;
            uint256 avail = mgr.availableCredit(ids[i]);
            if (avail >= 10 * ONE) {
                _draw(ids[i], sybil, avail);
                totalDrawn += avail;
            }
        }
        assertLe(totalDrawn, cfg.params().maxPerOwner);
        for (uint256 i; i < 10; ++i) {
            PolicyAccount pa = _pa(ids[i]);
            uint256 bal = usdg.balanceOf(address(pa));
            if (bal > 0) {
                vm.prank(operator);
                pa.pay(address(usdg), provider, bal * 25 / 100 > 0 ? bal * 25 / 100 : 0);
            }
        }
        skip(37 days);
        uint256 totalLoss;
        for (uint256 i; i < 10; ++i) {
            if (mgr.debtOf(ids[i]) == 0) continue;
            mgr.markDelinquent(ids[i]);
        }
        skip(30 days);
        uint256 taBefore = pool.totalAssets();
        for (uint256 i; i < 10; ++i) {
            if (_status(ids[i]) != ACM.Status.Delinquent) continue;
            mgr.markDefault(ids[i]);
            totalLoss += mgr.tabOf(ids[i]).lossWrittenOff;
        }
        // drawn capped at 3,000 (owner cap); stakes slashed first => loss is bounded
        assertLe(totalLoss, totalDrawn * 12 / 10 > totalStake ? totalDrawn * 12 / 10 - totalStake : 0);
        assertApproxEqAbs(pool.totalAssets(), taBefore - totalLoss, 20);
        assertTrue(mgr.blacklistedOwner(sybil));
    }

    /// Stress (c): identity NFT transferred while in debt -> draw frozen, old owner's stake still slashed.
    function test_stress_identityTransferredWithDebt() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 100 * ONE);
        vm.prank(alice);
        idReg.transferFrom(alice, bob, id);
        vm.prank(alice);
        vm.expectRevert(ACM.OwnerChanged.selector);
        mgr.draw(id, 10 * ONE);
        vm.prank(bob);
        vm.expectRevert(ACM.NotAgentOwner.selector);
        mgr.draw(id, 10 * ONE);
        vm.prank(bob);
        vm.expectRevert(ACM.TabExists.selector);
        mgr.openTab(id, bob, bob);
        // operator can't spend either
        PolicyAccount pa = _pa(id);
        vm.prank(operator);
        vm.expectRevert(PolicyAccount.SpendingFrozen.selector);
        pa.pay(address(usdg), provider, 1);
        // alice walks away
        skip(37 days);
        mgr.markDelinquent(id);
        skip(30 days);
        mgr.markDefault(id);
        assertEq(mgr.tabOf(id).lossWrittenOff, 0); // 100 still in PA + stake cover it
        assertTrue(mgr.blacklistedOwner(alice));
        assertFalse(mgr.blacklistedOwner(bob));
    }

    /// Stress (d): operator key stolen -> leak bounded by the daily cap and only to curated payees.
    function test_stress_operatorKeyCompromised() public {
        _setBaseLimit(1_000 * ONE);
        uint256 id = _newAgent(alice, 1_000 * ONE);
        _draw(id, alice, 1_000 * ONE);
        PolicyAccount pa = _pa(id);
        address thief = makeAddr("thief");
        vm.startPrank(operator); // attacker holds the operator key
        vm.expectRevert(PolicyAccount.NotPayee.selector);
        pa.pay(address(usdg), thief, 1);
        vm.expectRevert(PolicyAccount.CallNotAllowed.selector);
        pa.execute(address(usdg), 0, abi.encodeWithSignature("transfer(address,uint256)", thief, 1));
        vm.expectRevert(PolicyAccount.NotPayee.selector);
        pa.approveSpender(thief, 1);
        // max drain to a curated payee in one day = 25% of limit
        pa.pay(address(usdg), provider, 250 * ONE);
        vm.expectRevert(PolicyAccount.DailyCapExceeded.selector);
        pa.pay(address(usdg), provider, 1);
        vm.stopPrank();
        assertEq(usdg.balanceOf(thief), 0);
        // owner rotates the key; old key is dead
        vm.prank(alice);
        mgr.setOperator(id, alice);
        vm.prank(operator);
        vm.expectRevert(PolicyAccount.NotOperator.selector);
        pa.pay(address(usdg), provider, 1);
        // owner returns remaining funds to the pool
        vm.prank(alice);
        mgr.repayFromPolicyAccount(id, type(uint256).max);
        assertApproxEqAbs(mgr.debtOf(id), 250 * ONE, 1);
    }

    function _unsecuredTier(uint32 leverageBps) internal {
        IAgentRiskConfig.Tier[] memory t = new IAgentRiskConfig.Tier[](1);
        t[0] = IAgentRiskConfig.Tier(0, 0, 0, leverageBps);
        IAgentRiskConfig.Params memory p = cfg.params();
        p.baseLimit = 1_000 * ONE;
        vm.startPrank(owner);
        cfg.setTiers(t);
        cfg.setParams(p);
        vm.stopPrank();
    }
}
