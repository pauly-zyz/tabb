// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AgentFixture} from "../utils/AgentFixture.sol";
import {AgentHandler} from "./AgentHandler.sol";

contract AgentInvariantTest is AgentFixture {
    AgentHandler handler;

    function setUp() public override {
        super.setUp();
        _setBaseLimit(1_000 * ONE);
        uint256[] memory ids = new uint256[](4);
        address[] memory owners = new address[](4);
        address carol = makeAddr("carol");
        _fund(carol, 100_000 * ONE);
        ids[0] = _newAgent(alice, 1_000 * ONE);
        owners[0] = alice;
        ids[1] = _newAgent(alice, 300 * ONE);
        owners[1] = alice;
        ids[2] = _newAgent(bob, 500 * ONE);
        owners[2] = bob;
        ids[3] = _newAgent(carol, 100 * ONE);
        owners[3] = carol;
        handler = new AgentHandler(usdg, pool, mgr, vault, lender, operator, provider, ids, owners);
        targetContract(address(handler));
    }

    /// 1. total debt <= total pool assets
    function invariant_debtLeTotalAssets() public view {
        assertLe(pool.totalDebt(), pool.totalAssets());
    }

    /// 2. no position exceeds its credit limit right after a draw
    function invariant_noDrawOverLimit() public view {
        assertEq(handler.ghost_drawOverLimit(), 0);
    }

    /// 3. lenders can never withdraw more than their shares are worth, nor more than idle cash
    function invariant_lenderWithdrawBounded() public view {
        assertEq(handler.ghost_lenderOverWithdraw(), 0);
        assertLe(pool.maxWithdraw(lender), pool.convertToAssets(pool.balanceOf(lender)));
        assertLe(pool.maxWithdraw(lender), pool.availableLiquidity());
        assertLe(pool.previewRedeem(pool.totalSupply()), pool.totalAssets());
    }

    /// 4. revenue distribution (the agent's "harvest") never increases debt
    function invariant_revenueNeverIncreasesDebt() public view {
        assertEq(handler.ghost_revenueIncreasedDebt(), 0);
    }

    /// 5. scaled debt bookkeeping matches the pool
    function invariant_scaledDebtConsistency() public view {
        uint256 sum;
        for (uint256 i; i < handler.idCount(); ++i) {
            sum += mgr.tabOf(handler.ids(i)).scaledDebt;
        }
        assertEq(sum, mgr.totalScaledDebt());
        assertEq(sum, pool.scaledDebtOf(address(mgr)));
    }

    /// 6. borrowed funds never reach a non-whitelisted address
    function invariant_policyFundsNeverLeak() public view {
        assertEq(usdg.balanceOf(handler.attacker()), 0);
    }

    /// 7. stake of the borrower of record cannot be withdrawn while there is debt
    function invariant_stakeLockedWithDebt() public view {
        assertEq(handler.ghost_stakeWithdrawnWithDebt(), 0);
    }

    /// 8. default always clears the tab's debt
    function invariant_defaultClearsDebt() public view {
        assertEq(handler.ghost_defaultLeftDebt(), 0);
    }

    /// owner principal never exceeds the per-owner cap
    function invariant_ownerCap() public view {
        assertLe(mgr.ownerPrincipal(alice), cfg.params().maxPerOwner);
        assertLe(mgr.ownerPrincipal(bob), cfg.params().maxPerOwner);
    }
}
