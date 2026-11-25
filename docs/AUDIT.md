# Tabb — Internal Security Review (Phase 1, mainnet scope)

Date: 2026-11-25 · Commit: the commit that adds this file · Reviewer: Claude (AI), on the owner's instruction.

> **This is an internal, AI-performed review, not an independent third-party audit.** It lowers risk but cannot
> rule out undiscovered bugs. Launch caps are deliberately small (see §5) and an external audit plus a bug bounty are
> still recommended before raising them.

## 1. Scope

Deployed to Robinhood Chain mainnet (4663):

| Contract | Path |
|---|---|
| TabbPool, InterestRateModel | `contracts/src/pool/` |
| AgentCreditManager, AgentCreditScore, AgentRiskConfig (+Defaults), OwnerStakeVault, PolicyAccount, RepaymentSplitter, PayeeRegistry, ERC8004RegistryAdapter | `contracts/src/agent/` |
| TabbAccessControl, TabbMath | `contracts/src/access/`, `contracts/src/libraries/` |
| Deploy script | `contracts/script/DeployMainnet.s.sol`, `TabbDeployer.sol` |

**Out of mainnet scope:** Phase 2 (`contracts/src/yield/*`). It is implemented and tested, but is not deployed on
mainnet because no verified Chainlink price / sequencer feeds, USDG ERC-4626 vault or Clipt YT addresses exist yet.

External dependencies, verified on-chain on 2026-11-25:

| Dependency | Address | Checks |
|---|---|---|
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | `name` "Global Dollar", `symbol` "USDG", `decimals` 6, ~638M supply; upgradeable proxy (impl `0x6818…6f8f`), pausable (`paused() == false`) |
| ERC-8004 IdentityRegistry | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` | `name` "AgentIdentity"; `ownerOf` and `getMetadata(id,"agentWallet")` match the adapter ABI |

## 2. Method

1. Line-by-line manual review of every in-scope contract (access control, accounting, rounding, reentrancy,
   external-call ordering, state machine, default waterfall).
2. Static analysis: Slither 0.11, medium + high detectors. 53 results, all triaged (`SECURITY.md` §5.1).
3. Test suite: 206 tests (unit, fuzz, 9 stateful invariants, adversarial scenarios), 91.6% line coverage
   (AgentCreditManager 99.7%).
4. **Mainnet-fork integration** (`scripts/fork-mainnet-check.sh`). On an anvil fork of 4663 with the real USDG and
   the real ERC-8004 registry, the check ran:
   - the real deploy script
   - Ownable2Step handover to the owner
   - a lender deposit
   - a real registered agent (#1) staking, opening a tab, drawing its full available credit, and repaying in full
5. Frontend E2E against the fork: the `/admin` page was used to accept ownership on all 6 contracts, add a payee,
   and pause and unpause.

## 3. Findings

| ID | Severity | Title | Status |
|---|---|---|---|
| T-01 | Low | PolicyAccount allowances survive a freeze | Acknowledged |
| T-02 | Low | USDG issuer powers (pause / blocklist / upgrade) | Acknowledged (trust assumption) |
| T-03 | Info | Drawing exactly the credit limit can revert by 1 wei | Acknowledged (UI uses `availableCredit`) |
| T-04 | Info | Centralised owner powers | Mitigated by Ownable2Step + bounded setters; timelock recommended |
| T-05 | Info | Revenue routing is off-chain | Acknowledged (economic mitigation) |

No critical, high or medium issues were found.

**T-01: PolicyAccount allowances survive a freeze (Low).**
- **What happens:** `approveSpender` gives a curated payee a USDG allowance, counted against the daily cap when it is
  granted. If the tab later becomes Delinquent, Defaulted or frozen, an allowance the payee has not yet pulled can
  still be pulled.
- **Impact:** at most one day's cap (25% of the limit), and only by a curated payee.
- **Recommendation:** curators should approve only providers that pull immediately. A future version could track
  spenders and revoke them on `markDelinquent`.

**T-02: USDG issuer powers (Low).** USDG is an upgradeable, pausable token run by its issuer.
- A pause would block deposits, draws and repayments.
- A blocklist entry on the pool or manager would freeze funds.

This is inherent to using USDG.

**T-03: Drawing exactly the credit limit can revert by 1 wei (Info).** The line's interest index grows continuously.
Drawing exactly the credit limit can therefore round 1 wei over the limit and revert with `LimitExceeded`.
`availableCredit()` already returns the safe amount, and the UI uses it. Seen in the fork check: limit 100 USDG,
available 99.999999.

**T-04: Centralised owner powers (Info).** The owner can retune risk parameters within hard bounds, curate payees
and unpause. The owner cannot move user funds. Moving ownership to a `TimelockController` behind a multisig is
recommended once the protocol is live.

**T-05: Revenue routing is off-chain (Info).** Agents' clients must pay the splitter; the protocol cannot force this.
It is mitigated by first-loss stake, minimum payments, and limits that grow only from revenue that passes through the
splitter.

## 4. Invariants verified (fuzz + stateful)

1. `totalDebt ≤ totalAssets`.
2. No draw leaves debt above the credit limit.
3. Lenders cannot withdraw more than their shares are worth or the pool's idle cash.
4. Revenue distribution never increases debt.
5. Σ tab scaled debt == manager scaled debt == pool scaled debt.
6. Borrowed funds never reach a non-whitelisted address.
7. The borrower-of-record's stake cannot be withdrawn while in debt.
8. A default always clears the tab's debt.
9. Per-owner principal ≤ cap.

## 5. Launch limits (mainnet)

- Per agent: 1,000 USDG.
- Per owner: 3,000 USDG.
- Agent credit line cap: 50,000 USDG.
- New agents start at a 100 USDG limit, backed 1:1 by stake (tier 0).
- Seed deposit: 10 USDG to `0xdead`, on top of the 1e6 virtual-share offset.
- Guardian (defaults to the owner) can pause new tabs and draws at any time. Repayments are never pausable.
