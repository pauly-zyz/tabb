// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnerStakeVault} from "../../src/agent/OwnerStakeVault.sol";
import {TabbAccessControl} from "../../src/access/TabbAccessControl.sol";
import {IAgentCreditManager} from "../../src/interfaces/IAgentCreditManager.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";
import {MockStakeLocker} from "../mocks/MockStakeLocker.sol";
import {MockFeeOnTransfer} from "../mocks/MockFeeOnTransfer.sol";

contract OwnerStakeVaultTest is Test {
    MockUSDG usdg;
    OwnerStakeVault vault;
    MockStakeLocker locker;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");

    function setUp() public {
        usdg = new MockUSDG();
        vault = new OwnerStakeVault(IERC20(address(usdg)), owner, guardian);
        locker = new MockStakeLocker();
        vm.prank(owner);
        vault.setManager(IAgentCreditManager(address(locker)));
        usdg.mint(alice, 1_000e6);
        vm.prank(alice);
        usdg.approve(address(vault), type(uint256).max);
    }

    function test_stakeAndWithdraw() public {
        vm.prank(alice);
        vault.stake(1, 300e6);
        assertEq(vault.stakeOf(1, alice), 300e6);
        assertEq(vault.totalStakeOf(1), 300e6);
        vm.prank(alice);
        vault.withdraw(1, 100e6, alice);
        assertEq(vault.stakeOf(1, alice), 200e6);
        assertEq(usdg.balanceOf(alice), 800e6);
    }

    function test_revert_withdrawLocked() public {
        vm.prank(alice);
        vault.stake(1, 300e6);
        locker.setLocked(1, alice, true);
        vm.prank(alice);
        vm.expectRevert(OwnerStakeVault.StakeLocked.selector);
        vault.withdraw(1, 1, alice);
    }

    function test_revert_withdrawChecks() public {
        vm.prank(alice);
        vault.stake(1, 300e6);
        vm.startPrank(alice);
        vm.expectRevert(OwnerStakeVault.ZeroAmount.selector);
        vault.withdraw(1, 0, alice);
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        vault.withdraw(1, 1, address(0));
        vm.expectRevert(OwnerStakeVault.InsufficientStake.selector);
        vault.withdraw(1, 301e6, alice);
        vm.expectRevert(OwnerStakeVault.ZeroAmount.selector);
        vault.stake(1, 0);
        vm.stopPrank();
    }

    function test_withdrawPaused() public {
        vm.prank(alice);
        vault.stake(1, 300e6);
        uint256 flag = vault.PAUSE_WITHDRAW();
        vm.prank(guardian);
        vault.pause(flag);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TabbAccessControl.ActionPaused.selector, flag));
        vault.withdraw(1, 1, alice);
        // staking still works while paused
        vm.prank(alice);
        vault.stake(1, 1);
    }

    function test_slash() public {
        vm.prank(alice);
        vault.stake(1, 300e6);
        uint256 s = locker.slash(vault, 1, alice, 500e6, address(this));
        assertEq(s, 300e6);
        assertEq(vault.stakeOf(1, alice), 0);
        assertEq(usdg.balanceOf(address(this)), 300e6);
        assertEq(locker.slash(vault, 1, alice, 1, address(this)), 0);
    }

    function test_revert_slashNotManager() public {
        vm.expectRevert(OwnerStakeVault.NotManager.selector);
        vault.slash(1, alice, 1, address(this));
    }

    function test_revert_setManagerTwice() public {
        vm.prank(owner);
        vm.expectRevert(OwnerStakeVault.ManagerAlreadySet.selector);
        vault.setManager(IAgentCreditManager(address(1)));
    }

    function test_revert_setManagerZero() public {
        OwnerStakeVault v2 = new OwnerStakeVault(IERC20(address(usdg)), owner, guardian);
        vm.prank(owner);
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        v2.setManager(IAgentCreditManager(address(0)));
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        new OwnerStakeVault(IERC20(address(0)), owner, guardian);
    }

    function test_withdrawWithoutManager() public {
        OwnerStakeVault v2 = new OwnerStakeVault(IERC20(address(usdg)), owner, guardian);
        vm.startPrank(alice);
        usdg.approve(address(v2), 10);
        v2.stake(5, 10);
        v2.withdraw(5, 10, alice);
        vm.stopPrank();
    }

    function test_revert_feeOnTransferToken() public {
        MockFeeOnTransfer fot = new MockFeeOnTransfer();
        OwnerStakeVault v2 = new OwnerStakeVault(IERC20(address(fot)), owner, guardian);
        fot.mint(alice, 1_000);
        vm.startPrank(alice);
        fot.approve(address(v2), 1_000);
        vm.expectRevert(OwnerStakeVault.UnsupportedToken.selector);
        v2.stake(1, 1_000);
        vm.stopPrank();
    }
}
