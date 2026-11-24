// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AgentFixture} from "../utils/AgentFixture.sol";
import {TabManager} from "../../src/yield/TabManager.sol";
import {ITabbPool} from "../../src/interfaces/ITabbPool.sol";
import {ICreditLine} from "../../src/interfaces/ICreditLine.sol";

/// @notice Proves the pool accepts a second credit line (Phase 2) without touching Phase 1.
contract Phase2StubTest is AgentFixture {
    TabManager tm;

    function setUp() public override {
        super.setUp();
        tm = new TabManager(ITabbPool(address(pool)));
        vm.prank(owner);
        pool.setCreditLine(address(tm), 10_000 * ONE, 0, true);
    }

    function test_secondCreditLineRegistered() public view {
        assertEq(pool.lineCount(), 2);
        assertEq(ICreditLine(address(tm)).pool(), address(pool));
        assertEq(tm.totalScaledDebt(), 0);
        assertTrue(tm.creditLineKind() != mgr.creditLineKind());
    }

    function test_agentCreditUnaffected() public {
        uint256 id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 100 * ONE);
        skip(30 days);
        // agent line pays base + 8% spread, yield line has no debt
        assertGt(pool.indexOf(address(mgr)), pool.indexOf(address(tm)));
        assertEq(pool.debtOf(address(tm)), 0);
    }

    function test_stubReverts() public {
        vm.expectRevert(TabManager.NotImplemented.selector);
        tm.openTab(address(1));
        vm.expectRevert(TabManager.NotImplemented.selector);
        tm.addCollateral(1, 1);
        vm.expectRevert(TabManager.NotImplemented.selector);
        tm.borrow(1, 1);
        vm.expectRevert(TabManager.NotImplemented.selector);
        tm.repay(1, 1);
        vm.expectRevert(TabManager.NotImplemented.selector);
        tm.withdrawCollateral(1, 1);
        vm.expectRevert(TabManager.NotImplemented.selector);
        tm.closeTab(1);
    }
}
