// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {YieldFixture} from "../utils/YieldFixture.sol";
import {TabManager} from "../../src/yield/TabManager.sol";
import {TabbPool} from "../../src/pool/TabbPool.sol";
import {YieldHarvester} from "../../src/yield/YieldHarvester.sol";
import {Liquidator} from "../../src/yield/Liquidator.sol";
import {MockERC4626Vault} from "../mocks/MockERC4626Vault.sol";
import {MockYieldToken} from "../mocks/MockYieldToken.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";

contract YieldHandler is Test {
    TabManager tm;
    TabbPool pool;
    YieldHarvester harvester;
    Liquidator liquidator;
    MockERC4626Vault vault;
    MockYieldToken yt;
    MockAggregator ytFeed;
    MockAggregator seqFeed;
    MockUSDG usdg;
    address lender;
    address liq;
    uint256[] public ids;
    address[] public owners;

    uint256 public ghost_unhealthyAfterBorrowOrWithdraw;
    uint256 public ghost_harvestIncreasedDebt;
    uint256 public ghost_lenderOverWithdraw;

    struct Deps {
        TabManager tm;
        TabbPool pool;
        YieldHarvester harvester;
        Liquidator liquidator;
        MockERC4626Vault vault;
        MockYieldToken yt;
        MockAggregator ytFeed;
        MockAggregator seqFeed;
        MockUSDG usdg;
        address lender;
        address liq;
    }

    constructor(Deps memory d, uint256[] memory ids_, address[] memory owners_) {
        tm = d.tm;
        pool = d.pool;
        harvester = d.harvester;
        liquidator = d.liquidator;
        vault = d.vault;
        yt = d.yt;
        ytFeed = d.ytFeed;
        seqFeed = d.seqFeed;
        usdg = d.usdg;
        lender = d.lender;
        liq = d.liq;
        ids = ids_;
        owners = owners_;
    }

    function _pick(uint256 s) internal view returns (uint256, address) {
        uint256 i = s % ids.length;
        return (ids[i], owners[i]);
    }

    function borrow(uint256 s, uint256 amt) external {
        (uint256 id, address who) = _pick(s);
        uint256 m;
        try tm.maxBorrow(id) returns (uint256 x) {
            m = x;
        } catch {
            return;
        }
        if (m < 10e6) return;
        amt = bound(amt, 10e6, m);
        vm.prank(who);
        try tm.borrow(id, amt) {
            if (tm.healthFactor(id) < 1e18) ghost_unhealthyAfterBorrowOrWithdraw++;
        } catch {}
    }

    function repay(uint256 s, uint256 amt) external {
        (uint256 id, address who) = _pick(s);
        amt = bound(amt, 1, 50_000e6);
        vm.prank(who);
        try tm.repay(id, amt) {} catch {}
    }

    function withdraw(uint256 s, uint256 amt) external {
        (uint256 id, address who) = _pick(s);
        amt = bound(amt, 1, 10_000e18);
        vm.prank(who);
        try tm.withdrawCollateral(id, amt) {
            if (tm.healthFactor(id) < 1e18) ghost_unhealthyAfterBorrowOrWithdraw++;
        } catch {}
    }

    function harvest(uint256 s) external {
        (uint256 id,) = _pick(s);
        uint256 before = tm.debtOf(id);
        try harvester.harvest(id) {
            if (tm.debtOf(id) > before) ghost_harvestIncreasedDebt++;
        } catch {}
    }

    function liquidate(uint256 s, uint256 amt) external {
        (uint256 id,) = _pick(s);
        amt = bound(amt, 1, 100_000e6);
        vm.prank(liq);
        try liquidator.liquidate(id, amt) {} catch {}
    }

    function vaultYield(uint256 amt) external {
        vault.injectYield(bound(amt, 1, 30_000e6));
    }

    function vaultLoss(uint256 bpsLoss) external {
        bpsLoss = bound(bpsLoss, 1, 1_500);
        vault.lose(vault.totalAssets() * bpsLoss / 10_000);
    }

    function dividend(uint256 amt) external {
        yt.distributeDividend(bound(amt, 1e6, 100_000e6));
    }

    function ytPrice(uint256 px) external {
        ytFeed.set(int256(bound(px, 1e8, 20e8)));
    }

    function warp(uint256 dt) external {
        skip(bound(dt, 1 minutes, 30 days));
        ytFeed.set(ytFeed.answer());
    }

    function lenderWithdraw(uint256 amt) external {
        uint256 m = pool.maxWithdraw(lender);
        if (m == 0) return;
        amt = bound(amt, 1, m);
        uint256 entitled = pool.convertToAssets(pool.balanceOf(lender));
        vm.prank(lender);
        pool.withdraw(amt, lender, lender);
        if (amt > entitled) ghost_lenderOverWithdraw++;
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }
}

contract YieldInvariantTest is YieldFixture {
    YieldHandler handler;

    function setUp() public override {
        super.setUp();
        uint256[] memory ids = new uint256[](4);
        address[] memory owners = new address[](4);
        ids[0] = _shareTab(alice, 20_000 * ONE);
        owners[0] = alice;
        ids[1] = _shareTab(bob, 50_000 * ONE);
        owners[1] = bob;
        ids[2] = _ytTab(alice, 5_000e18);
        owners[2] = alice;
        ids[3] = _ytTab(bob, 2_000e18);
        owners[3] = bob;
        handler = new YieldHandler(
            YieldHandler.Deps(tm, pool, harvester, liquidator, vault, yt, ytFeed, seqFeed, usdg, lender, liq),
            ids,
            owners
        );
        targetContract(address(handler));
    }

    /// total debt <= total pool assets
    function invariant_debtLeAssets() public view {
        assertLe(pool.totalDebt(), pool.totalAssets());
    }

    /// no position has HF < 1 right after borrow or withdrawCollateral
    function invariant_healthyAfterBorrowWithdraw() public view {
        assertEq(handler.ghost_unhealthyAfterBorrowOrWithdraw(), 0);
    }

    /// lenders can never withdraw more than their shares are worth
    function invariant_lenderBounded() public view {
        assertEq(handler.ghost_lenderOverWithdraw(), 0);
        assertLe(pool.maxWithdraw(lender), pool.convertToAssets(pool.balanceOf(lender)));
    }

    /// harvest never increases debt
    function invariant_harvestNeverIncreasesDebt() public view {
        assertEq(handler.ghost_harvestIncreasedDebt(), 0);
    }

    function invariant_scaledDebtConsistency() public view {
        uint256 sum;
        for (uint256 i; i < handler.idCount(); ++i) {
            sum += tm.tabOf(handler.ids(i)).scaledDebt;
        }
        assertEq(sum, tm.totalScaledDebt());
        assertEq(sum, pool.scaledDebtOf(address(tm)));
    }

    function invariant_adapterCustody() public view {
        assertEq(vault.balanceOf(address(shareAdapter)), shareAdapter.totalBalance());
        assertEq(yt.balanceOf(address(ytAdapter)), ytAdapter.totalBalance());
    }
}
