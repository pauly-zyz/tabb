// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldFixture} from "../utils/YieldFixture.sol";
import {TabManager} from "../../src/yield/TabManager.sol";
import {YieldRiskConfig} from "../../src/yield/YieldRiskConfig.sol";
import {YieldHarvester} from "../../src/yield/YieldHarvester.sol";
import {TabbAccessControl} from "../../src/access/TabbAccessControl.sol";
import {ITabbPool} from "../../src/interfaces/ITabbPool.sol";

contract TabManagerTest is YieldFixture {
    uint256 constant SH = 10_000 * 1e6; // 10k vault shares (1:1 with USDG at start)

    // ------------------------------------------------------------------ open / collateral

    function test_openAddBorrow() public {
        uint256 id = _shareTab(alice, SH);
        TabManager.Tab memory t = tm.tabOf(id);
        assertEq(t.owner, alice);
        assertEq(t.adapter, address(shareAdapter));
        assertTrue(t.open);
        assertEq(tm.tabIdOf(alice, address(shareAdapter)), id);
        assertEq(tm.maxBorrow(id), 8_000 * ONE - 1);
        uint256 before = usdg.balanceOf(alice);
        _borrow(id, alice, 8_000 * ONE - 1);
        assertEq(usdg.balanceOf(alice) - before, 8_000 * ONE - 1);
        assertEq(tm.debtOf(id), 8_000 * ONE - 1);
        assertGe(tm.healthFactor(id), 1.0625e18 - 1e12); // 85/80
        assertEq(tm.totalScaledDebt(), pool.scaledDebtOf(address(tm)));
        assertEq(tm.principalByAdapter(address(shareAdapter)), 8_000 * ONE - 1);
        assertEq(tm.pool(), address(pool));
        assertEq(tm.creditLineKind(), tm.KIND());
        assertEq(tm.effectiveLtvBps(id), 8_000);
    }

    function test_revert_openTab() public {
        vm.startPrank(alice);
        tm.openTab(address(shareAdapter));
        vm.expectRevert(TabManager.TabExists.selector);
        tm.openTab(address(shareAdapter));
        vm.expectRevert(TabManager.InvalidStatus.selector);
        tm.openTab(address(0xBEEF));
        vm.stopPrank();
        uint256 flag = tm.PAUSE_OPEN();
        vm.prank(guardian);
        tm.pause(flag);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TabbAccessControl.ActionPaused.selector, flag));
        tm.openTab(address(shareAdapter));
    }

    function test_revert_addCollateral() public {
        uint256 id = _shareTab(alice, SH);
        vm.startPrank(alice);
        vm.expectRevert(TabManager.ZeroAmount.selector);
        tm.addCollateral(id, 0);
        vm.expectRevert(TabManager.TabNotOpen.selector);
        tm.addCollateral(999, 1);
        vm.stopPrank();
        // supply cap
        YieldRiskConfig.CollateralParams memory p = risk.collateral(address(shareAdapter));
        p.supplyCap = 10_500 * ONE;
        vm.prank(owner);
        risk.setCollateral(address(shareAdapter), p);
        vm.prank(alice);
        vm.expectRevert(TabManager.SupplyCapExceeded.selector);
        tm.addCollateral(id, 1_000 * ONE);
        // disabled collateral
        p.status = YieldRiskConfig.Status.Disabled;
        vm.prank(owner);
        risk.setCollateral(address(shareAdapter), p);
        vm.prank(alice);
        vm.expectRevert(TabManager.InvalidStatus.selector);
        tm.addCollateral(id, 1);
    }

    // ------------------------------------------------------------------ borrow

    function test_revert_borrowChecks() public {
        uint256 id = _shareTab(alice, SH);
        vm.prank(bob);
        vm.expectRevert(TabManager.NotOwner.selector);
        tm.borrow(id, 1);
        vm.startPrank(alice);
        vm.expectRevert(TabManager.ZeroAmount.selector);
        tm.borrow(id, 0);
        vm.expectRevert(TabManager.InsufficientCollateral.selector);
        tm.borrow(id, 8_000 * ONE + 1);
        vm.expectRevert(TabManager.BelowMinDebt.selector);
        tm.borrow(id, 9 * ONE);
        vm.stopPrank();
        uint256 flag = tm.PAUSE_BORROW();
        vm.prank(guardian);
        tm.pause(flag);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TabbAccessControl.ActionPaused.selector, flag));
        tm.borrow(id, 100 * ONE);
    }

    function test_revert_borrowCapAndFrozen() public {
        uint256 id = _shareTab(alice, SH);
        YieldRiskConfig.CollateralParams memory p = risk.collateral(address(shareAdapter));
        p.borrowCap = 1_000 * ONE;
        vm.prank(owner);
        risk.setCollateral(address(shareAdapter), p);
        vm.prank(alice);
        vm.expectRevert(TabManager.BorrowCapExceeded.selector);
        tm.borrow(id, 1_001 * ONE);
        assertEq(tm.maxBorrow(id), 1_000 * ONE);
        p.status = YieldRiskConfig.Status.Frozen;
        vm.prank(owner);
        risk.setCollateral(address(shareAdapter), p);
        vm.prank(alice);
        vm.expectRevert(TabManager.InvalidStatus.selector);
        tm.borrow(id, 100 * ONE);
    }

    function test_marketClosedFreezesYtBorrowAndWithdraw() public {
        uint256 id = _ytTab(alice, 1_000e18); // value 7,000
        _borrow(id, alice, 2_000 * ONE);
        vm.prank(owner);
        oracle.setMarketOpen(address(yt), false);
        assertEq(tm.effectiveLtvBps(id), 0);
        assertEq(tm.maxBorrow(id), 0);
        vm.prank(alice);
        vm.expectRevert(TabManager.BorrowFrozen.selector);
        tm.borrow(id, 100 * ONE);
        vm.prank(alice);
        vm.expectRevert(TabManager.InsufficientCollateral.selector);
        tm.withdrawCollateral(id, 1e18);
        // repay and adding collateral still work
        vm.prank(alice);
        tm.repay(id, 100 * ONE);
        vm.prank(alice);
        tm.addCollateral(id, 10e18);
    }

    function test_maturityBlocksBorrow() public {
        uint256 id = _ytTab(alice, 1_000e18);
        skip(701 days);
        ytFeed.set(10e8);
        seqFeed.setStartedAt(block.timestamp - 2 days);
        vm.prank(alice);
        vm.expectRevert(TabManager.MaturityTooClose.selector);
        tm.borrow(id, 100 * ONE);
    }

    function test_staleOracleBlocksYtBorrow() public {
        uint256 id = _ytTab(alice, 1_000e18);
        skip(2 hours);
        vm.prank(alice);
        vm.expectRevert(); // StalePrice from the oracle
        tm.borrow(id, 100 * ONE);
    }

    // ------------------------------------------------------------------ repay / withdraw / close

    function test_repayInterestFirstAndFull() public {
        uint256 id = _shareTab(alice, SH);
        _borrow(id, alice, 5_000 * ONE);
        skip(365 days);
        uint256 debt = tm.debtOf(id);
        uint256 interest = debt - 5_000 * ONE;
        assertGt(interest, 0);
        vm.prank(bob);
        tm.repay(id, interest);
        assertEq(tm.tabOf(id).principal, 5_000 * ONE);
        vm.prank(bob);
        uint256 paid = tm.repay(id, 1_000_000 * ONE);
        assertApproxEqAbs(paid, 5_000 * ONE, 2);
        assertEq(tm.debtOf(id), 0);
        assertEq(tm.tabOf(id).principal, 0);
        assertEq(tm.healthFactor(id), type(uint256).max);
        vm.expectRevert(TabManager.TabNotOpen.selector);
        tm.repay(999, 1);
        vm.expectRevert(TabManager.ZeroAmount.selector);
        tm.repay(id, 0);
        assertEq(tm.repay(id, 1), 0); // nothing owed
    }

    function test_withdrawCollateral() public {
        uint256 id = _shareTab(alice, SH);
        _borrow(id, alice, 4_000 * ONE);
        vm.prank(alice);
        tm.withdrawCollateral(id, 5_000 * ONE); // value 5,000 * 80% = 4,000 >= debt
        vm.prank(alice);
        vm.expectRevert(TabManager.InsufficientCollateral.selector);
        tm.withdrawCollateral(id, 1);
        vm.prank(alice);
        vm.expectRevert(TabManager.InsufficientCollateral.selector);
        tm.withdrawCollateral(id, 1_000_000 * ONE);
        vm.prank(bob);
        vm.expectRevert(TabManager.NotOwner.selector);
        tm.withdrawCollateral(id, 1);
        vm.prank(alice);
        vm.expectRevert(TabManager.ZeroAmount.selector);
        tm.withdrawCollateral(id, 0);
        uint256 flag = tm.PAUSE_WITHDRAW();
        vm.prank(guardian);
        tm.pause(flag);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TabbAccessControl.ActionPaused.selector, flag));
        tm.withdrawCollateral(id, 1);
    }

    function test_closeTab() public {
        uint256 id = _shareTab(alice, SH);
        _borrow(id, alice, 1_000 * ONE);
        vm.startPrank(alice);
        vm.expectRevert(TabManager.HasDebt.selector);
        tm.closeTab(id);
        tm.repay(id, 2_000 * ONE);
        vm.expectRevert(TabManager.HasCollateral.selector);
        tm.closeTab(id);
        tm.withdrawCollateral(id, SH);
        tm.closeTab(id);
        assertFalse(tm.tabOf(id).open);
        assertEq(tm.tabIdOf(alice, address(shareAdapter)), 0);
        assertEq(tm.maxBorrow(id), 0);
        // can reopen a fresh tab
        uint256 id2 = tm.openTab(address(shareAdapter));
        assertGt(id2, id);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(TabManager.NotOwner.selector);
        tm.closeTab(id2);
    }

    // ------------------------------------------------------------------ harvest

    function test_harvestRepaysAndRewards() public {
        uint256 id = _shareTab(alice, SH);
        _borrow(id, alice, 5_000 * ONE);
        vault.injectYield(30_000 * ONE); // +10% => 1,000 yield on 10k
        uint256 debtBefore = tm.debtOf(id);
        (uint256 y, uint256 reward, uint256 repaid, uint256 credited) = _harvest(id);
        assertApproxEqAbs(y, 1_000 * ONE, 3);
        assertEq(reward, y * 50 / 10_000); // 0.5%
        assertEq(usdg.balanceOf(keeper), reward);
        assertEq(repaid, y - reward);
        assertEq(credited, 0);
        assertEq(tm.debtOf(id), debtBefore - repaid);
        assertEq(tm.tabOf(id).yieldRepaid, repaid);
    }

    function test_harvestRewardCapAndCreditAfterPayoff() public {
        uint256 id = _shareTab(alice, SH);
        _borrow(id, alice, 100 * ONE);
        vault.injectYield(300_000 * ONE); // doubles price => 10,000 yield
        (uint256 y, uint256 reward, uint256 repaid, uint256 credited) = _harvest(id);
        assertEq(reward, 25 * ONE); // capped
        assertEq(repaid, 100 * ONE);
        assertEq(credited, y - reward - repaid);
        assertEq(tm.ownerCredit(alice), credited);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        tm.claimCredit();
        assertEq(usdg.balanceOf(alice) - before, credited);
        vm.prank(alice);
        vm.expectRevert(TabManager.ZeroAmount.selector);
        tm.claimCredit();
    }

    function test_revert_harvest() public {
        uint256 id = _shareTab(alice, SH);
        vm.prank(keeper);
        vm.expectRevert(TabManager.BelowMinHarvest.selector);
        harvester.harvest(id);
        vm.expectRevert(TabManager.NotHarvester.selector);
        tm.harvestFor(id, keeper);
        vm.prank(address(harvester));
        vm.expectRevert(TabManager.TabNotOpen.selector);
        tm.harvestFor(999, keeper);
    }

    function test_harvestMany() public {
        uint256 a = _shareTab(alice, SH);
        uint256 b = _shareTab(bob, SH);
        uint256 c = _ytTab(alice, 1_000e18);
        _borrow(a, alice, 1_000 * ONE);
        vault.injectYield(30_000 * ONE);
        uint256[] memory ids = new uint256[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c; // no dividends -> skipped
        vm.prank(keeper);
        (uint256 ok, uint256 totalReward) = harvester.harvestMany(ids);
        assertEq(ok, 2);
        assertGt(totalReward, 0);
        assertGt(tm.ownerCredit(bob), 0);
    }

    function test_ytHarvestFromDividends() public {
        uint256 id = _ytTab(alice, 10_000e18);
        _borrow(id, alice, 20_000 * ONE);
        yt.distributeDividend(300_000 * ONE); // 1 USDG / YT
        (uint256 y,, uint256 repaid,) = _harvest(id);
        assertApproxEqAbs(y, 10_000 * ONE, 2);
        assertGt(repaid, 9_900 * ONE);
    }

    // ------------------------------------------------------------------ liquidation

    function test_revert_liquidateHealthy() public {
        uint256 id = _shareTab(alice, SH);
        _borrow(id, alice, 5_000 * ONE);
        vm.prank(liq);
        vm.expectRevert(TabManager.Healthy.selector);
        liquidator.liquidate(id, 1_000 * ONE);
        vm.expectRevert(TabManager.NotLiquidator.selector);
        tm.liquidateFor(id, liq, 1);
        uint256 id2 = _shareTab(bob, SH);
        vm.prank(liq);
        vm.expectRevert(TabManager.Healthy.selector); // no debt
        liquidator.liquidate(id2, 1);
        vault.lose(100_000 * ONE);
        vm.prank(liq);
        vm.expectRevert(TabManager.ZeroAmount.selector);
        liquidator.liquidate(id, 0);
    }

    function test_partialLiquidation() public {
        uint256 id = _shareTab(alice, SH);
        _borrow(id, alice, 8_000 * ONE);
        vault.lose(15_000 * ONE); // -5%: value 9,500, HF = 9500*0.85/8000 = 1.009
        assertGt(tm.healthFactor(id), 1e18);
        vault.lose(15_000 * ONE); // -10%: value 9,000, HF = 0.956
        uint256 hf = tm.healthFactor(id);
        assertLt(hf, 1e18);
        assertGt(hf, 0.95e18);
        uint256 debt = tm.debtOf(id);
        uint256 sharesBefore = vault.balanceOf(liq);
        vm.prank(liq);
        (uint256 repaid, uint256 seized, uint256 bad) = liquidator.liquidate(id, type(uint256).max);
        assertApproxEqAbs(repaid, debt / 2, 2); // close factor 50%
        assertEq(bad, 0);
        assertEq(vault.balanceOf(liq) - sharesBefore, seized);
        // liquidator received repaid * 1.05 worth of collateral
        assertApproxEqAbs(vault.previewRedeem(seized), repaid * 105 / 100, 2e6);
        assertGt(tm.healthFactor(id), hf);
    }

    function test_fullLiquidationBelowThreshold() public {
        uint256 id = _shareTab(alice, SH);
        _borrow(id, alice, 8_000 * ONE);
        vault.lose(45_000 * ONE); // -15%: value 8,500, HF 0.903 < 0.95 -> full
        uint256 debt = tm.debtOf(id);
        vm.prank(liq);
        (uint256 repaid,,) = liquidator.liquidate(id, type(uint256).max);
        assertApproxEqAbs(repaid, debt, 2);
        assertEq(tm.debtOf(id), 0);
    }

    function test_liquidationBadDebt() public {
        uint256 id = _shareTab(alice, SH);
        _borrow(id, alice, 8_000 * ONE);
        vault.lose(90_000 * ONE); // -30%: value 7,000 < debt
        uint256 taBefore = pool.totalAssets();
        vm.prank(liq);
        (uint256 repaid, uint256 seized, uint256 bad) = liquidator.liquidate(id, type(uint256).max);
        assertEq(seized, SH);
        assertApproxEqAbs(repaid, 7_000 * ONE * 10_000 / 10_500, 3);
        assertGt(bad, 0);
        assertEq(tm.debtOf(id), 0);
        assertEq(tm.tabOf(id).principal, 0);
        assertApproxEqAbs(pool.totalAssets(), taBefore - bad, 3);
        assertEq(tm.totalScaledDebt(), pool.scaledDebtOf(address(tm)));
    }

    function test_dustDebtFullyLiquidatable() public {
        uint256 id = _shareTab(alice, 100 * ONE);
        _borrow(id, alice, 80 * ONE);
        vault.lose(15_000 * ONE); // -5%: HF 0.95+ but debt <= dust
        vault.lose(3_000 * ONE);
        assertLt(tm.healthFactor(id), 1e18);
        vm.prank(liq);
        (uint256 repaid,,) = liquidator.liquidate(id, type(uint256).max);
        assertApproxEqAbs(repaid, 80 * ONE, 1);
    }

    // ------------------------------------------------------------------ admin

    function test_peripheryOnce() public {
        vm.prank(owner);
        vm.expectRevert(TabManager.AlreadySet.selector);
        tm.setPeriphery(address(1), address(2));
        TabManager tm2 = new TabManager(IERC20(address(usdg)), ITabbPool(address(pool)), oracle, risk, owner, guardian);
        vm.prank(owner);
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        tm2.setPeriphery(address(0), address(2));
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        new TabManager(IERC20(address(0)), ITabbPool(address(pool)), oracle, risk, owner, guardian);
    }
}
