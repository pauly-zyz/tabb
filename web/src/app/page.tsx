"use client";

import Link from "next/link";
import { NetworkBanner } from "@/components/NetworkBanner";
import { Card, Stat } from "@/components/ui";
import { usePoolStats } from "@/lib/hooks";
import { fmtUsdg, fmtWadPct } from "@/lib/format";
import { deployed } from "@/lib/tabb";

const STEPS = [
  {
    t: "Stake & open a tab",
    d: "The owner of an ERC-8004 agent posts a USDG stake as first-loss capital and opens a small tab. Limits start at the stake and grow with proven revenue and on-time repayments.",
  },
  {
    t: "Spend with guardrails",
    d: "Borrowed USDG lands in the agent's PolicyAccount. It can only pay curated providers (compute, APIs, data), under a daily cap.",
  },
  {
    t: "Revenue pays it back",
    d: "Clients pay the agent through its RepaymentSplitter. A share of every payment repays the tab automatically; the rest goes to the agent.",
  },
];

export default function Home() {
  const s = usePoolStats();
  return (
    <div className="space-y-8">
      <NetworkBanner />
      <section className="pt-4 sm:pt-10">
        <p className="text-sm font-medium text-tab-400">Revenue-backed credit on Robinhood Chain</p>
        <h1 className="mt-2 max-w-2xl text-4xl font-bold leading-tight tracking-tight sm:text-5xl">
          Put it on the tab.
          <br />
          <span className="text-tab-400">Your yield pays it back.</span>
        </h1>
        <p className="mt-4 max-w-xl text-zinc-400">
          Tabb lends USDG against future income, not just collateral. Phase 1 opens small, stake-backed tabs for AI agents
          that repay themselves from what they earn.
        </p>
        <div className="mt-6 flex flex-wrap gap-3">
          <Link
            href="/agents/"
            className="rounded-xl bg-tab-400 px-5 py-3 text-sm font-semibold text-ink-950 hover:bg-tab-500"
          >
            Open an agent tab
          </Link>
          <Link
            href="/lend/"
            className="rounded-xl border border-ink-600 bg-ink-800 px-5 py-3 text-sm font-semibold hover:bg-ink-700"
          >
            Lend USDG
          </Link>
        </div>
      </section>

      {deployed && (
        <section className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <Stat label="Pool TVL" value={`$${fmtUsdg(s.totalAssets, 0)}`} />
          <Stat label="Lender APY" value={fmtWadPct(s.supplyRate)} />
          <Stat label="Utilization" value={fmtWadPct(s.utilization, 1)} />
          <Stat label="Agent tabs" value={s.agentCount?.toString() ?? "—"} />
        </section>
      )}

      <section className="grid gap-3 sm:grid-cols-3">
        {STEPS.map((x, i) => (
          <Card key={x.t}>
            <div className="text-xs font-semibold text-tab-400">0{i + 1}</div>
            <h3 className="mt-1 font-semibold">{x.t}</h3>
            <p className="mt-1 text-sm leading-relaxed text-zinc-400">{x.d}</p>
          </Card>
        ))}
      </section>

      <section className="grid gap-3 sm:grid-cols-2">
        <Card>
          <div className="flex items-center justify-between gap-2">
            <h3 className="font-semibold">Phase 1 — Agent credit</h3>
            <span className="rounded-full bg-tab-400/15 px-2.5 py-0.5 text-xs font-semibold text-tab-400">
              Pre-audit
            </span>
          </div>
          <p className="mt-2 text-sm text-zinc-400">
            Stake-backed tabs for ERC-8004 agents with curated spending, automatic revenue splits and a transparent
            default waterfall: unspent funds → splitter → owner stake → protocol reserves → lenders.
          </p>
        </Card>
        <Card>
          <div className="flex items-center justify-between gap-2">
            <h3 className="font-semibold">Phase 2 — Yield credit</h3>
            <span className="rounded-full bg-zinc-500/15 px-2.5 py-0.5 text-xs font-semibold text-zinc-300">Next</span>
          </div>
          <p className="mt-2 text-sm text-zinc-400">
            Self-repaying, overcollateralized loans against yield-bearing assets (USDG vault shares, stock-dividend YT).
            Harvested yield pays interest first, then principal.
          </p>
        </Card>
      </section>
    </div>
  );
}
