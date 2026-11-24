"use client";

import { useState } from "react";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { formatUnits, maxUint256, parseUnits, type Address } from "viem";
import {
  collateralAdapterAbi,
  mockAggregatorAbi,
  mockUsdgAbi,
  mockVaultAbi,
  mockYieldTokenAbi,
  oracleRouterAbi,
  tabManagerAbi,
  tabbPoolAbi,
  yieldHarvesterAbi,
  liquidatorAbi,
  yieldRiskConfigAbi,
} from "@/abi";
import { NetworkBanner } from "@/components/NetworkBanner";
import { Faucet } from "@/components/Faucet";
import { Badge, Button, Card, Input, Meter, Notice, Row, SectionTitle, Stat, TxStatus } from "@/components/ui";
import { fmtBps, fmtUsdg, fmtWadPct, parseUsdg } from "@/lib/format";
import { A, addrs, Y, yieldDeployed, type YieldTab } from "@/lib/tabb";
import { useTx } from "@/lib/useTx";

const MAX = 2n ** 256n - 1n;

interface CollateralParams {
  status: number;
  maxLtvBps: number;
  liqThresholdBps: number;
  liqBonusBps: number;
  closedMarketLtvBps: number;
  supplyCap: bigint;
  borrowCap: bigint;
}

function fmtHf(hf: bigint | undefined) {
  if (hf === undefined) return "—";
  if (hf === MAX) return "∞";
  return (Number(hf) / 1e18).toFixed(3);
}

export default function YieldPage() {
  if (!yieldDeployed || !Y) {
    return (
      <div className="space-y-5">
        <SectionTitle title="Yield Tab" subtitle="Phase 2 — self-repaying, overcollateralized credit against yield-bearing assets." />
        <NetworkBanner />
        <Notice>
          Phase 2 contracts are implemented and tested but not deployed on this network yet. Run the local anvil deployment
          to try it.
        </Notice>
        <ParamsCard />
      </div>
    );
  }
  return <YieldApp />;
}

function ParamsCard() {
  return (
    <Card>
      <h2 className="font-semibold">Initial risk parameters</h2>
      <Row k="USDG vault shares (ERC-4626)" v="LTV 80% · LT 85% · bonus 5%" />
      <Row k="Stock-dividend YT (Clipt)" v="LTV 40% · LT 50% · bonus 10%" />
      <Row k="YT maturity haircut" v="10% + 10%/yr, max 50%" />
      <Row k="Market closed (YT)" v="new borrows frozen" />
      <Row k="Close factor" v="50% (100% below HF 0.95)" />
      <Row k="Keeper reward" v="0.5% of harvested yield (max 25 USDG)" />
    </Card>
  );
}

function YieldApp() {
  const y = Y!;
  const { address } = useAccount();
  const [which, setWhich] = useState<"share" | "yt">("share");
  const adapter = (which === "share" ? y.shareAdapter : y.ytAdapter) as Address;
  const collToken = (which === "share" ? y.vault : y.yieldToken) as Address;
  const collDecimals = which === "share" ? 6 : 18;
  const collSymbol = which === "share" ? "vUSDG shares" : "YT";

  const pool = { address: y.pool, abi: tabbPoolAbi } as const;
  const { data: ps } = useReadContracts({
    contracts: [
      { ...pool, functionName: "totalAssets" },
      { ...pool, functionName: "utilization" },
      { ...pool, functionName: "supplyRate" },
      { ...pool, functionName: "borrowRateOf", args: [y.tabManager] },
      { address: y.oracle, abi: oracleRouterAbi, functionName: "isMarketOpen", args: [y.yieldToken] },
      { address: y.ytAdapter, abi: collateralAdapterAbi, functionName: "haircutBps" },
    ],
  });
  const marketOpen = ps?.[4]?.result as boolean | undefined;

  const { data: params } = useReadContract({
    address: y.risk,
    abi: yieldRiskConfigAbi,
    functionName: "collateral",
    args: [adapter],
  }) as { data: CollateralParams | undefined };

  const { data: tabIdRaw } = useReadContract({
    address: y.tabManager,
    abi: tabManagerAbi,
    functionName: "tabIdOf",
    args: [address!, adapter],
    query: { enabled: !!address },
  });
  const tabId = tabIdRaw as bigint | undefined;
  const hasTab = !!tabId && tabId > 0n;

  const { data: td } = useReadContracts({
    contracts: [
      { address: y.tabManager, abi: tabManagerAbi, functionName: "tabOf", args: [tabId ?? 0n] },
      { address: y.tabManager, abi: tabManagerAbi, functionName: "debtOf", args: [tabId ?? 0n] },
      { address: y.tabManager, abi: tabManagerAbi, functionName: "healthFactor", args: [tabId ?? 0n] },
      { address: y.tabManager, abi: tabManagerAbi, functionName: "maxBorrow", args: [tabId ?? 0n] },
      { address: adapter, abi: collateralAdapterAbi, functionName: "balanceOf", args: [tabId ?? 0n] },
      { address: adapter, abi: collateralAdapterAbi, functionName: "valueInUSDG", args: [tabId ?? 0n, 2] },
      { address: adapter, abi: collateralAdapterAbi, functionName: "pendingYield", args: [tabId ?? 0n] },
      { address: y.tabManager, abi: tabManagerAbi, functionName: "effectiveLtvBps", args: [tabId ?? 0n] },
      { address: y.tabManager, abi: tabManagerAbi, functionName: "ownerCredit", args: [address!] },
    ],
    query: { enabled: hasTab && !!address },
  });
  const tab = td?.[0]?.result as YieldTab | undefined;
  const debt = (td?.[1]?.result as bigint | undefined) ?? 0n;
  const hf = td?.[2]?.result as bigint | undefined;
  const maxBorrow = (td?.[3]?.result as bigint | undefined) ?? 0n;
  const collBal = (td?.[4]?.result as bigint | undefined) ?? 0n;
  const value = (td?.[5]?.result as bigint | undefined) ?? 0n;
  const pending = (td?.[6]?.result as bigint | undefined) ?? 0n;
  const effLtv = td?.[7]?.result as bigint | undefined;
  const credit = (td?.[8]?.result as bigint | undefined) ?? 0n;

  const { data: wd } = useReadContracts({
    contracts: [
      { address: collToken, abi: mockUsdgAbi, functionName: "balanceOf", args: [address!] },
      { address: collToken, abi: mockUsdgAbi, functionName: "allowance", args: [address!, adapter] },
      { address: A.usdg, abi: mockUsdgAbi, functionName: "allowance", args: [address!, y.tabManager] },
    ],
    query: { enabled: !!address },
  });
  const walletColl = wd?.[0]?.result as bigint | undefined;
  const collAllowance = (wd?.[1]?.result as bigint | undefined) ?? 0n;
  const usdgAllowance = (wd?.[2]?.result as bigint | undefined) ?? 0n;

  const tx = useTx();
  const [collStr, setCollStr] = useState("");
  const [borrowStr, setBorrowStr] = useState("");
  const [repayStr, setRepayStr] = useState("");
  const [wdStr, setWdStr] = useState("");
  const [ack, setAck] = useState(false);
  const collAmt = (() => {
    try {
      return collStr && Number(collStr) > 0 ? parseUnits(collStr as `${number}`, collDecimals) : undefined;
    } catch {
      return undefined;
    }
  })();
  const wdAmt = (() => {
    try {
      return wdStr && Number(wdStr) > 0 ? parseUnits(wdStr as `${number}`, collDecimals) : undefined;
    } catch {
      return undefined;
    }
  })();
  const borrowAmt = parseUsdg(borrowStr);
  const repayAmt = parseUsdg(repayStr);

  // live preview
  const lt = BigInt(params?.liqThresholdBps ?? 0);
  const newDebt = debt + (borrowAmt ?? 0n);
  const previewHf = newDebt > 0n ? (value * lt * 10n ** 18n) / (newDebt * 10_000n) : MAX;
  const ltvNow = value > 0n ? Number((newDebt * 10_000n) / value) / 100 : 0;

  async function approveIfNeeded(token: Address, spender: Address, have: bigint, need: bigint) {
    if (have >= need) return true;
    return tx.send({ address: token, abi: mockUsdgAbi, functionName: "approve", args: [spender, maxUint256] }, "Approve");
  }

  return (
    <div className="space-y-5">
      <SectionTitle
        title="Yield Tab"
        subtitle="Deposit yield-bearing collateral, borrow USDG, and let harvested yield pay it back — interest first, then principal."
      />
      <NetworkBanner />

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="Yield pool TVL" value={`$${fmtUsdg(ps?.[0]?.result as bigint | undefined, 0)}`} />
        <Stat label="Lender APY" value={fmtWadPct(ps?.[2]?.result as bigint | undefined)} />
        <Stat label="Borrow APR" value={fmtWadPct(ps?.[3]?.result as bigint | undefined)} />
        <Stat label="Stock market" value={marketOpen === undefined ? "—" : marketOpen ? "Open" : "Closed"} hint="affects YT only" />
      </div>

      <div className="grid grid-cols-2 gap-2">
        {(["share", "yt"] as const).map((k) => (
          <button
            key={k}
            type="button"
            onClick={() => setWhich(k)}
            className={`rounded-xl border px-3 py-3 text-left text-sm ${which === k ? "border-tab-400 bg-tab-400/10" : "border-ink-600 bg-ink-900"}`}
          >
            <div className="font-semibold">{k === "share" ? "USDG vault shares" : "Stock-dividend YT"}</div>
            <div className="text-xs text-zinc-400">
              {k === "share" ? "LTV 80% · LT 85%" : `LTV 40% · LT 50% · haircut ${fmtBps(ps?.[5]?.result as bigint | undefined)}`}
            </div>
          </button>
        ))}
      </div>

      {which === "yt" && marketOpen === false && (
        <Notice tone="warn">Market closed: new borrows against YT are frozen until the stock market reopens. Liquidations continue.</Notice>
      )}

      {!address && <Notice>Connect your wallet to open a yield tab.</Notice>}

      {address && !hasTab && (
        <Card>
          <h2 className="mb-2 font-semibold">Open a {which === "share" ? "vault-share" : "YT"} tab</h2>
          <p className="mb-3 text-sm text-zinc-400">One tab per collateral type. Max LTV {fmtBps(params?.maxLtvBps)}, liquidation at {fmtBps(params?.liqThresholdBps)}.</p>
          <Button disabled={tx.busy} onClick={() => tx.send({ address: y.tabManager, abi: tabManagerAbi, functionName: "openTab", args: [adapter] })}>
            Open tab
          </Button>
          <TxStatus status={tx.status} error={tx.error} />
        </Card>
      )}

      {address && hasTab && tab && (
        <Card>
          <div className="flex items-center justify-between">
            <h2 className="text-lg font-semibold">Tab #{tabId!.toString()}</h2>
            <Badge label={tab.open ? "Active" : "Closed"} />
          </div>
          <div className="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-4">
            <Stat label="Collateral" value={`${Number(formatUnits(collBal, collDecimals)).toLocaleString()}`} hint={`≈ ${fmtUsdg(value)} USDG`} />
            <Stat label="Debt" value={fmtUsdg(debt)} hint={`max borrow ${fmtUsdg(maxBorrow)}`} />
            <Stat label="Health factor" value={fmtHf(hf)} hint="< 1 = liquidatable" />
            <Stat label="Yield paid" value={fmtUsdg(tab.yieldRepaid)} hint={`pending ${fmtUsdg(pending)}`} />
          </div>

          <div className="mt-4 grid gap-4 md:grid-cols-2">
            <div className="space-y-3">
              <div>
                <Input label={`Add collateral (${collSymbol})`} placeholder="0" inputMode="decimal" value={collStr} onChange={(e) => setCollStr(e.target.value)} />
                <div className="mt-1 text-xs text-zinc-500">Wallet: {walletColl !== undefined ? Number(formatUnits(walletColl, collDecimals)).toLocaleString() : "—"}</div>
                <Button
                  className="mt-2 w-full"
                  variant="ghost"
                  disabled={!collAmt || tx.busy}
                  onClick={async () => {
                    if (!collAmt) return;
                    if (!(await approveIfNeeded(collToken, adapter, collAllowance, collAmt))) return;
                    if (await tx.send({ address: y.tabManager, abi: tabManagerAbi, functionName: "addCollateral", args: [tabId!, collAmt] })) setCollStr("");
                  }}
                >
                  Add collateral
                </Button>
              </div>
              <div>
                <Input label="Borrow" placeholder="0.00" inputMode="decimal" value={borrowStr} onChange={(e) => setBorrowStr(e.target.value)} suffix="USDG" />
                <div className="mt-2 space-y-1">
                  <div className="flex justify-between text-xs text-zinc-400">
                    <span>LTV after: {ltvNow.toFixed(1)}% (max {effLtv !== undefined ? fmtBps(effLtv) : "—"})</span>
                    <span>HF after: {fmtHf(previewHf)}</span>
                  </div>
                  <Meter value={ltvNow} max={Number(params?.liqThresholdBps ?? 10_000) / 100} />
                </div>
                <div className="mt-3">
                  <Notice tone="warn">
                    <p className="font-semibold">Risk warning</p>
                    <p className="mt-1 text-xs leading-relaxed">
                      If your collateral value drops so that health factor falls below 1, anyone can liquidate up to 50% of
                      your debt (100% below 0.95) and take collateral worth the repaid amount plus a {fmtBps(params?.liqBonusBps)} bonus.
                      Stock-linked YT can gap when markets reopen. Yield is variable and may not cover interest. Unaudited software.
                    </p>
                  </Notice>
                  <label className="mt-2 flex items-start gap-2 text-sm text-zinc-300">
                    <input type="checkbox" className="mt-0.5 h-5 w-5 accent-lime-400" checked={ack} onChange={(e) => setAck(e.target.checked)} />
                    <span>I understand the liquidation risk.</span>
                  </label>
                </div>
                <Button
                  className="mt-2 w-full"
                  disabled={!borrowAmt || !ack || borrowAmt > maxBorrow || tx.busy}
                  onClick={async () => {
                    if (await tx.send({ address: y.tabManager, abi: tabManagerAbi, functionName: "borrow", args: [tabId!, borrowAmt!] })) {
                      setBorrowStr("");
                      setAck(false);
                    }
                  }}
                >
                  Borrow
                </Button>
              </div>
            </div>
            <div className="space-y-3">
              <div>
                <Input label="Repay" placeholder="0.00" inputMode="decimal" value={repayStr} onChange={(e) => setRepayStr(e.target.value)} suffix="USDG" />
                <Button
                  className="mt-2 w-full"
                  variant="ghost"
                  disabled={!repayAmt || tx.busy}
                  onClick={async () => {
                    if (!(await approveIfNeeded(A.usdg, y.tabManager, usdgAllowance, repayAmt!))) return;
                    if (await tx.send({ address: y.tabManager, abi: tabManagerAbi, functionName: "repay", args: [tabId!, repayAmt!] })) setRepayStr("");
                  }}
                >
                  Repay
                </Button>
              </div>
              <div>
                <Input label={`Withdraw collateral (${collSymbol})`} placeholder="0" inputMode="decimal" value={wdStr} onChange={(e) => setWdStr(e.target.value)} />
                <Button
                  className="mt-2 w-full"
                  variant="ghost"
                  disabled={!wdAmt || tx.busy}
                  onClick={async () => {
                    if (await tx.send({ address: y.tabManager, abi: tabManagerAbi, functionName: "withdrawCollateral", args: [tabId!, wdAmt!] })) setWdStr("");
                  }}
                >
                  Withdraw
                </Button>
              </div>
              <div className="grid grid-cols-2 gap-2">
                <Button variant="ghost" disabled={tx.busy || pending === 0n} onClick={() => tx.send({ address: y.harvester, abi: yieldHarvesterAbi, functionName: "harvest", args: [tabId!] })}>
                  Harvest yield
                </Button>
                <Button variant="ghost" disabled={tx.busy || credit === 0n} onClick={() => tx.send({ address: y.tabManager, abi: tabManagerAbi, functionName: "claimCredit" })}>
                  Claim {fmtUsdg(credit)}
                </Button>
                <Button
                  variant="ghost"
                  className="col-span-2"
                  disabled={tx.busy || debt > 0n || collBal > 0n}
                  onClick={() => tx.send({ address: y.tabManager, abi: tabManagerAbi, functionName: "closeTab", args: [tabId!] })}
                >
                  Close tab
                </Button>
              </div>
              <Row k="Interest paid first, then principal" v="✓" />
              <Row k="Extra yield after payoff" v="credited to you" />
            </div>
          </div>
          <TxStatus status={tx.status} error={tx.error} />
        </Card>
      )}

      <YieldLend />
      <Liquidations />
      {addrs?.mocks && <MockTools />}
    </div>
  );
}

function YieldLend() {
  const y = Y!;
  const { address } = useAccount();
  const tx = useTx();
  const [amt, setAmt] = useState("");
  const a = parseUsdg(amt);
  const { data } = useReadContracts({
    contracts: [
      { address: y.pool, abi: tabbPoolAbi, functionName: "maxWithdraw", args: [address!] },
      { address: A.usdg, abi: mockUsdgAbi, functionName: "allowance", args: [address!, y.pool] },
    ],
    query: { enabled: !!address },
  });
  const maxW = data?.[0]?.result as bigint | undefined;
  const allowance = (data?.[1]?.result as bigint | undefined) ?? 0n;
  return (
    <Card>
      <h2 className="mb-1 font-semibold">Lend to the yield pool</h2>
      <p className="mb-3 text-sm text-zinc-400">Separate ERC-4626 pool backing overcollateralized yield tabs. Your withdrawable: {fmtUsdg(maxW)} USDG.</p>
      <Input placeholder="0.00" inputMode="decimal" value={amt} onChange={(e) => setAmt(e.target.value)} suffix="USDG" />
      <div className="mt-2 grid grid-cols-2 gap-2">
        <Button
          disabled={!a || !address || tx.busy}
          onClick={async () => {
            if (allowance < a!) {
              const ok = await tx.send({ address: A.usdg, abi: mockUsdgAbi, functionName: "approve", args: [y.pool, maxUint256] }, "Approve");
              if (!ok) return;
            }
            if (await tx.send({ address: y.pool, abi: tabbPoolAbi, functionName: "deposit", args: [a!, address!] })) setAmt("");
          }}
        >
          Deposit
        </Button>
        <Button
          variant="ghost"
          disabled={!a || !address || tx.busy}
          onClick={async () => {
            if (await tx.send({ address: y.pool, abi: tabbPoolAbi, functionName: "withdraw", args: [a!, address!, address!] })) setAmt("");
          }}
        >
          Withdraw
        </Button>
      </div>
      <TxStatus status={tx.status} error={tx.error} />
    </Card>
  );
}

function Liquidations() {
  const y = Y!;
  const tx = useTx();
  const { address } = useAccount();
  const { data: next } = useReadContract({ address: y.tabManager, abi: tabManagerAbi, functionName: "nextTabId" });
  const n = Number((next as bigint | undefined) ?? 1n) - 1;
  const ids = Array.from({ length: n }, (_, i) => BigInt(i + 1));
  const { data } = useReadContracts({
    contracts: ids.flatMap(
      (id) =>
        [
          { address: y.tabManager, abi: tabManagerAbi, functionName: "healthFactor", args: [id] },
          { address: y.tabManager, abi: tabManagerAbi, functionName: "debtOf", args: [id] },
          { address: y.tabManager, abi: tabManagerAbi, functionName: "tabOf", args: [id] },
        ] as const,
    ),
    query: { enabled: n > 0 },
  });
  const { data: allowance } = useReadContract({
    address: A.usdg,
    abi: mockUsdgAbi,
    functionName: "allowance",
    args: [address!, y.tabManager],
    query: { enabled: !!address },
  });
  const rows = ids
    .map((id, i) => ({
      id,
      hf: data?.[i * 3]?.result as bigint | undefined,
      debt: (data?.[i * 3 + 1]?.result as bigint | undefined) ?? 0n,
      tab: data?.[i * 3 + 2]?.result as YieldTab | undefined,
    }))
    .filter((r) => r.debt > 0n && r.hf !== undefined && r.hf < 11n * 10n ** 17n)
    .sort((a, b) => (a.hf! < b.hf! ? -1 : 1));
  return (
    <Card>
      <h2 className="mb-1 font-semibold">Liquidations</h2>
      <p className="mb-3 text-sm text-zinc-400">Yield tabs with health factor below 1.1. Below 1.0 anyone can repay up to 50% and receive collateral + bonus.</p>
      {rows.length === 0 && <p className="text-sm text-zinc-500">No positions at risk.</p>}
      {rows.map((r) => (
        <div key={r.id.toString()} className="flex flex-wrap items-center justify-between gap-2 border-t border-ink-700 py-2 text-sm">
          <span>
            Tab #{r.id.toString()} · {r.tab?.adapter.toLowerCase() === y.ytAdapter.toLowerCase() ? "YT" : "vault shares"}
          </span>
          <span className="tabular-nums">debt {fmtUsdg(r.debt)}</span>
          <span className={`tabular-nums ${r.hf! < 10n ** 18n ? "text-red-300" : "text-amber-300"}`}>HF {fmtHf(r.hf)}</span>
          <Button
            variant="danger"
            className="!min-h-[36px]"
            disabled={tx.busy || r.hf! >= 10n ** 18n || !address}
            onClick={async () => {
              if (((allowance as bigint | undefined) ?? 0n) < r.debt) {
                const ok = await tx.send({ address: A.usdg, abi: mockUsdgAbi, functionName: "approve", args: [y.tabManager, maxUint256] }, "Approve");
                if (!ok) return;
              }
              await tx.send({ address: y.liquidator, abi: liquidatorAbi, functionName: "liquidate", args: [r.id, r.debt] });
            }}
          >
            Liquidate
          </Button>
        </div>
      ))}
      <TxStatus status={tx.status} error={tx.error} />
    </Card>
  );
}

/** Local demo helpers (mock vault / YT / feed only). */
function MockTools() {
  const y = Y!;
  const { address } = useAccount();
  const tx = useTx();
  const { data: allowance } = useReadContract({
    address: A.usdg,
    abi: mockUsdgAbi,
    functionName: "allowance",
    args: [address!, y.vault],
    query: { enabled: !!address },
  });
  const [px, setPx] = useState("");
  return (
    <Card>
      <h2 className="mb-1 font-semibold">Demo controls (local mocks)</h2>
      <p className="mb-3 text-sm text-zinc-400">Simulate yield, dividends, price moves and market hours on the local deployment.</p>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
        <Faucet />
        <Button
          variant="ghost"
          disabled={!address || tx.busy}
          onClick={async () => {
            const amt = parseUnits("1000", 6);
            if (((allowance as bigint | undefined) ?? 0n) < amt) {
              const ok = await tx.send({ address: A.usdg, abi: mockUsdgAbi, functionName: "approve", args: [y.vault, maxUint256] }, "Approve");
              if (!ok) return;
            }
            await tx.send({ address: y.vault, abi: mockVaultAbi, functionName: "deposit", args: [amt, address!] });
          }}
        >
          Get 1,000 vault shares
        </Button>
        <Button variant="ghost" disabled={tx.busy} onClick={() => tx.send({ address: y.vault, abi: mockVaultAbi, functionName: "injectYield", args: [parseUnits("5000", 6)] })}>
          Vault earns 5,000 USDG
        </Button>
        <Button variant="ghost" disabled={tx.busy} onClick={() => tx.send({ address: y.yieldToken, abi: mockYieldTokenAbi, functionName: "distributeDividend", args: [parseUnits("5000", 6)] })}>
          YT pays 5,000 USDG dividend
        </Button>
        <Button variant="ghost" disabled={tx.busy} onClick={() => tx.send({ address: y.oracle, abi: oracleRouterAbi, functionName: "setMarketOpen", args: [y.yieldToken, false] })}>
          Close stock market
        </Button>
        <Button variant="ghost" disabled={tx.busy} onClick={() => tx.send({ address: y.oracle, abi: oracleRouterAbi, functionName: "setMarketOpen", args: [y.yieldToken, true] })}>
          Open stock market
        </Button>
      </div>
      {y.ytFeed && (
        <div className="mt-3 flex items-end gap-2">
          <div className="flex-1">
            <Input label="Set YT price (USD)" placeholder="10" inputMode="decimal" value={px} onChange={(e) => setPx(e.target.value)} />
          </div>
          <Button
            variant="ghost"
            disabled={!px || tx.busy}
            onClick={() => tx.send({ address: y.ytFeed!, abi: mockAggregatorAbi, functionName: "set", args: [BigInt(Math.round(Number(px) * 1e8))] })}
          >
            Set price
          </Button>
        </div>
      )}
      <TxStatus status={tx.status} error={tx.error} />
    </Card>
  );
}
