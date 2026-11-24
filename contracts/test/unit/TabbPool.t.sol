// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {TabbPool} from "../../src/pool/TabbPool.sol";
import {InterestRateModel} from "../../src/pool/InterestRateModel.sol";
import {TabbAccessControl} from "../../src/access/TabbAccessControl.sol";
import {ITabbPool} from "../../src/interfaces/ITabbPool.sol";
import {ILossAbsorber} from "../../src/interfaces/ILossAbsorber.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";
import {MockCreditLine} from "../mocks/MockCreditLine.sol";
import {MockLossAbsorber} from "../mocks/MockLossAbsorber.sol";

contract TabbPoolTest is Test {
    MockUSDG usdg;
    TabbPool pool;
    InterestRateModel irm;
    MockCreditLine lineA;
    MockCreditLine lineB;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address sink = makeAddr("sink");
    address treasury = makeAddr("treasury");

    uint256 constant ONE = 1e6;

    function setUp() public {
        usdg = new MockUSDG();
        irm = new InterestRateModel(0, 0.06e18, 0.8e18, 0.6e18);
        pool = new TabbPool(IERC20(address(usdg)), "Tabb USDG", "tUSDG", owner, guardian, irm, treasury, 1_000);
        lineA = new MockCreditLine(ITabbPool(address(pool)), IERC20(address(usdg)));
        lineB = new MockCreditLine(ITabbPool(address(pool)), IERC20(address(usdg)));
        vm.startPrank(owner);
        pool.setCreditLine(address(lineA), 1_000_000 * ONE, 800, true);
        pool.setCreditLine(address(lineB), 1_000_000 * ONE, 0, true);
        vm.stopPrank();
        usdg.mint(alice, 1_000_000 * ONE);
        usdg.mint(bob, 1_000_000 * ONE);
        vm.prank(alice);
        usdg.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        usdg.approve(address(pool), type(uint256).max);
    }

    function _deposit(address who, uint256 amt) internal returns (uint256) {
        vm.prank(who);
        return pool.deposit(amt, who);
    }

    // ---------------- ERC-4626 basics ----------------

    function test_metadata() public view {
        assertEq(pool.decimals(), 12);
        assertEq(pool.asset(), address(usdg));
        assertEq(pool.owner(), owner);
        assertEq(pool.guardian(), guardian);
    }

    function test_depositWithdraw() public {
        uint256 shares = _deposit(alice, 1_000 * ONE);
        assertEq(shares, 1_000 * ONE * 1e6);
        assertEq(pool.totalAssets(), 1_000 * ONE);
        vm.prank(alice);
        pool.withdraw(400 * ONE, alice, alice);
        assertEq(pool.totalAssets(), 600 * ONE);
        uint256 bal = pool.balanceOf(alice);
        vm.prank(alice);
        pool.redeem(bal, alice, alice);
        assertEq(pool.totalAssets(), 0);
        assertEq(usdg.balanceOf(alice), 1_000_000 * ONE);
    }

    function test_mint() public {
        vm.prank(alice);
        uint256 assets = pool.mint(5e12, alice);
        assertEq(assets, 5 * ONE);
    }

    function test_inflationAttackUnprofitable() public {
        // attacker deposits 1 wei, then donates a large amount to inflate share price
        _deposit(bob, 1);
        vm.prank(bob);
        usdg.transfer(address(pool), 10_000 * ONE);
        // victim deposits
        uint256 victimShares = _deposit(alice, 1_000 * ONE);
        assertGt(victimShares, 0);
        uint256 victimAssets = pool.previewRedeem(victimShares);
        // victim loses a negligible amount (< 0.01 USDG on a 10k USDG donation) thanks to the virtual offset
        assertApproxEqAbs(victimAssets, 1_000 * ONE, 10_000);
        // attacker cannot extract more than they put in
        uint256 attackerAssets = pool.previewRedeem(pool.balanceOf(bob));
        assertLt(attackerAssets, 10_000 * ONE + 1);
    }

    // ---------------- credit lines ----------------

    function test_drawAndRepay() public {
        _deposit(alice, 1_000 * ONE);
        uint256 scaled = lineA.draw(400 * ONE, sink);
        assertEq(scaled, 400 * ONE); // index = 1 RAY at t0
        assertEq(usdg.balanceOf(sink), 400 * ONE);
        assertEq(pool.debtOf(address(lineA)), 400 * ONE);
        assertEq(pool.totalAssets(), 1_000 * ONE);
        assertEq(pool.availableLiquidity(), 600 * ONE);

        usdg.mint(address(lineA), 400 * ONE);
        uint256 paid = lineA.repay(scaled);
        assertEq(paid, 400 * ONE);
        assertEq(pool.debtOf(address(lineA)), 0);
    }

    function test_revert_drawNotLine() public {
        _deposit(alice, 1_000 * ONE);
        vm.expectRevert(TabbPool.NotCreditLine.selector);
        pool.draw(1, sink);
    }

    function test_revert_drawInactive() public {
        _deposit(alice, 1_000 * ONE);
        vm.prank(owner);
        pool.setCreditLine(address(lineA), 1_000 * ONE, 0, false);
        vm.expectRevert(TabbPool.CreditLineInactive.selector);
        lineA.draw(1, sink);
    }

    function test_revert_drawCap() public {
        _deposit(alice, 1_000 * ONE);
        vm.prank(owner);
        pool.setCreditLine(address(lineA), 100 * ONE, 0, true);
        vm.expectRevert(TabbPool.CapExceeded.selector);
        lineA.draw(101 * ONE, sink);
    }

    function test_revert_drawLiquidity() public {
        _deposit(alice, 100 * ONE);
        vm.expectRevert(TabbPool.InsufficientLiquidity.selector);
        lineA.draw(101 * ONE, sink);
    }

    function test_revert_drawZero() public {
        _deposit(alice, 100 * ONE);
        vm.expectRevert(TabbPool.ZeroAmount.selector);
        lineA.draw(0, sink);
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        lineA.draw(1, address(0));
    }

    function test_revert_repayTooMuchAndZero() public {
        _deposit(alice, 100 * ONE);
        lineA.draw(10 * ONE, sink);
        vm.expectRevert(TabbPool.ExceedsDebt.selector);
        lineA.repay(11 * ONE);
        vm.expectRevert(TabbPool.ZeroAmount.selector);
        lineA.repay(0);
    }

    function test_interestAccruesWithSpread() public {
        _deposit(alice, 1_000 * ONE);
        lineA.draw(400 * ONE, sink); // spread 8%
        lineB.draw(400 * ONE, sink); // spread 0
        // utilization 80% => base rate 6%
        assertEq(pool.utilization(), 0.8e18);
        assertEq(pool.borrowRateOf(address(lineA)), 0.14e18);
        assertEq(pool.borrowRateOf(address(lineB)), 0.06e18);
        skip(365 days);
        // linear growth for one accrual period
        assertApproxEqAbs(pool.debtOf(address(lineA)), 456 * ONE, 1);
        assertApproxEqAbs(pool.debtOf(address(lineB)), 424 * ONE, 1);
        // interest = 80; treasury 10% = 8; lenders 72
        assertApproxEqAbs(pool.treasuryAssets(), 8 * ONE, 2);
        pool.accrue();
        assertApproxEqAbs(pool.treasuryAssets(), 8 * ONE, 2);
        assertApproxEqAbs(pool.totalAssets(), 1_080 * ONE, 3);
        assertApproxEqAbs(pool.previewRedeem(pool.balanceOf(alice)), 1_072 * ONE, 3);
    }

    function test_supplyRate() public {
        _deposit(alice, 1_000 * ONE);
        assertEq(pool.supplyRate(), 0);
        lineA.draw(400 * ONE, sink);
        lineB.draw(400 * ONE, sink);
        // (0.14*400 + 0.06*400)/1000 * 0.9 = 0.072
        assertApproxEqAbs(pool.supplyRate(), 0.072e18, 1e12);
    }

    function test_withdrawCappedByLiquidity() public {
        _deposit(alice, 1_000 * ONE);
        lineA.draw(900 * ONE, sink);
        assertEq(pool.maxWithdraw(alice), 100 * ONE);
        assertLe(pool.previewRedeem(pool.maxRedeem(alice)), 100 * ONE);
        vm.prank(alice);
        vm.expectRevert();
        pool.withdraw(101 * ONE, alice, alice);
    }

    function test_treasuryCanRedeemReserves() public {
        _deposit(alice, 1_000 * ONE);
        lineA.draw(500 * ONE, sink);
        skip(365 days);
        pool.accrue();
        uint256 tShares = pool.balanceOf(treasury);
        assertGt(tShares, 0);
        uint256 expected = pool.previewRedeem(tShares);
        vm.prank(treasury);
        pool.redeem(tShares, treasury, treasury);
        assertEq(usdg.balanceOf(treasury), expected);
    }

    function test_writeOffBurnsTreasuryThenLenders() public {
        _deposit(alice, 1_000 * ONE);
        uint256 scaled = lineA.draw(500 * ONE, sink);
        skip(365 days);
        pool.accrue();
        uint256 tAssets = pool.treasuryAssets();
        uint256 aliceBefore = pool.previewRedeem(pool.balanceOf(alice));
        uint256 debt = pool.debtOf(address(lineA));
        uint256 loss = lineA.writeOff(scaled);
        assertEq(loss, debt);
        assertEq(pool.balanceOf(treasury), 0);
        // lenders lose loss - treasury cover
        assertApproxEqAbs(pool.previewRedeem(pool.balanceOf(alice)), aliceBefore - (loss - tAssets), 3);
        assertLe(pool.totalDebt(), pool.totalAssets());
    }

    function test_writeOffSmallLossFullyCoveredByTreasury() public {
        _deposit(alice, 1_000 * ONE);
        lineA.draw(500 * ONE, sink);
        uint256 s2 = lineB.draw(1 * ONE, sink);
        skip(365 days);
        pool.accrue();
        uint256 aliceBefore = pool.previewRedeem(pool.balanceOf(alice));
        lineB.writeOff(s2); // ~1.06 loss, treasury holds > 3
        assertGt(pool.balanceOf(treasury), 0);
        uint256 aliceAfter = pool.previewRedeem(pool.balanceOf(alice));
        assertGe(aliceAfter + 2, aliceBefore); // lenders are made whole
        assertApproxEqRel(aliceAfter, aliceBefore, 1e13); // within 0.001%
    }

    function test_writeOffAbsorberFirst() public {
        MockLossAbsorber ab = new MockLossAbsorber(IERC20(address(usdg)), address(pool));
        usdg.mint(address(ab), 1_000 * ONE);
        vm.prank(owner);
        pool.setLossAbsorber(ILossAbsorber(address(ab)));
        _deposit(alice, 1_000 * ONE);
        uint256 scaled = lineA.draw(300 * ONE, sink);
        uint256 taBefore = pool.totalAssets();
        lineA.writeOff(scaled);
        assertEq(pool.totalAssets(), taBefore); // fully absorbed
    }

    function test_writeOffAbsorberRevertIsTolerated() public {
        MockLossAbsorber ab = new MockLossAbsorber(IERC20(address(usdg)), address(pool));
        ab.setRevert(true);
        vm.prank(owner);
        pool.setLossAbsorber(ILossAbsorber(address(ab)));
        _deposit(alice, 1_000 * ONE);
        uint256 scaled = lineA.draw(300 * ONE, sink);
        lineA.writeOff(scaled);
        assertEq(pool.totalAssets(), 700 * ONE);
    }

    function test_revert_writeOffChecks() public {
        _deposit(alice, 1_000 * ONE);
        lineA.draw(1 * ONE, sink);
        vm.expectRevert(TabbPool.ZeroAmount.selector);
        lineA.writeOff(0);
        vm.expectRevert(TabbPool.ExceedsDebt.selector);
        lineA.writeOff(2 * ONE);
        vm.expectRevert(TabbPool.NotCreditLine.selector);
        pool.writeOff(1);
    }

    function test_donationIncreasesShareValue() public {
        _deposit(alice, 1_000 * ONE);
        vm.prank(bob);
        usdg.transfer(address(pool), 100 * ONE);
        assertApproxEqAbs(pool.previewRedeem(pool.balanceOf(alice)), 1_100 * ONE, 1);
    }

    // ---------------- pause ----------------

    function test_pauseFlags() public {
        uint256 flags = pool.PAUSE_DEPOSIT() | pool.PAUSE_WITHDRAW() | pool.PAUSE_DRAW();
        vm.prank(guardian);
        pool.pause(flags);
        assertEq(pool.maxDeposit(alice), 0);
        assertEq(pool.maxMint(alice), 0);
        assertEq(pool.maxWithdraw(alice), 0);
        assertEq(pool.maxRedeem(alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        pool.deposit(1, alice);
        vm.expectRevert(abi.encodeWithSelector(TabbAccessControl.ActionPaused.selector, pool.PAUSE_DRAW()));
        lineA.draw(1, sink);

        // guardian cannot unpause
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        pool.unpause(type(uint256).max);
        vm.prank(owner);
        pool.unpause(type(uint256).max);
        _deposit(alice, 10 * ONE);
    }

    function test_revert_pauseByStranger() public {
        vm.expectRevert(TabbAccessControl.NotGuardianOrOwner.selector);
        pool.pause(1);
    }

    function test_repayWorksWhilePaused() public {
        _deposit(alice, 100 * ONE);
        uint256 s = lineA.draw(10 * ONE, sink);
        vm.prank(guardian);
        pool.pause(type(uint256).max);
        usdg.mint(address(lineA), 10 * ONE);
        lineA.repay(s);
        assertEq(pool.debtOf(address(lineA)), 0);
    }

    // ---------------- admin ----------------

    function test_adminSetters() public {
        InterestRateModel irm2 = new InterestRateModel(0.01e18, 0.05e18, 0.9e18, 1e18);
        vm.startPrank(owner);
        pool.setInterestRateModel(irm2);
        assertEq(address(pool.interestRateModel()), address(irm2));
        pool.setReserveFactor(2_000);
        assertEq(pool.reserveFactorBps(), 2_000);
        vm.expectRevert(TabbPool.InvalidParam.selector);
        pool.setReserveFactor(5_001);
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        pool.setInterestRateModel(InterestRateModel(address(0)));
        vm.expectRevert(TabbPool.InvalidParam.selector);
        pool.setCreditLine(address(1), 1, 5_001, true);
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        pool.setCreditLine(address(0), 1, 0, true);
        pool.setGuardian(alice);
        assertEq(pool.guardian(), alice);
        pool.setTreasury(bob);
        assertEq(pool.treasury(), bob);
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        pool.setTreasury(address(0));
        vm.stopPrank();
        assertEq(pool.lineCount(), 2);
        assertTrue(pool.creditLine(address(lineA)).active);
    }

    function test_revert_tooManyLines() public {
        vm.startPrank(owner);
        for (uint160 i = 1; i <= 6; i++) {
            pool.setCreditLine(address(i), 1, 0, true);
        }
        vm.expectRevert(TabbPool.TooManyLines.selector);
        pool.setCreditLine(address(7), 1, 0, true);
        vm.stopPrank();
    }

    function test_revert_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        pool.setCreditLine(address(1), 1, 0, true);
    }

    function test_revert_constructor() public {
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        new TabbPool(IERC20(address(usdg)), "x", "x", owner, guardian, InterestRateModel(address(0)), treasury, 0);
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        new TabbPool(IERC20(address(usdg)), "x", "x", owner, guardian, irm, address(0), 0);
        vm.expectRevert(TabbPool.InvalidParam.selector);
        new TabbPool(IERC20(address(usdg)), "x", "x", owner, guardian, irm, treasury, 5_001);
    }

    function test_ownable2Step() public {
        vm.prank(owner);
        pool.transferOwnership(alice);
        assertEq(pool.owner(), owner);
        vm.prank(alice);
        pool.acceptOwnership();
        assertEq(pool.owner(), alice);
    }

    // ---------------- fuzz ----------------

    function testFuzz_depositRedeemNoProfit(uint256 amt) public {
        amt = bound(amt, 1, 1_000_000 * ONE);
        uint256 before = usdg.balanceOf(alice);
        uint256 shares = _deposit(alice, amt);
        vm.prank(alice);
        pool.redeem(shares, alice, alice);
        assertLe(usdg.balanceOf(alice), before);
    }

    function testFuzz_drawRepayInterest(uint256 dep, uint256 drawAmt, uint256 dt) public {
        dep = bound(dep, 1_000 * ONE, 1_000_000 * ONE);
        drawAmt = bound(drawAmt, 1, dep);
        dt = bound(dt, 0, 3 * 365 days);
        _deposit(alice, dep);
        uint256 scaled = lineA.draw(drawAmt, sink);
        skip(dt);
        assertLe(pool.totalDebt(), pool.totalAssets());
        uint256 debt = pool.debtOf(address(lineA));
        assertGe(debt, drawAmt);
        usdg.mint(address(lineA), debt);
        uint256 paid = lineA.repay(scaled);
        assertEq(paid, debt);
        assertEq(pool.debtOf(address(lineA)), 0);
        // lenders never lose money when debt is repaid in full
        assertGe(pool.previewRedeem(pool.balanceOf(alice)) + 1, dep);
    }
}
