// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {YieldFixture} from "../utils/YieldFixture.sol";
import {ERC4626ShareAdapter} from "../../src/yield/ERC4626ShareAdapter.sol";
import {YieldTokenAdapter} from "../../src/yield/YieldTokenAdapter.sol";
import {IClipYieldToken} from "../../src/interfaces/IClipYieldToken.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

contract ERC4626ShareAdapterTest is YieldFixture {
    function test_metadataAndValue() public {
        assertEq(shareAdapter.asset(), address(vault));
        assertEq(shareAdapter.usdg(), address(usdg));
        assertFalse(shareAdapter.isEquityLinked());
        assertTrue(shareAdapter.canBorrow());
        uint256 shares = vault.balanceOf(alice) / 10;
        uint256 id = _shareTab(alice, shares);
        assertEq(shareAdapter.balanceOf(id), shares);
        assertEq(shareAdapter.totalBalance(), shares);
        assertApproxEqAbs(shareAdapter.valueInUSDG(id, 0), 10_000 * ONE, 1);
        assertEq(shareAdapter.pendingYield(id), 0);
        assertApproxEqAbs(shareAdapter.amountForValue(5_000 * ONE, 0), shares / 2, 1e6);
    }

    function test_yieldHarvestKeepsHighWaterMark() public {
        uint256 shares = vault.balanceOf(alice) / 10; // 10k USDG of the 100k vault... alice+bob+liq hold 300k
        uint256 id = _shareTab(alice, shares);
        vault.injectYield(30_000 * ONE); // +10% share price
        uint256 pend = shareAdapter.pendingYield(id);
        assertApproxEqAbs(pend, 1_000 * ONE, 2);
        vm.prank(address(tm));
        uint256 out = shareAdapter.harvest(id, address(this));
        assertApproxEqAbs(out, 1_000 * ONE, 2);
        assertLe(shareAdapter.pendingYield(id), 1);
        // price drop: no yield, high-water mark not lowered by a later harvest of 0
        vault.lose(30_000 * ONE);
        assertEq(shareAdapter.pendingYield(id), 0);
        vm.prank(address(tm));
        assertEq(shareAdapter.harvest(id, address(this)), 0);
    }

    function test_withdrawReducesPrincipalProportionally() public {
        uint256 shares = 1_000 * 1e6 * 1; // vault has 0 offset: 1 share = 1 USDG unit
        uint256 id = _shareTab(alice, shares);
        uint256 p0 = shareAdapter.principalAssets(id);
        vm.prank(address(tm));
        shareAdapter.withdraw(id, alice, shares / 4);
        assertApproxEqAbs(shareAdapter.principalAssets(id), p0 * 3 / 4, 1);
        vm.prank(address(tm));
        shareAdapter.seize(id, bob, shares / 4);
        assertApproxEqAbs(shareAdapter.principalAssets(id), p0 / 2, 1);
        vm.prank(address(tm));
        vm.expectRevert(ERC4626ShareAdapter.InsufficientBalance.selector);
        shareAdapter.withdraw(id, alice, shares);
    }

    function test_revert_onlyTabManagerAndZero() public {
        vm.expectRevert(ERC4626ShareAdapter.NotTabManager.selector);
        shareAdapter.deposit(1, alice, 1);
        vm.expectRevert(ERC4626ShareAdapter.NotTabManager.selector);
        shareAdapter.harvest(1, alice);
        vm.expectRevert(ERC4626ShareAdapter.ZeroAddress.selector);
        new ERC4626ShareAdapter(IERC4626(address(vault)), address(0));
    }
}

contract YieldTokenAdapterTest is YieldFixture {
    function test_metadataAndHaircut() public {
        assertEq(ytAdapter.asset(), address(yt));
        assertEq(ytAdapter.usdg(), address(usdg));
        assertTrue(ytAdapter.isEquityLinked());
        assertTrue(ytAdapter.canBorrow());
        // 2 years to maturity: 10% + 20% = 30%
        assertEq(ytAdapter.haircutBps(), 3_000);
        // 1,000 YT * $10 * 70% = 7,000 USDG
        assertEq(ytAdapter.valueOfAmount(1_000e18, 0), 7_000 * ONE);
        assertEq(ytAdapter.amountForValue(7_000 * ONE, 0), 1_000e18);
        assertEq(ytAdapter.valueOfAmount(0, 0), 0);
        skip(701 days);
        ytFeed.set(10e8);
        assertFalse(ytAdapter.canBorrow()); // < 30 days to maturity
        assertEq(ytAdapter.haircutBps(), 1_000 + uint256(1_000) * 29 days / 365 days);
        skip(60 days);
        assertEq(ytAdapter.timeToMaturity(), 0);
        assertEq(ytAdapter.haircutBps(), 1_000);
    }

    function test_maxHaircutCap() public {
        YieldTokenAdapter a = new YieldTokenAdapter(
            IClipYieldToken(address(yt)),
            IERC20(address(usdg)),
            oracle,
            address(tm),
            YieldTokenAdapter.Haircut({baseBps: 1_000, annualBps: 5_000, maxBps: 5_000, minTimeToMaturity: 0})
        );
        assertEq(a.haircutBps(), 5_000);
    }

    function test_usdgAbovePegIsConservative() public {
        MockAggregator usdgFeed = new MockAggregator(8, 1.25e8);
        vm.prank(owner);
        oracle.setFeed(address(usdg), IAggregatorV3(address(usdgFeed)), 1 days, 1 days);
        assertEq(ytAdapter.valueOfAmount(1_000e18, 0), 5_600 * ONE); // 7000 / 1.25
        usdgFeed.set(0.9e8); // below peg -> treated as $1
        assertEq(ytAdapter.valueOfAmount(1_000e18, 0), 7_000 * ONE);
    }

    function test_dividendAttributionAcrossTabs() public {
        uint256 a = _ytTab(alice, 1_000e18);
        uint256 b = _ytTab(bob, 3_000e18);
        // total YT supply is 300,000 (adapter holds 4,000 of it)
        yt.distributeDividend(300_000 * ONE); // 1 USDG per YT
        assertApproxEqAbs(ytAdapter.pendingYield(a), 1_000 * ONE, 2);
        assertApproxEqAbs(ytAdapter.pendingYield(b), 3_000 * ONE, 2);
        // alice adds more YT: her pending stays, new YT does not earn past dividends
        vm.prank(alice);
        tm.addCollateral(a, 1_000e18);
        assertApproxEqAbs(ytAdapter.pendingYield(a), 1_000 * ONE, 2);
        yt.distributeDividend(300_000 * ONE); // +1 per YT
        assertApproxEqAbs(ytAdapter.pendingYield(a), 3_000 * ONE, 4);
        assertApproxEqAbs(ytAdapter.pendingYield(b), 6_000 * ONE, 4);
        // valuation includes pending dividends
        assertApproxEqAbs(ytAdapter.valueInUSDG(a, 2), 14_000 * ONE + 3_000 * ONE, 4);
        vm.prank(address(tm));
        uint256 out = ytAdapter.harvest(b, address(this));
        assertApproxEqAbs(out, 6_000 * ONE, 4);
        assertEq(ytAdapter.pendingYield(b), 0);
        vm.prank(address(tm));
        assertEq(ytAdapter.harvest(b, address(this)), 0);
        vm.prank(address(tm));
        ytAdapter.seize(a, liq, 500e18);
        assertEq(ytAdapter.balanceOf(a), 1_500e18);
        assertApproxEqAbs(ytAdapter.pendingYield(a), 3_000 * ONE, 4);
        vm.prank(address(tm));
        vm.expectRevert(YieldTokenAdapter.InsufficientBalance.selector);
        ytAdapter.withdraw(a, alice, 2_000e18);
    }

    function test_revert_constructorAndAccess() public {
        YieldTokenAdapter.Haircut memory h =
            YieldTokenAdapter.Haircut({baseBps: 6_000, annualBps: 0, maxBps: 5_000, minTimeToMaturity: 0});
        vm.expectRevert(YieldTokenAdapter.InvalidHaircut.selector);
        new YieldTokenAdapter(IClipYieldToken(address(yt)), IERC20(address(usdg)), oracle, address(tm), h);
        h.baseBps = 0;
        h.maxBps = 10_000;
        vm.expectRevert(YieldTokenAdapter.InvalidHaircut.selector);
        new YieldTokenAdapter(IClipYieldToken(address(yt)), IERC20(address(usdg)), oracle, address(tm), h);
        vm.expectRevert(YieldTokenAdapter.ZeroAddress.selector);
        new YieldTokenAdapter(IClipYieldToken(address(0)), IERC20(address(usdg)), oracle, address(tm), h);
        vm.expectRevert(YieldTokenAdapter.NotTabManager.selector);
        ytAdapter.deposit(1, alice, 1);
        vm.expectRevert(YieldTokenAdapter.NotTabManager.selector);
        ytAdapter.seize(1, alice, 1);
        vm.expectRevert(YieldTokenAdapter.NotTabManager.selector);
        ytAdapter.withdraw(1, alice, 1);
        vm.expectRevert(YieldTokenAdapter.NotTabManager.selector);
        ytAdapter.harvest(1, alice);
    }
}
