"use client";

import { agentCreditManagerAbi } from "@/abi";
import { NetworkBanner } from "@/components/NetworkBanner";
import { Badge, Button, Card, Notice, SectionTitle, Stat, TxStatus } from "@/components/ui";
import { useAllTabs, type TabRow } from "@/lib/hooks";
import { daysFromNow, fmtDate, fmtUsdg, shortAddr } from "@/lib/format";
import { A, deployed, STATUS } from "@/lib/tabb";
import { useTx } from "@/lib/useTx";

function stage(r: TabRow, now: number) {
  const s = STATUS[r.tab.status];
  if (s === "Delinquent") {
    return Number(r.payment?.defaultEligibleAt ?? 0n) <= now ? "Default-eligible" : "Delinquent";
  }
  if (s !== "Active" || r.debt === 0n || !r.payment) return "Healthy";
  if (r.payment.pastDue) return Number(r.payment.delinquentEligibleAt) <= now ? "Delinquent-eligible" : "Past due (grace)";
  if (Number(r.payment.periodEnd) - now < 7 * 86400) return "Due soon";
  return "Healthy";
}

const ORDER = ["Default-eligible", "Delinquent-eligible", "Delinquent", "Past due (grace)", "Due soon", "Healthy"];

export default function RiskPage() {
  const { rows, isLoading } = useAllTabs();
  const now = Math.floor(Date.now() / 1000);
  const open = rows.filter((r) => r.debt > 0n || STATUS[r.tab.status] === "Delinquent");
  const sorted = [...open].sort((a, b) => ORDER.indexOf(stage(a, now)) - ORDER.indexOf(stage(b, now)));
  const totalDebt = open.reduce((s, r) => s + r.debt, 0n);
  const atRisk = open.filter((r) => !["Healthy", "Due soon"].includes(stage(r, now)));
  const defaulted = rows.filter((r) => STATUS[r.tab.status] === "Defaulted");

  return (
    <div className="space-y-5">
      <SectionTitle
        title="Risk monitor"
        subtitle="Tabs approaching their payment deadline, delinquent or ready to default. Keeper actions are permissionless."
      />
      <NetworkBanner />
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="Open tabs" value={open.length} />
        <Stat label="Outstanding debt" value={fmtUsdg(totalDebt, 0)} />
        <Stat label="At risk" value={atRisk.length} />
        <Stat label="Defaulted" value={defaulted.length} />
      </div>
      <Notice>
        Agent tabs are not liquidated by price. Instead: a missed minimum payment + 7-day grace → <b>markDelinquent</b>{" "}
        (spending freezes, 100% of revenue repays). After 30 days delinquent → <b>markDefault</b> runs the recovery waterfall.
      </Notice>
      {deployed && !isLoading && sorted.length === 0 && <Card>No open tabs.</Card>}
      {sorted.map((r) => (
        <RiskRow key={r.agentId.toString()} r={r} st={stage(r, now)} />
      ))}
    </div>
  );
}

function RiskRow({ r, st }: { r: TabRow; st: string }) {
  const tx = useTx();
  const status = STATUS[r.tab.status];
  return (
    <Card>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <span className="font-semibold">Agent #{r.agentId.toString()}</span>
          <Badge label={status} />
          <span className="text-xs text-zinc-400">{st}</span>
        </div>
        <span className="font-mono text-xs text-zinc-500">owner {shortAddr(r.tab.owner)}</span>
      </div>
      <div className="mt-3 grid grid-cols-2 gap-2 text-sm sm:grid-cols-4">
        <div>
          <div className="text-xs text-zinc-500">Debt</div>
          <div className="tabular-nums">{fmtUsdg(r.debt)}</div>
        </div>
        <div>
          <div className="text-xs text-zinc-500">Min due / paid</div>
          <div className="tabular-nums">
            {fmtUsdg(r.payment?.minPaymentDue)} / {fmtUsdg(r.payment?.paidThisPeriod)}
          </div>
        </div>
        <div>
          <div className="text-xs text-zinc-500">Period end</div>
          <div>{r.payment?.periodEnd ? `${fmtDate(r.payment.periodEnd)} (${daysFromNow(r.payment.periodEnd)})` : "—"}</div>
        </div>
        <div>
          <div className="text-xs text-zinc-500">{status === "Delinquent" ? "Default from" : "Delinquent from"}</div>
          <div>
            {status === "Delinquent" ? fmtDate(r.payment?.defaultEligibleAt) : r.payment?.pastDue ? fmtDate(r.payment.delinquentEligibleAt) : "—"}
          </div>
        </div>
      </div>
      <div className="mt-3 flex flex-wrap gap-2">
        <Button
          variant="ghost"
          disabled={tx.busy || st !== "Delinquent-eligible"}
          onClick={() => tx.send({ address: A.agentCreditManager, abi: agentCreditManagerAbi, functionName: "markDelinquent", args: [r.agentId] })}
        >
          Mark delinquent
        </Button>
        <Button
          variant="danger"
          disabled={tx.busy || st !== "Default-eligible"}
          onClick={() => tx.send({ address: A.agentCreditManager, abi: agentCreditManagerAbi, functionName: "markDefault", args: [r.agentId] })}
        >
          Trigger default
        </Button>
      </div>
      <TxStatus status={tx.status} error={tx.error} />
    </Card>
  );
}
