"use client";

import { useState } from "react";
import { useAccount, useReadContracts } from "wagmi";
import { formatUnits, maxUint256 } from "viem";
import { mockUsdgAbi, tabbPoolAbi } from "@/abi";
import { NetworkBanner } from "@/components/NetworkBanner";
import { Faucet } from "@/components/Faucet";
import { Button, Card, Input, Notice, Row, SectionTitle, Stat, TxStatus } from "@/components/ui";
import { usePoolStats, useUsdgBalance } from "@/lib/hooks";
import { fmtUsdg, fmtWadPct, parseUsdg } from "@/lib/format";
import { A, deployed } from "@/lib/tabb";
import { useTx } from "@/lib/useTx";

export default function LendPage() {
  const { address } = useAccount();
  const s = usePoolStats();
  const { balance, allowance } = useUsdgBalance(address, A.pool);
  const { data } = useReadContracts({
    contracts: [
      { address: A.pool, abi: tabbPoolAbi, functionName: "balanceOf", args: [address!] },
      { address: A.pool, abi: tabbPoolAbi, functionName: "maxWithdraw", args: [address!] },
    ],
    query: { enabled: deployed && !!address },
  });
  const shares = data?.[0]?.result as bigint | undefined;
  const maxWithdraw = data?.[1]?.result as bigint | undefined;
  const { data: posData } = useReadContracts({
    contracts: [{ address: A.pool, abi: tabbPoolAbi, functionName: "previewRedeem", args: [shares ?? 0n] }],
    query: { enabled: deployed && shares !== undefined },
  });
  const position = posData?.[0]?.result as bigint | undefined;

  const [dep, setDep] = useState("");
  const [wd, setWd] = useState("");
  const depTx = useTx();
  const wdTx = useTx();
  const depAmt = parseUsdg(dep);
  const wdAmt = parseUsdg(wd);
  const needsApprove = depAmt !== undefined && (allowance ?? 0n) < depAmt;

  async function deposit() {
    if (!depAmt || !address) return;
    if (needsApprove) {
      const ok = await depTx.send(
        { address: A.usdg, abi: mockUsdgAbi, functionName: "approve", args: [A.pool, maxUint256] },
        "Approve",
      );
      if (!ok) return;
    }
    const ok = await depTx.send({ address: A.pool, abi: tabbPoolAbi, functionName: "deposit", args: [depAmt, address] });
    if (ok) setDep("");
  }

  async function withdraw() {
    if (!wdAmt || !address) return;
    const ok = await wdTx.send({
      address: A.pool,
      abi: tabbPoolAbi,
      functionName: "withdraw",
      args: [wdAmt, address, address],
    });
    if (ok) setWd("");
  }

  return (
    <div className="space-y-5">
      <SectionTitle
        title="Lend"
        subtitle="Deposit USDG into the agent-credit pool (ERC-4626). Earn the base rate plus the agent risk spread."
      />
      <NetworkBanner />
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="TVL" value={`$${fmtUsdg(s.totalAssets, 0)}`} />
        <Stat label="Lender APY" value={fmtWadPct(s.supplyRate)} hint="variable" />
        <Stat label="Utilization" value={fmtWadPct(s.utilization, 1)} />
        <Stat label="Available" value={`$${fmtUsdg(s.liquidity, 0)}`} hint="withdrawable now" />
        <Stat label="Agent debt" value={`$${fmtUsdg(s.agentDebt, 0)}`} />
        <Stat label="Agent borrow APR" value={fmtWadPct(s.agentBorrowRate)} hint="base + 8% spread" />
        <Stat label="Insurance reserve" value={`$${fmtUsdg(s.treasury)}`} hint="burned first on bad debt" />
        <Stat label="Your position" value={`$${fmtUsdg(position)}`} />
      </div>

      <div className="grid gap-4 md:grid-cols-2">
        <Card>
          <h2 className="mb-3 font-semibold">Deposit</h2>
          <Input
            label="Amount"
            placeholder="0.00"
            inputMode="decimal"
            value={dep}
            onChange={(e) => setDep(e.target.value)}
            suffix="USDG"
          />
          <div className="mt-2 text-xs text-zinc-500">Wallet: {fmtUsdg(balance)} USDG</div>
          <Button className="mt-3 w-full" disabled={!deployed || !address || !depAmt || depTx.busy} onClick={deposit}>
            {needsApprove ? "Approve & deposit" : "Deposit"}
          </Button>
          <TxStatus status={depTx.status} error={depTx.error} />
          <div className="mt-3">
            <Faucet />
          </div>
        </Card>
        <Card>
          <h2 className="mb-3 font-semibold">Withdraw</h2>
          <Input
            label="Amount"
            placeholder="0.00"
            inputMode="decimal"
            value={wd}
            onChange={(e) => setWd(e.target.value)}
            suffix="USDG"
          />
          <div className="mt-2 flex justify-between text-xs text-zinc-500">
            <span>Max now: {fmtUsdg(maxWithdraw)} USDG</span>
            <button
              type="button"
              className="text-tab-400"
              onClick={() => maxWithdraw !== undefined && setWd(formatUnits(maxWithdraw, 6))}
            >
              Max
            </button>
          </div>
          <Button
            className="mt-3 w-full"
            variant="ghost"
            disabled={!deployed || !address || !wdAmt || wdTx.busy}
            onClick={withdraw}
          >
            Withdraw
          </Button>
          <TxStatus status={wdTx.status} error={wdTx.error} />
          <div className="mt-3 border-t border-ink-700 pt-2">
            <Row k="Pool shares" v={shares !== undefined ? (Number(shares) / 1e12).toLocaleString() : "—"} />
          </div>
        </Card>
      </div>

      <Notice tone="warn">
        <b>Lender risk.</b> Agent tabs are not fully collateralized. Losses are absorbed first by the agent owner&apos;s
        stake and unspent funds, then by protocol reserve shares, then by lenders (share price drops). Withdrawals are
        limited to idle liquidity. Unaudited software.
      </Notice>
    </div>
  );
}
