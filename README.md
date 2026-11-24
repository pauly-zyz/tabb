# Tabb

> **Put it on the tab. Your yield pays it back.**

Revenue-backed credit on **Robinhood Chain** (Arbitrum Orbit L2, chain ID `4663`). Loans are repaid from future income,
not only from collateral.

- **Phase 1 — Agent credit (implemented).** ERC-8004 AI agents open small tabs backed by their owner's USDG stake.
  Borrowed funds go to a `PolicyAccount` that can only pay curated providers; the agent's revenue flows through a
  `RepaymentSplitter` that repays the tab automatically. Missed minimum payments → delinquent → default, with a
  deterministic recovery waterfall.
- **Phase 2 — Yield credit (designed, interfaces + stub).** Self-repaying, overcollateralized loans against
  yield-bearing assets. See [`docs/DESIGN.md` §9](docs/DESIGN.md).

> ⚠️ Unaudited. Deploy scripts target **anvil and testnet only**. Mainnet deployment is done manually by the team after
> an audit.

## Repository

```
contracts/   Foundry (Solidity 0.8.24, OpenZeppelin v5)
web/         Next.js App Router + wagmi v2 + viem + Tailwind (static export)
config/      addresses.ts — per-chain addresses (TODO placeholders, nothing invented)
docs/        DESIGN.md, SECURITY.md
scripts/     export-abis.mjs — copy ABIs from Foundry artifacts into web/
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
| `yield/TabManager` | Phase 2 stub (second credit line) |

## Local end-to-end (anvil)

```bash
anvil
```

```bash
cd contracts && forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

The local deploy uses anvil's public test keys, mock USDG and a mock ERC-8004 registry, seeds the pool, and opens a demo
tab for agent `#1` (owned by anvil account #2). Addresses are deterministic on a fresh anvil and already present in
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

Until USDG / ERC-8004 addresses are known for testnet, add `DEPLOY_MOCKS=true`. The script refuses chain `4663`.
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
