// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TabbPool} from "../../src/pool/TabbPool.sol";
import {AgentCreditManager as ACM} from "../../src/agent/AgentCreditManager.sol";
import {OwnerStakeVault} from "../../src/agent/OwnerStakeVault.sol";
import {PolicyAccount} from "../../src/agent/PolicyAccount.sol";
import {RepaymentSplitter} from "../../src/agent/RepaymentSplitter.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";

contract AgentHandler is Test {
    MockUSDG public usdg;
    TabbPool public pool;
    ACM public mgr;
    OwnerStakeVault public vault;
    address public lender;
    address public operator;
    address public provider;
    address public attacker = address(0xBAD);
    address public client = address(0xC11E);

    uint256[] public ids;
    address[] public owners;

    // ghosts
    uint256 public ghost_drawOverLimit;
    uint256 public ghost_revenueIncreasedDebt;
    uint256 public ghost_stakeWithdrawnWithDebt;
    uint256 public ghost_defaultLeftDebt;
    uint256 public ghost_lenderOverWithdraw;
    uint256 public calls;

    constructor(
        MockUSDG usdg_,
        TabbPool pool_,
        ACM mgr_,
        OwnerStakeVault vault_,
        address lender_,
        address operator_,
        address provider_,
        uint256[] memory ids_,
        address[] memory owners_
    ) {
        usdg = usdg_;
        pool = pool_;
        mgr = mgr_;
        vault = vault_;
        lender = lender_;
        operator = operator_;
        provider = provider_;
        ids = ids_;
        owners = owners_;
        usdg.mint(client, 1e15);
    }

    function _pick(uint256 seed) internal view returns (uint256 id, address who) {
        uint256 i = seed % ids.length;
        return (ids[i], owners[i]);
    }

    function lenderDeposit(uint256 amt) external {
        calls++;
        amt = bound(amt, 1, 50_000e6);
        usdg.mint(lender, amt);
        vm.startPrank(lender);
        usdg.approve(address(pool), amt);
        pool.deposit(amt, lender);
        vm.stopPrank();
    }

    function lenderWithdraw(uint256 amt) external {
        calls++;
        uint256 maxW = pool.maxWithdraw(lender);
        if (maxW == 0) return;
        amt = bound(amt, 1, maxW);
        uint256 entitled = pool.convertToAssets(pool.balanceOf(lender));
        vm.prank(lender);
        pool.withdraw(amt, lender, lender);
        if (amt > entitled) ghost_lenderOverWithdraw++;
    }

    function draw(uint256 seed, uint256 amt) external {
        calls++;
        (uint256 id, address who) = _pick(seed);
        uint256 avail = mgr.availableCredit(id);
        if (avail < 10e6) return;
        amt = bound(amt, 10e6, avail);
        vm.prank(who);
        try mgr.draw(id, amt) {
            if (mgr.debtOf(id) > mgr.creditLimitOf(id)) ghost_drawOverLimit++;
        } catch {}
    }

    function repay(uint256 seed, uint256 amt) external {
        calls++;
        (uint256 id, address who) = _pick(seed);
        amt = bound(amt, 1, 2_000e6);
        usdg.mint(who, amt);
        vm.startPrank(who);
        usdg.approve(address(mgr), amt);
        try mgr.repay(id, amt) {} catch {}
        vm.stopPrank();
    }

    function earn(uint256 seed, uint256 amt) external {
        calls++;
        (uint256 id,) = _pick(seed);
        amt = bound(amt, 1, 1_000e6);
        address sp = mgr.tabOf(id).splitter;
        uint256 before = mgr.debtOf(id);
        vm.prank(client);
        usdg.transfer(sp, amt);
        RepaymentSplitter(sp).distribute();
        if (mgr.debtOf(id) > before) ghost_revenueIncreasedDebt++;
    }

    function spend(uint256 seed, uint256 amt) external {
        calls++;
        (uint256 id,) = _pick(seed);
        PolicyAccount pa = PolicyAccount(payable(mgr.tabOf(id).policyAccount));
        uint256 bal = usdg.balanceOf(address(pa));
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        vm.prank(operator);
        try pa.pay(address(usdg), provider, amt) {} catch {}
    }

    function attack(uint256 seed, uint256 amt) external {
        calls++;
        (uint256 id,) = _pick(seed);
        PolicyAccount pa = PolicyAccount(payable(mgr.tabOf(id).policyAccount));
        amt = bound(amt, 1, 1_000e6);
        vm.startPrank(operator);
        try pa.pay(address(usdg), attacker, amt) {} catch {}
        try pa.execute(address(usdg), 0, abi.encodeCall(IERC20.transfer, (attacker, amt))) {} catch {}
        try pa.approveSpender(attacker, amt) {} catch {}
        vm.stopPrank();
    }

    function withdrawStake(uint256 seed, uint256 amt) external {
        calls++;
        (uint256 id, address who) = _pick(seed);
        uint256 bal = vault.stakeOf(id, who);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        uint256 debt = mgr.debtOf(id);
        vm.prank(who);
        try vault.withdraw(id, amt, who) {
            if (debt > 0) ghost_stakeWithdrawnWithDebt++;
        } catch {}
    }

    function warp(uint256 dt) external {
        calls++;
        dt = bound(dt, 1 hours, 20 days);
        skip(dt);
    }

    function markDelinquent(uint256 seed) external {
        calls++;
        (uint256 id,) = _pick(seed);
        try mgr.markDelinquent(id) {} catch {}
    }

    function markDefault(uint256 seed) external {
        calls++;
        (uint256 id,) = _pick(seed);
        try mgr.markDefault(id) {
            if (mgr.debtOf(id) != 0) ghost_defaultLeftDebt++;
        } catch {}
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }
}
