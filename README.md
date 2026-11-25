# Tabb

> **Put it on the tab. Your yield pays it back.**

Revenue-backed credit on **Robinhood Chain** (Arbitrum Orbit L2, chain ID `4663`). Loans are repaid from future income,
not only from collateral.

- **Phase 1 — Agent credit (implemented).** ERC-8004 AI agents open small tabs backed by their owner's USDG stake.
  Borrowed funds go to a `PolicyAccount` that can only pay curated providers; the agent's revenue flows through a
  `RepaymentSplitter` that repays the tab automatically. Missed minimum payments → delinquent → default, with a
  deterministic recovery waterfall.
- **Phase 2 — Yield credit (implemented).** Self-repaying, overcollateralized loans against yield-bearing assets
  (USDG ERC-4626 vault shares, Clipt stock-dividend YT) in a separate pool. Keepers harvest yield (interest first, then
  principal); partial liquidation below HF 1; "market closed" mode for stock-linked collateral.

> ⚠️ Unaudited. Deploy scripts target **anvil and testnet only**. Mainnet deployment is done manually by the team after
> an audit.

## Repository

```
contracts/   Foundry (Solidity 0.8.24, OpenZeppelin v5)
web/         Next.js App Router + wagmi v2 + viem + Tailwind (static export)
config/      addresses.ts — per-chain addresses (TODO placeholders, nothing invented)
docs/        DESIGN.md, SECURITY.md, LAUNCH.md (public launch checklist)
scripts/     export-abis.mjs (ABIs → web/), sync-addresses.mjs (deployment JSON → config/addresses.ts), deploy-testnet.sh
```

## Contracts

```bash
cd contracts
forge build
```

```bash
forge test
```

```bash
forge coverage --ir-minimum --report summary
```

Install note: dependencies are git submodules (`git submodule update --init --recursive`). `foundry.toml` sets
`offline = true` and pins solc `0.8.24`.

| Contract | Role |
|---|---|
| `pool/TabbPool` | ERC-4626 USDG pool, per-credit-line interest index (base + spread), reserves minted as treasury shares |
| `pool/InterestRateModel` | Kinked utilization model |
| `agent/AgentCreditManager` | Phase 1 credit line: open, draw, repay, revenue processing, delinquency, default waterfall |
| `agent/AgentCreditScore` | Deterministic limits from stake, splitter revenue, age, qualified repayment cycles |
| `agent/AgentRiskConfig` | Bounded risk parameters + tiers |
| `agent/OwnerStakeVault` | First-loss stake, locked while in debt (+ cooldown), slashable |
| `agent/PolicyAccount` | Per-agent clone; curated payees / calls only, daily cap |
| `agent/RepaymentSplitter` | Per-agent clone; public payment address, auto-repays `splitBps` |
| `agent/PayeeRegistry` | Curated payee / call whitelist, global spending pause |
| `agent/ERC8004RegistryAdapter` | Adapter to the ERC-8004 Identity Registry |
| `yield/TabManager` | Phase 2 credit line: open, add/withdraw collateral, borrow, repay, harvest, liquidate |
| `yield/YieldRiskConfig` | Per-collateral LTV / LT / bonus / caps / market-closed LTV + global liquidation params |
| `yield/OracleRouter` | Chainlink reads: staleness (open/closed heartbeat), answer > 0, sequencer uptime + grace, market status |
| `yield/ERC4626ShareAdapter` | USDG vault shares; yield = growth above per-tab high-water mark |
| `yield/YieldTokenAdapter` | Clipt dividend YT; per-tab dividend accumulator; maturity haircut |
| `yield/YieldHarvester`, `yield/Liquidator` | Permissionless keeper entrypoints |

## Local end-to-end (anvil)

```bash
anvil
```

```bash
cd contracts && forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

The local deploy uses anvil's public test keys, mock USDG, a mock ERC-8004 registry, a mock USDG vault, a mock dividend
YT and a mock price feed; it seeds both pools and opens a demo agent tab for agent `#1` (owned by anvil account #2).
The Yield page has demo controls (vault yield, YT dividend, YT price, market open/close — the latter needs account #0). Addresses are deterministic on a fresh anvil and already present in
`config/addresses.ts`.

```bash
cd web && npm ci && NEXT_PUBLIC_CHAIN_ID=31337 npm run dev
```

Import an anvil test key into your wallet (e.g. account #2) and add the network `http://127.0.0.1:8545`, chain `31337`.

## Testnet deploy

```bash
cp .env.example .env   # fill ROBINHOOD_TESTNET_RPC_URL, DEPLOYER_PRIVATE_KEY (testnet only)
```

```bash
cd contracts && source ../.env && forge script script/DeployTestnet.s.sol --rpc-url $ROBINHOOD_TESTNET_RPC_URL --broadcast
```

Until USDG / ERC-8004 addresses are known for testnet, add `DEPLOY_MOCKS=true`. Add `DEPLOY_YIELD=true` to also deploy
Phase 2 (with mocks when `DEPLOY_MOCKS=true`). The script refuses chain `4663`.
Output goes to `contracts/deployments/<chainId>.json`; copy it into `config/addresses.ts`.

## Frontend / Vercel

The web app is a static export (`web/out`). Vercel: either set **Root Directory = `web`** (framework auto-detected), or
keep the repo root — `vercel.json` builds `web/` and serves `web/out`.

Environment variables (all public): `NEXT_PUBLIC_CHAIN_ID` (default `4663`), `NEXT_PUBLIC_ROBINHOOD_RPC_URL`,
`NEXT_PUBLIC_RPC_URL`, `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID`. While contracts are not deployed on the selected chain,
the UI shows a "not deployed yet" notice and disables actions.

After changing contracts: `forge build && node scripts/export-abis.mjs`.

## Addresses to fill in (TODO)

See `config/addresses.ts`, `contracts/script/Config.s.sol` and [`docs/DESIGN.md` §15](docs/DESIGN.md).
