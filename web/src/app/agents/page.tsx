"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { isAddress, maxUint256 } from "viem";
import {
  agentCreditManagerAbi,
  agentCreditScoreAbi,
  agentRiskConfigAbi,
  mockIdentityRegistryAbi,
  mockUsdgAbi,
  ownerStakeVaultAbi,
  tabbPoolAbi,
} from "@/abi";
import { NetworkBanner } from "@/components/NetworkBanner";
import { Faucet } from "@/components/Faucet";
import { RiskAck } from "@/components/RiskAck";
import { Badge, Button, Card, Input, Meter, Notice, Row, SectionTitle, Stat, TxStatus } from "@/components/ui";
import { useUsdgBalance } from "@/lib/hooks";
import { fmtBps, fmtUsdg, fmtWadPct, parseUsdg } from "@/lib/format";
import { A, addrs, deployed, STATUS, type AgentTab } from "@/lib/tabb";
import { useTx } from "@/lib/useTx";

interface Breakdown {
  stake: bigint;
  tier: bigint;
  leverageBps: bigint;
  revenue: bigint;
  revenueLimit: bigint;
  capacity: bigint;
  stakeLimit: bigint;
  limit: bigint;
  score: bigint;
}

interface Params {
  minStake: bigint;
  baseLimit: bigint;
  maxPerAgent: bigint;
  maxPerOwner: bigint;
  minDebt: bigint;
  minPaymentBps: number;
  defaultSplitBps: number;
  dailySpendCapBps: number;
  paymentPeriod: number;
}

export default function AgentsPage() {
  const { address } = useAccount();
  const [idStr, setIdStr] = useState("");
  const agentId = /^\d+$/.test(idStr) ? BigInt(idStr) : undefined;
  const ready = deployed && !!address && agentId !== undefined;

  const { data: params } = useReadContract({
    address: A.riskConfig,
    abi: agentRiskConfigAbi,
    functionName: "params",
    query: { enabled: deployed },
  }) as { data: Params | undefined };

  const { data } = useReadContracts({
    contracts: [
      { address: A.identityRegistry, abi: mockIdentityRegistryAbi, functionName: "ownerOf", args: [agentId ?? 0n] },
      { address: A.stakeVault, abi: ownerStakeVaultAbi, functionName: "stakeOf", args: [agentId ?? 0n, address!] },
      { address: A.creditScore, abi: agentCreditScoreAbi, functionName: "breakdown", args: [agentId ?? 0n, address!] },
      { address: A.agentCreditManager, abi: agentCreditManagerAbi, functionName: "tabOf", args: [agentId ?? 0n] },
      { address: A.agentCreditManager, abi: agentCreditManagerAbi, functionName: "debtOf", args: [agentId ?? 0n] },
      { address: A.agentCreditManager, abi: agentCreditManagerAbi, functionName: "availableCredit", args: [agentId ?? 0n] },
      { address: A.pool, abi: tabbPoolAbi, functionName: "borrowRateOf", args: [A.agentCreditManager] },
    ],
    query: { enabled: ready },
  });
  const agentOwner = data?.[0]?.result as `0x${string}` | undefined;
  const stake = data?.[1]?.result as bigint | undefined;
  const bd = data?.[2]?.result as Breakdown | undefined;
  const tab = data?.[3]?.result as AgentTab | undefined;
  const debt = (data?.[4]?.result as bigint | undefined) ?? 0n;
  const available = (data?.[5]?.result as bigint | undefined) ?? 0n;
  const borrowRate = data?.[6]?.result as bigint | undefined;

  const isOwner = !!agentOwner && !!address && agentOwner.toLowerCase() === address.toLowerCase();
  const status = tab ? STATUS[tab.status] : "None";
  const tabOpen = status === "Active" || status === "Delinquent";
  const canOpen = isOwner && (status === "None" || status === "Closed") && (stake ?? 0n) >= (params?.minStake ?? 1n);

  const { balance, allowance } = useUsdgBalance(address, A.stakeVault);

  // ---- register demo agent (mock registry only)
  const regTx = useTx();
  const { data: nextId } = useReadContract({
    address: A.identityRegistry,
    abi: mockIdentityRegistryAbi,
    functionName: "nextId",
    query: { enabled: deployed && !!addrs?.mocks },
  });
  async function registerDemo() {
    const id = nextId as bigint | undefined;
    const ok = await regTx.send({
      address: A.identityRegistry,
      abi: mockIdentityRegistryAbi,
      functionName: "register",
      args: ["ipfs://tabb-demo-agent"],
    });
    if (ok && id !== undefined) setIdStr(id.toString());
  }

  // ---- stake
  const [stakeStr, setStakeStr] = useState("");
  const stakeAmt = parseUsdg(stakeStr);
  const stakeTx = useTx();
  async function doStake() {
    if (!stakeAmt || agentId === undefined) return;
    if ((allowance ?? 0n) < stakeAmt) {
      const ok = await stakeTx.send(
        { address: A.usdg, abi: mockUsdgAbi, functionName: "approve", args: [A.stakeVault, maxUint256] },
        "Approve",
      );
      if (!ok) return;
    }
    if (await stakeTx.send({ address: A.stakeVault, abi: ownerStakeVaultAbi, functionName: "stake", args: [agentId, stakeAmt] }))
      setStakeStr("");
  }

  // ---- open
  const [operator, setOperator] = useState("");
  const [payout, setPayout] = useState("");
  const openTx = useTx();
  const opValid = operator === "" || isAddress(operator);
  const payValid = payout === "" || isAddress(payout);
  async function doOpen() {
    if (agentId === undefined || !address) return;
    await openTx.send({
      address: A.agentCreditManager,
      abi: agentCreditManagerAbi,
      functionName: "openTab",
      args: [agentId, (operator || address) as `0x${string}`, (payout || address) as `0x${string}`],
    });
  }

  // ---- draw
  const [drawStr, setDrawStr] = useState("");
  const [ack, setAck] = useState(false);
  const drawAmt = parseUsdg(drawStr);
  const drawTx = useTx();
  const limit = bd?.limit ?? 0n;
  const newDebt = debt + (drawAmt ?? 0n);
  const preview = useMemo(() => {
    if (!params) return undefined;
    const base = debt === 0n ? newDebt : undefined;
    return {
      minPayment: base !== undefined ? (base * BigInt(params.minPaymentBps)) / 10_000n : undefined,
      dailyCap: (limit * BigInt(params.dailySpendCapBps)) / 10_000n,
      overLimit: newDebt > limit,
      belowMin: drawAmt !== undefined && newDebt < params.minDebt,
    };
  }, [params, debt, newDebt, limit, drawAmt]);

  async function doDraw() {
    if (!drawAmt || agentId === undefined) return;
    if (await drawTx.send({ address: A.agentCreditManager, abi: agentCreditManagerAbi, functionName: "draw", args: [agentId, drawAmt] })) {
      setDrawStr("");
      setAck(false);
    }
  }

  return (
    <div className="space-y-5">
      <SectionTitle
        title="Open a Tab"
        subtitle="For ERC-8004 agents. Stake, preview your limit, then draw into the agent's PolicyAccount."
      />
      <NetworkBanner />

      <Card>
        <h2 className="mb-3 font-semibold">1 · Choose your agent</h2>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-end">
          <div className="flex-1">
            <Input
              label="ERC-8004 agent ID"
              placeholder="e.g. 1"
              inputMode="numeric"
              value={idStr}
              onChange={(e) => setIdStr(e.target.value.trim())}
            />
          </div>
          {addrs?.mocks && (
            <Button variant="ghost" disabled={!address || regTx.busy} onClick={registerDemo}>
              Register a demo agent
            </Button>
          )}
        </div>
        <TxStatus status={regTx.status} error={regTx.error} />
        {ready && (
          <div className="mt-3 space-y-1">
            <Row k="Registry owner" v={agentOwner ? (isOwner ? "You" : agentOwner) : "Not found"} />
            <Row k="Tab status" v={<Badge label={status} />} />
          </div>
        )}
        {ready && agentOwner && !isOwner && (
          <div className="mt-3">
            <Notice tone="danger">You are not the owner of this agent identity, so you cannot open or draw on its tab.</Notice>
          </div>
        )}
      </Card>

      {ready && isOwner && (
        <>
          <Card>
            <h2 className="mb-3 font-semibold">2 · Stake (first-loss capital)</h2>
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <Stat label="Your stake" value={fmtUsdg(stake)} />
              <Stat label="Min stake" value={fmtUsdg(params?.minStake)} />
              <Stat label="Tier" value={bd ? `T${bd.tier}` : "—"} hint={bd ? `${Number(bd.leverageBps) / 10_000}× stake` : undefined} />
              <Stat label="Score" value={bd ? `${bd.score} / 1000` : "—"} />
            </div>
            <div className="mt-3 flex flex-col gap-3 sm:flex-row sm:items-end">
              <div className="flex-1">
                <Input label="Add stake" placeholder="100" inputMode="decimal" value={stakeStr} onChange={(e) => setStakeStr(e.target.value)} suffix="USDG" />
              </div>
              <Button disabled={!stakeAmt || stakeTx.busy} onClick={doStake}>
                {(allowance ?? 0n) < (stakeAmt ?? 0n) ? "Approve & stake" : "Stake"}
              </Button>
            </div>
            <div className="mt-2 text-xs text-zinc-500">Wallet: {fmtUsdg(balance)} USDG</div>
            <TxStatus status={stakeTx.status} error={stakeTx.error} />
            <div className="mt-2">
              <Faucet />
            </div>
          </Card>

          <Card>
            <h2 className="mb-3 font-semibold">3 · Your credit limit</h2>
            <Row k="Revenue via splitter (90d)" v={`${fmtUsdg(bd?.revenue)} USDG`} />
            <Row k="Revenue-based capacity (25%)" v={`${fmtUsdg(bd?.revenueLimit)} USDG`} />
            <Row k="Base limit" v={`${fmtUsdg(params?.baseLimit)} USDG`} />
            <Row k="Stake × leverage" v={`${fmtUsdg(bd?.stakeLimit)} USDG`} />
            <Row k="Max per agent / per owner" v={`${fmtUsdg(params?.maxPerAgent, 0)} / ${fmtUsdg(params?.maxPerOwner, 0)}`} />
            <div className="mt-2 flex items-center justify-between rounded-xl bg-ink-800 px-3 py-2">
              <span className="text-sm text-zinc-300">Credit limit</span>
              <span className="text-lg font-semibold text-tab-400 tabular-nums">{fmtUsdg(limit)} USDG</span>
            </div>
            <p className="mt-2 text-xs text-zinc-500">
              limit = min(max(base, 25% × 90-day revenue), stake × leverage, max per agent). Limits grow with revenue routed
              through your splitter and with on-time repayment cycles.
            </p>
          </Card>

          {!tabOpen && (
            <Card>
              <h2 className="mb-3 font-semibold">4 · Open the tab</h2>
              <div className="grid gap-3 sm:grid-cols-2">
                <Input label="Operator key (agent wallet) — default: you" placeholder="0x…" value={operator} onChange={(e) => setOperator(e.target.value.trim())} />
                <Input label="Payout wallet — default: you" placeholder="0x…" value={payout} onChange={(e) => setPayout(e.target.value.trim())} />
              </div>
              <Button className="mt-3 w-full sm:w-auto" disabled={!canOpen || !opValid || !payValid || openTx.busy} onClick={doOpen}>
                Open tab
              </Button>
              {!canOpen && (stake ?? 0n) < (params?.minStake ?? 0n) && (
                <p className="mt-2 text-xs text-amber-300">Stake at least {fmtUsdg(params?.minStake)} USDG first.</p>
              )}
              <TxStatus status={openTx.status} error={openTx.error} />
            </Card>
          )}

          {tabOpen && tab && (
            <Card>
              <h2 className="mb-3 font-semibold">4 · Draw</h2>
              <Input label="Amount to borrow" placeholder="0.00" inputMode="decimal" value={drawStr} onChange={(e) => setDrawStr(e.target.value)} suffix="USDG" />
              <div className="mt-2 flex justify-between text-xs text-zinc-500">
                <span>Available now: {fmtUsdg(available)} USDG</span>
                <button type="button" className="text-tab-400" onClick={() => setDrawStr((Number(available) / 1e6).toString())}>
                  Max
                </button>
              </div>
              <div className="mt-4 space-y-2">
                <div className="flex justify-between text-sm">
                  <span className="text-zinc-400">Debt after draw / limit</span>
                  <span className="tabular-nums">
                    {fmtUsdg(newDebt)} / {fmtUsdg(limit)}
                  </span>
                </div>
                <Meter value={Number(newDebt)} max={Number(limit)} />
                <Row k="Borrow APR (base + spread)" v={fmtWadPct(borrowRate)} />
                <Row k="Funds go to" v="Agent PolicyAccount (curated payees only)" />
                <Row k="Daily spend cap" v={`${fmtUsdg(preview?.dailyCap)} USDG`} />
                <Row k="Auto-repay split of revenue" v={fmtBps(tab.splitBps)} />
                {preview?.minPayment !== undefined && (
                  <Row k="Minimum payment every 30 days" v={`${fmtUsdg(preview.minPayment)} USDG`} />
                )}
              </div>
              {preview?.overLimit && <p className="mt-2 text-xs text-red-300">Exceeds your credit limit.</p>}
              {preview?.belowMin && <p className="mt-2 text-xs text-amber-300">Minimum debt is {fmtUsdg(params?.minDebt)} USDG.</p>}
              <div className="mt-4">
                <RiskAck checked={ack} onChange={setAck} />
              </div>
              <Button
                className="mt-3 w-full"
                disabled={!drawAmt || !ack || preview?.overLimit || preview?.belowMin || status !== "Active" || drawTx.busy}
                onClick={doDraw}
              >
                Draw {drawAmt ? `${fmtUsdg(drawAmt)} USDG` : ""}
              </Button>
              <TxStatus status={drawTx.status} error={drawTx.error} />
              <p className="mt-3 text-xs text-zinc-500">
                Manage repayments and your splitter address in{" "}
                <Link href="/tabs/" className="text-tab-400 underline">
                  My Tabs
                </Link>
                .
              </p>
            </Card>
          )}
        </>
      )}
    </div>
  );
}
