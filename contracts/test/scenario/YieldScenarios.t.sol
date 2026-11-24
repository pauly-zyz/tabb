// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {YieldFixture} from "../utils/YieldFixture.sol";
import {TabManager} from "../../src/yield/TabManager.sol";

contract YieldScenariosTest is YieldFixture {
    /// E2E: lender deposit -> open tab -> borrow -> several harvests -> debt self-repays -> withdraw collateral.
    function test_e2e_selfRepayingYieldTab() public {
        uint256 lenderValue = pool.previewRedeem(pool.balanceOf(lender));
        uint256 shares = 20_000 * ONE;
        uint256 id = _shareTab(alice, shares);
        _borrow(id, alice, 4_000 * ONE); // 20% LTV

        uint256 harvests;
        while (tm.debtOf(id) > 0 && harvests < 60) {
            skip(30 days);
            // vault earns ~5% APR: 300k TVL * 5% / 12
            vault.injectYield(1_250 * ONE);
            _harvest(id);
            harvests++;
        }
        assertEq(tm.debtOf(id), 0, "self-repaid");
        assertGt(harvests, 1);
        assertGt(tm.tabOf(id).yieldRepaid, 4_000 * ONE);

        // later harvest: debt is zero, yield is credited to the owner
        skip(30 days);
        vault.injectYield(1_250 * ONE);
        (,,, uint256 credited) = _harvest(id);
        assertGt(credited, 0);
        vm.startPrank(alice);
        tm.claimCredit();
        uint256 bal = shareAdapter.balanceOf(id);
        tm.withdrawCollateral(id, bal);
        tm.closeTab(id);
        vm.stopPrank();
        assertEq(vault.balanceOf(alice) >= 80_000 * ONE + bal - 1, true);
        // lenders earned interest
        assertGt(pool.previewRedeem(pool.balanceOf(lender)), lenderValue);
    }

    /// Stress: stock-dividend YT gaps down 30% while the market is closed -> new borrows frozen,
    /// liquidation still works on the extended heartbeat and restores health.
    function test_stress_ytGapDownWhileMarketClosed() public {
        uint256 id = _ytTab(alice, 10_000e18); // value 70,000 (30% haircut)
        _borrow(id, alice, 28_000 * ONE); // 40% LTV (max)
        uint256 hf0 = tm.healthFactor(id);
        assertApproxEqRel(hf0, 1.25e18, 1e14); // 50/40

        // Friday close
        vm.prank(owner);
        oracle.setMarketOpen(address(yt), false);
        vm.prank(alice);
        vm.expectRevert(TabManager.BorrowFrozen.selector);
        tm.borrow(id, 1 * ONE);

        // weekend: 30h pass, off-hours feed reports a 30% gap down ($10 -> $7)
        skip(30 hours);
        ytFeed.set(7e8);
        uint256 hf = tm.healthFactor(id);
        assertApproxEqRel(hf, 0.875e18, 2e15); // 1.25 * 0.7 (haircut shrinks slightly as time passes)
        assertLt(hf, 1e18);
        assertLt(hf, 0.95e18); // full liquidation allowed

        // stale-for-borrow but fresh-for-liquidation price (closed heartbeat = 80h)
        skip(10 hours);
        uint256 debt = tm.debtOf(id);
        uint256 ytBefore = yt.balanceOf(liq);
        vm.prank(liq);
        (uint256 repaid, uint256 seized, uint256 bad) = liquidator.liquidate(id, type(uint256).max);
        assertApproxEqAbs(repaid, debt, 2);
        assertEq(bad, 0);
        assertEq(yt.balanceOf(liq) - ytBefore, seized);
        // liquidator got 110% of repaid in collateral value (at the haircut valuation)
        assertApproxEqAbs(ytAdapter.valueOfAmount(seized, 1), repaid * 11 / 10, 2e6);
        assertEq(tm.debtOf(id), 0);
        // remaining collateral returns to the owner after reopening of the market
        assertGt(ytAdapter.balanceOf(id), 0);
        vm.prank(owner);
        oracle.setMarketOpen(address(yt), true);
        ytFeed.set(7e8);
        uint256 rest = ytAdapter.balanceOf(id);
        vm.prank(alice);
        tm.withdrawCollateral(id, rest);
        assertEq(ytAdapter.balanceOf(id), 0);
    }

    /// Stress: partial liquidation when the gap is moderate (HF between 0.95 and 1).
    function test_stress_partialLiquidationMarketClosed() public {
        uint256 id = _ytTab(alice, 10_000e18);
        _borrow(id, alice, 28_000 * ONE);
        vm.prank(owner);
        oracle.setMarketOpen(address(yt), false);
        skip(20 hours);
        ytFeed.set(7.8e8); // -22% -> HF 0.975
        uint256 hf = tm.healthFactor(id);
        assertLt(hf, 1e18);
        assertGt(hf, 0.95e18);
        uint256 debt = tm.debtOf(id);
        vm.prank(liq);
        (uint256 repaid,,) = liquidator.liquidate(id, type(uint256).max);
        assertApproxEqAbs(repaid, debt / 2, 2);
        assertGt(tm.healthFactor(id), 1e18);
    }
}
