// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {YieldFixture} from "../utils/YieldFixture.sol";

contract YieldFuzzTest is YieldFixture {
    function testFuzz_borrowRepay(uint256 coll, uint256 borrowBps, uint256 repayAmt, uint256 dt) public {
        coll = bound(coll, 1_000 * ONE, 90_000 * ONE);
        uint256 id = _shareTab(alice, coll);
        uint256 maxB = tm.maxBorrow(id);
        uint256 amt = bound(borrowBps, 10 * ONE, maxB);
        _borrow(id, alice, amt);
        assertGe(tm.healthFactor(id), 1e18);
        skip(bound(dt, 0, 2 * 365 days));
        uint256 debt = tm.debtOf(id);
        repayAmt = bound(repayAmt, 1, debt * 2);
        vm.prank(bob);
        uint256 paid = tm.repay(id, repayAmt);
        assertLe(paid, repayAmt);
        assertApproxEqAbs(tm.debtOf(id) + paid, debt, 2);
        assertEq(tm.totalScaledDebt(), pool.scaledDebtOf(address(tm)));
        assertLe(pool.totalDebt(), pool.totalAssets());
    }

    function testFuzz_harvestNeverIncreasesDebt(uint256 coll, uint256 borrowAmt, uint256 yieldAmt, uint256 dt) public {
        coll = bound(coll, 1_000 * ONE, 90_000 * ONE);
        uint256 id = _shareTab(alice, coll);
        borrowAmt = bound(borrowAmt, 10 * ONE, tm.maxBorrow(id));
        _borrow(id, alice, borrowAmt);
        skip(bound(dt, 0, 365 days));
        yieldAmt = bound(yieldAmt, 10_000 * ONE, 1_000_000 * ONE);
        vault.injectYield(yieldAmt);
        uint256 debtBefore = tm.debtOf(id);
        uint256 creditBefore = tm.ownerCredit(alice);
        (uint256 y, uint256 reward, uint256 repaid, uint256 credited) = _harvest(id);
        assertLe(tm.debtOf(id), debtBefore);
        assertEq(y, reward + repaid + credited);
        assertEq(tm.ownerCredit(alice) - creditBefore, credited);
        if (credited > 1) assertEq(tm.debtOf(id), 0); // excess only after full payoff (1 wei rounding dust aside)
    }

    function testFuzz_withdrawKeepsHealthy(uint256 coll, uint256 borrowAmt, uint256 wd) public {
        coll = bound(coll, 1_000 * ONE, 90_000 * ONE);
        uint256 id = _shareTab(alice, coll);
        borrowAmt = bound(borrowAmt, 10 * ONE, tm.maxBorrow(id));
        _borrow(id, alice, borrowAmt);
        wd = bound(wd, 1, coll);
        vm.prank(alice);
        try tm.withdrawCollateral(id, wd) {
            assertGe(tm.healthFactor(id), 1e18);
        } catch {}
    }

    function testFuzz_liquidation(uint256 coll, uint256 lossBps, uint256 repayAmt) public {
        coll = bound(coll, 1_000 * ONE, 90_000 * ONE);
        uint256 id = _shareTab(alice, coll);
        _borrow(id, alice, tm.maxBorrow(id));
        lossBps = bound(lossBps, 700, 6_000); // 7%..60% vault loss
        vault.lose(vault.totalAssets() * lossBps / 10_000);
        uint256 hf = tm.healthFactor(id);
        uint256 debt = tm.debtOf(id);
        repayAmt = bound(repayAmt, 1 * ONE, debt);
        uint256 sharesBefore = vault.balanceOf(liq);
        if (hf >= 1e18) return;
        vm.prank(liq);
        (uint256 repaid, uint256 seized, uint256 bad) = liquidator.liquidate(id, repayAmt);
        assertLe(repaid, repayAmt);
        assertEq(vault.balanceOf(liq) - sharesBefore, seized);
        // seized value never exceeds repaid * (1 + bonus) (+ rounding)
        assertLe(vault.previewRedeem(seized), repaid * 10_500 / 10_000 + 2);
        assertLe(tm.debtOf(id), debt);
        if (bad > 0) assertEq(tm.debtOf(id), 0);
        assertEq(tm.totalScaledDebt(), pool.scaledDebtOf(address(tm)));
    }
}
