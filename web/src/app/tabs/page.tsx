"use client";

import { useState } from "react";
import Link from "next/link";
import { useAccount, useReadContracts } from "wagmi";
import { maxUint256 } from "viem";
import {
  agentCreditManagerAbi,
  agentCreditScoreAbi,
  mockUsdgAbi,
  ownerStakeVaultAbi,
  repaymentSplitterAbi,
} from "@/abi";
import { NetworkBanner } from "@/components/NetworkBanner";
import { Badge, Button, Card, Input, Meter, Notice, Row, SectionTitle, Stat, TxStatus } from "@/components/ui";
import { useMyTabs, useUsdgBalance, type TabRow } from "@/lib/hooks";
import { daysFromNow, fmtBps, fmtDate, fmtUsdg, parseUsdg, shortAddr } from "@/lib/format";
import { A, deployed, STATUS, STABLE } from "@/lib/tabb";
import { useTx } from "@/lib/useTx";

export default function MyTabsPage() {
  const { address } = useAccount();
  const { rows, isLoading } = useMyTabs();
  return (
    <div className="space-y-5">
      <SectionTitle title="My Tabs" subtitle="Debt, limits, revenue that already paid you down, and payment schedule." />
      <NetworkBanner />
      {!address && <Notice>Connect your wallet to see your tabs.</Notice>}
      {address && deployed && !isLoading && rows.length === 0 && (
        <Card>
          <p className="text-sm text-zinc-400">
            No tabs yet.{" "}
            <Link href="/agents/" className="text-tab-400 underline">
              Open one for your agent
            </Link>
            .
          </p>
        </Card>
      )}
      {rows.map((r) => (
        <TabCard key={r.agentId.toString()} row={r} />
      ))}
    </div>
  );
}

function TabCard({ row }: { row: TabRow }) {
  const { address } = useAccount();
  const { agentId, tab, debt, limit, available, payment } = row;
  const status = STATUS[tab.status];
  const { data } = useReadContracts({
    contracts: [
      { address: A.usdg, abi: mockUsdgAbi, functionName: "balanceOf", args: [tab.policyAccount] },
      { address: A.usdg, abi: mockUsdgAbi, functionName: "balanceOf", args: [tab.splitter] },
      { address: A.creditScore, abi: agentCreditScoreAbi, functionName: "revenueInWindow", args: [agentId] },
      { address: A.creditScore, abi: agentCreditScoreAbi, functionName: "score", args: [agentId, tab.owner] },
      { address: A.creditScore, abi: agentCreditScoreAbi, functionName: "tierOf", args: [agentId] },
      { address: A.stakeVault, abi: ownerStakeVaultAbi, functionName: "stakeOf", args: [agentId, tab.owner] },
      { address: A.agentCreditManager, abi: agentCreditManagerAbi, functionName: "stakeLocked", args: [agentId, tab.owner] },
    ],
  });
  const paBal = data?.[0]?.result as bigint | undefined;
  const splitterBal = data?.[1]?.result as bigint | undefined;
  const revenue90 = data?.[2]?.result as bigint | undefined;
  const score = data?.[3]?.result as bigint | undefined;
  const tier = data?.[4]?.result as bigint | undefined;
  const stake = data?.[5]?.result as bigint | undefined;
  const stakeLocked = data?.[6]?.result as boolean | undefined;

  const interest = debt > tab.principal ? debt - tab.principal : 0n;
  // payoff estimate from the last 90 days of splitter revenue at the current split (ignores new interest)
  const dailyRepay = revenue90 ? (revenue90 * BigInt(status === "Delinquent" ? 10_000 : tab.splitBps)) / 10_000n / 90n : 0n;
  const payoffDays = dailyRepay > 0n && debt > 0n ? Number((debt + dailyRepay - 1n) / dailyRepay) : undefined;

  const { allowance } = useUsdgBalance(address, A.agentCreditManager);
  const repayTx = useTx();
  const [repayStr, setRepayStr] = useState("");
  const repayAmt = parseUsdg(repayStr);
  async function repay() {
    if (!repayAmt) return;
    if ((allowance ?? 0n) < repayAmt) {
      const ok = await repayTx.send(
        { address: A.usdg, abi: mockUsdgAbi, functionName: "approve", args: [A.agentCreditManager, maxUint256] },
        "Approve",
      );
      if (!ok) return;
    }
    if (await repayTx.send({ address: A.agentCreditManager, abi: agentCreditManagerAbi, functionName: "repay", args: [agentId, repayAmt] }))
      setRepayStr("");
  }

  const actTx = useTx();
  const [splitStr, setSplitStr] = useState("");
  const [payStr, setPayStr] = useState("");
  const payAmt = parseUsdg(payStr);
  const [copied, setCopied] = useState(false);

  return (
    <Card>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <h2 className="text-lg font-semibold">Agent #{agentId.toString()}</h2>
          <Badge label={status} />
        </div>
        <div className="text-xs text-zinc-500">
          Tier T{tier?.toString() ?? "—"} · Score {score?.toString() ?? "—"}/1000
        </div>
      </div>

      <div className="mt-4 grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="Debt" value={fmtUsdg(debt)} hint={`interest ${fmtUsdg(interest)}`} />
        <Stat label="Limit" value={fmtUsdg(limit)} hint={`available ${fmtUsdg(available)}`} />
        <Stat label="Paid by revenue" value={fmtUsdg(tab.revenueRepaid)} hint={`total repaid ${fmtUsdg(tab.totalRepaid)}`} />
        <Stat
          label="Est. paid off"
          value={debt === 0n ? "Paid ✓" : payoffDays !== undefined ? `~${payoffDays}d` : "—"}
          hint={payoffDays !== undefined && debt > 0n ? fmtDate(Math.floor(Date.now() / 1000) + payoffDays * 86400) : "from 90d revenue"}
        />
      </div>

      <div className="mt-4">
        <Meter value={Number(debt)} max={Number(limit) || 1} />
      </div>

      <div className="mt-4 grid gap-4 md:grid-cols-2">
        <div>
          <h3 className="mb-1 text-sm font-semibold text-zinc-300">Payment schedule</h3>
          {payment && payment.periodEnd > 0n ? (
            <>
              <Row k="Minimum due this period" v={`${fmtUsdg(payment.minPaymentDue)} ${STABLE}`} />
              <Row k="Paid this period" v={`${fmtUsdg(payment.paidThisPeriod)} ${STABLE}`} />
              <Row k="Period ends" v={`${fmtDate(payment.periodEnd)} (${daysFromNow(payment.periodEnd)})`} />
              {payment.pastDue && (
                <Notice tone="danger">
                  Past due. Delinquency possible from {fmtDate(payment.delinquentEligibleAt)}.
                </Notice>
              )}
              {status === "Delinquent" && (
                <Notice tone="danger">Delinquent: default possible from {fmtDate(payment.defaultEligibleAt)}. Pay the minimum to cure.</Notice>
              )}
            </>
          ) : (
            <p className="text-sm text-zinc-500">No open period (no debt).</p>
          )}
          <h3 className="mb-1 mt-4 text-sm font-semibold text-zinc-300">Accounts</h3>
          <Row
            k="Splitter (share with clients)"
            v={
              <button
                type="button"
                className="font-mono text-tab-400"
                onClick={() => {
                  navigator.clipboard?.writeText(tab.splitter);
                  setCopied(true);
                  setTimeout(() => setCopied(false), 1500);
                }}
              >
                {copied ? "Copied ✓" : shortAddr(tab.splitter)}
              </button>
            }
          />
          <Row k="Undistributed revenue" v={`${fmtUsdg(splitterBal)} ${STABLE}`} />
          <Row k="PolicyAccount balance" v={`${fmtUsdg(paBal)} ${STABLE}`} />
          <Row k="Revenue (90d)" v={`${fmtUsdg(revenue90)} ${STABLE}`} />
          <Row k="Auto-repay split" v={fmtBps(status === "Delinquent" ? 10_000 : tab.splitBps)} />
          <Row k="Stake" v={`${fmtUsdg(stake)} ${STABLE} ${stakeLocked ? "🔒" : ""}`} />
          {tab.lossWrittenOff > 0n && <Row k="Written off / recovered" v={`${fmtUsdg(tab.lossWrittenOff)} / ${fmtUsdg(tab.recovered)}`} />}
        </div>

        <div className="space-y-3">
          {(status === "Active" || status === "Delinquent") && (
            <div>
              <Input label="Repay" placeholder="0.00" inputMode="decimal" value={repayStr} onChange={(e) => setRepayStr(e.target.value)} suffix={STABLE} />
              <Button className="mt-2 w-full" disabled={!repayAmt || repayTx.busy} onClick={repay}>
                Repay
              </Button>
              <TxStatus status={repayTx.status} error={repayTx.error} />
            </div>
          )}
          <div className="grid grid-cols-2 gap-2">
            <Button
              variant="ghost"
              disabled={actTx.busy || !splitterBal}
              onClick={() => actTx.send({ address: tab.splitter, abi: repaymentSplitterAbi, functionName: "distribute" })}
            >
              Distribute revenue
            </Button>
            <Button
              variant="ghost"
              disabled={actTx.busy || !paBal || debt === 0n || !(status === "Active" || status === "Delinquent")}
              onClick={() =>
                actTx.send({
                  address: A.agentCreditManager,
                  abi: agentCreditManagerAbi,
                  functionName: "repayFromPolicyAccount",
                  args: [agentId, maxUint256],
                })
              }
            >
              Repay from PolicyAccount
            </Button>
            <Button
              variant="ghost"
              disabled={actTx.busy || status !== "Active" || debt > 0n}
              onClick={() => actTx.send({ address: A.agentCreditManager, abi: agentCreditManagerAbi, functionName: "closeTab", args: [agentId] })}
            >
              Close tab
            </Button>
            <Button
              variant="ghost"
              disabled={actTx.busy || !stake || stakeLocked}
              onClick={() =>
                actTx.send({ address: A.stakeVault, abi: ownerStakeVaultAbi, functionName: "withdraw", args: [agentId, stake!, address!] })
              }
            >
              Withdraw stake
            </Button>
          </div>
          <div className="flex items-end gap-2">
            <div className="flex-1">
              <Input label="Auto-repay split (%)" placeholder={(tab.splitBps / 100).toString()} inputMode="decimal" value={splitStr} onChange={(e) => setSplitStr(e.target.value)} suffix="%" />
            </div>
            <Button
              variant="ghost"
              disabled={actTx.busy || !splitStr}
              onClick={() =>
                actTx.send({
                  address: A.agentCreditManager,
                  abi: agentCreditManagerAbi,
                  functionName: "setSplitBps",
                  args: [agentId, Math.round(Number(splitStr) * 100)],
                })
              }
            >
              Set
            </Button>
          </div>
          <div className="flex items-end gap-2">
            <div className="flex-1">
              <Input label="Pay this agent (as a client)" placeholder="0.00" inputMode="decimal" value={payStr} onChange={(e) => setPayStr(e.target.value)} suffix={STABLE} />
            </div>
            <Button
              variant="ghost"
              disabled={actTx.busy || !payAmt}
              onClick={async () => {
                if (await actTx.send({ address: A.usdg, abi: mockUsdgAbi, functionName: "transfer", args: [tab.splitter, payAmt!] }))
                  setPayStr("");
              }}
            >
              Pay
            </Button>
          </div>
          <TxStatus status={actTx.status} error={actTx.error} />
        </div>
      </div>
    </Card>
  );
}
