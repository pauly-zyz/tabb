# Tabb — Security Notes & Pre-Audit Checklist

Status: **pre-audit**. Scope: Phase 1 (agent credit), Phase 2 (yield credit) and the shared pool code (deployed as two separate pools).

---

## 1. Scope

| In scope | Path |
|---|---|
| Pool | `contracts/src/pool/TabbPool.sol`, `InterestRateModel.sol` |
| Agent credit | `contracts/src/agent/*.sol` |
| Access control / math | `contracts/src/access/TabbAccessControl.sol`, `contracts/src/libraries/TabbMath.sol` |
| Yield credit | `contracts/src/yield/*.sol` |
| Out of scope (test/local only) | `contracts/test/mocks/*`, `contracts/script/*` |

Compiler `0.8.24`, optimizer 200 runs, `evm_version = shanghai`, OpenZeppelin `v5.1.0`. No upgradeability, no proxies
except non-upgradeable EIP-1167 clones (`PolicyAccount`, `RepaymentSplitter`).

## 2. Trust assumptions

1. **Owner** (Ownable2Step, intended to be a `TimelockController` behind a multisig) can change risk parameters,
   tiers, credit-line caps/spreads, interest-rate model, reserve factor, treasury, loss absorber, payee curators, and
   unpause. Every setter is bounded (see `AgentRiskConfig._setParams`, `TabbPool.setCreditLine`, etc.). The owner
   **cannot** move user funds directly. A malicious owner can still harm users indirectly, e.g. by raising leverage
   to the 5× cap, whitelisting a malicious payee, or swapping in a hostile interest-rate model (capped at 1000% APR).
2. **Guardian** can only pause (bitmask). Repay, revenue distribution, `markDelinquent`, `markDefault`, adding stake
   and pool `repay` are never pausable.
3. **Payee curators** decide where borrowed funds can flow. A compromised or colluding curator can whitelist an
   address controlled by a borrower → borrowed funds can leave at the daily-cap rate. Losses are still bounded by
   the per-agent / per-owner / global caps minus stake.
4. **ERC-8004 Identity Registry** is trusted for `ownerOf`. If the registry is malicious or buggy, it can block
   opening/drawing (DoS) or let a non-owner open a tab (still requires their own stake). Dependency is isolated in
   `ERC8004RegistryAdapter`.
5. **USDG** is assumed to be a standard 6-decimal ERC-20 without fee-on-transfer, rebasing or blocklist side effects
   on protocol addresses. A blocklist on the pool / manager would freeze the protocol (issuer risk).
6. **Agents' revenue routing is off-chain.** The protocol cannot force clients to pay the splitter. This is mitigated
   economically (stake first-loss, minimum payments, limits grow only from splitter revenue), not enforced.

## 3. Known risks and design limitations

| # | Risk | Mitigation / status |
|---|---|---|
| R1 | Unsecured exposure: with tier leverage > 1×, debt can exceed stake. | Tier 0 = 1×. Max loss per agent ≈ `limit − stake − unspent funds`; per-owner and global caps; treasury shares are burned before lenders take losses. |
| R2 | Wash revenue (owner pays own agent through the splitter to inflate limits). | Limit ≤ `stake × leverage`; qualified cycles require ≥ 7 days and ≥ 50 USDG peak; optional distribute fee (default 0). Not fully preventable on-chain. |
| R3 | Payee collusion / exfiltration through a whitelisted payee. | Global curation, daily cap (25% of limit), spending pause, freeze on delinquency. |
| R4 | Operator key compromise. | Funds can only reach curated payees at the daily-cap rate; owner can rotate the operator; `repayFromPolicyAccount`. |
| R5 | Identity NFT transfer while in debt. | Draw and spending freeze (`OwnerChanged`, `canSpend`), old owner's stake stays locked and slashable. New owner can only take over after the tab is repaid and closed. |
| R6 | Minimum payment model is simplified: `minPaymentBps` (12%) of the debt at period start, not "interest + 10% principal". Overpayment in one period does not carry over. | Documented; parameterised. If the borrow rate per 30 days exceeded 12%, debt could grow while still "current" — prevented in practice by the IRM ceiling but worth an auditor's look. |
| R7 | Lazy period roll-forward is bounded to 12 periods per interaction. | A tab untouched for > 12 periods still behaves correctly for delinquency (first unsatisfied period stops the roll). |
| R8 | Pool withdrawals limited to idle cash; at 100% utilization lenders cannot exit. | Kinked IRM (slope2 60%) incentivises repayment; standard lending-pool risk. |
| R9 | Donations to the pool increase share price (cash = `balanceOf`). | Benefits lenders; virtual offset (1e6) + seed deposit prevent inflation attacks. Post-default recoveries intentionally use this path. |
| R10 | Rounding: debt rounds up, payments burn scaled debt rounded down, limits checked on exact post-draw debt. | Fuzzed and invariant-tested; `availableCredit` pre-adjusts for rounding. |
| R11 | `stakeLocked` only protects the borrower-of-record's stake; other stakers for the same agentId are unaffected. | By design (stakes keyed by `(agentId, staker)`). |
| R12 | Unbounded loops: `TabbPool` iterates credit lines (max 8); score iterates a 26-slot ring buffer; frontend enumerates `agentIds` client-side. | Bounded on-chain. Frontend needs an indexer at scale. |
| R13 | `markDefault` relies on external calls to clones and the vault (all protocol-controlled code). | `nonReentrant`, status set to `Defaulted` before interactions. |
| R14 | ERC-8004 standard may change. | Adapter is immutable per manager; a new manager deployment would be required. |
| R15 | Robinhood Chain specifics (sequencer downtime, `block.timestamp` granularity on L2). | Agent credit uses no price oracle; time-based deadlines tolerate small skews (days). Sequencer checks are a Phase 2 concern. |
| R16 | Regulatory: undercollateralised lending to agents/owners may require KYC. | Owner allowlist hook in `AgentRiskConfig` (off by default). Legal decision for the team. |

### Phase 2 (yield credit) specific

| # | Risk | Mitigation / status |
|---|---|---|
| Y1 | ERC-4626 share-price manipulation (donation / thin vault) inflating collateral value. | Only owner-whitelisted vaults; no on-chain growth bound yet (DESIGN I7) — **vault selection is a critical trust assumption**. |
| Y2 | Stock-linked YT gaps when the market reopens. | Market-closed mode: borrow and withdraw use `closedMarketLtvBps` (default 0 = frozen); low LTV 40%, LT 50%, bonus 10%; maturity haircut. Tested: −30% gap while closed → full liquidation works on the extended heartbeat. |
| Y3 | Stale prices during market closure used for liquidation. | Extended `heartbeatClosed` only for LIQUIDATION purpose; BORROW always uses the strict heartbeat. |
| Y4 | Sequencer downtime on Robinhood Chain. | Sequencer uptime feed + grace period blocks borrow and liquidation; feed address TODO (Q-Y10). If no feed exists, the check can be disabled and the guardian must pause manually. |
| Y5 | YT dividend attribution errors. | Accumulator with checkpoint before every balance change; dust from rounding stays in the adapter. Interface of Clipt YT is assumed (I10). |
| Y6 | In-kind liquidation of YT may lack buyers. | Bonus 10%, borrow cap 50k, owner-set supply caps. |
| Y7 | Self-repaying only if yield > interest. | UI shows HF/LTV; harvest never increases debt (invariant). Excess yield credited (pull) after payoff. |
| Y8 | 1-wei rounding dust may be credited to the owner while debt remains after a partial harvest payment. | Benign (owner's own yield); documented in fuzz test. |

## 4. Implemented protections

- `ReentrancyGuard` on every external state-changing entrypoint of pool, manager, vault, PolicyAccount, splitter.
- `SafeERC20` everywhere; stake vault rejects fee-on-transfer tokens via balance-delta check.
- Checks-effects-interactions: debt bookkeeping updated before calling the pool; pool `draw` returns scaled debt
  that the manager cross-checks (`ScaledMismatch`).
- ERC-4626 inflation protection: `_decimalsOffset() = 6` and a 1,000 USDG seed deposit to `0xdead` in deploy scripts.
- Reserve factor minted as treasury shares → invariant `totalDebt ≤ totalAssets` holds by construction.
- Clones' implementations are locked in their constructors; `initialize` is one-shot.
- PolicyAccount cannot call USDG, itself or the manager; `execute` checks (target, selector) whitelist; USDG
  outflows during `execute` are also counted against the daily cap.
- Deploy scripts refuse chain `4663` (mainnet) by design.

## 5. Test evidence

`forge test` — 200+ tests including:

- Unit tests for every contract (success paths + custom errors).
- Fuzz: draw/repay, limit enforcement, revenue-split conservation, delinquency timing, default loss accounting.
- Invariants (128 runs × 64 depth, handler with lender, owner, operator, attacker, keeper actions):
  1. `totalDebt ≤ totalAssets`
  2. no draw leaves debt above the credit limit
  3. lenders can never withdraw more than their shares are worth / more than idle cash
  4. revenue distribution never increases debt
  5. Σ tab scaled debt == manager scaled debt == pool scaled debt
  6. borrowed funds never reach a non-whitelisted address
  7. borrower-of-record stake cannot be withdrawn while in debt
  8. default always clears the tab's debt
  9. per-owner principal ≤ cap
- Scenarios: self-repaying E2E; agent stops paying; sybil owner with 10 agents defaulting; identity transferred with
  debt; operator key compromised.
- Phase 2: unit tests (oracle, risk config, both adapters, TabManager, harvester, liquidator), fuzz (borrow/repay,
  harvest, withdraw, liquidation), invariants (debt ≤ assets; HF ≥ 1 right after borrow/withdraw; lender bounded;
  harvest never increases debt; scaled-debt and custody consistency), E2E self-repaying tab and market-closed stress.
- Coverage (206 tests): `AgentCreditManager` 99.7% lines; `TabManager` 100%; `YieldHarvester` 100%; `Liquidator` 100%;
  `PolicyAccount` 98%; `RepaymentSplitter` 100%; `AgentCreditScore` 100%; `TabbPool` 93.5%; total 91.6%.

## 6. Pre-audit checklist

- [ ] Freeze scope and tag a commit for the auditors.
- [ ] Fill all TODO addresses (`config/addresses.ts`, `contracts/script/Config.s.sol`) and verify USDG `decimals() == 6`
      and its blocklist/pausing behaviour on Robinhood Chain.
- [ ] Confirm the ERC-8004 Identity Registry deployment and ABI (`ownerOf`, `getMetadata`) on Robinhood Chain.
- [ ] Decide final risk parameters (DESIGN.md §7) and tiers; document rationale.
- [ ] Deploy `TimelockController` (min delay ≥ 48h) behind a multisig; transfer ownership of pool, manager, risk
      config, vault, score and payee registry (Ownable2Step → `acceptOwnership`).
- [ ] Set guardian to a separate hot multisig with pause-only runbook.
- [ ] Define payee curation policy (KYB of providers, no DEX/bridge targets, no transfer-capable selectors).
- [ ] Run `forge test --profile ci` (2048 fuzz runs) and a longer invariant campaign (e.g. 1,000 runs × 200 depth).
- [ ] Static analysis (Slither / Aderyn) and resolve findings.
- [ ] Review rounding paths in `_applyPayment`, `writeOff` treasury burn, and `_snapshot` treasury share math.
- [ ] Review min-payment model (R6) vs. maximum borrow rate.
- [ ] Gas review of `markDefault` worst case and `useAllTabs` frontend enumeration → plan an indexer.
- [ ] Testnet soak: run keepers (`distribute`, `markDelinquent`, `markDefault`) for ≥ 2 payment periods.
- [ ] Monitoring/alerts: utilization, past-due tabs, defaults, treasury share balance, pause events.
- [ ] Incident runbook: who pauses what (`PAUSE_DRAW`, `PAUSE_OPEN`, `PAUSE_SPENDING`, pool deposit/withdraw).
- [ ] Legal review of agent/owner credit and the owner allowlist decision (Q-A17).
- [ ] Bug bounty before mainnet.
