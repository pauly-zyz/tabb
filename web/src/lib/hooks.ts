"use client";

import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { agentCreditManagerAbi, mockUsdgAbi, tabbPoolAbi } from "@/abi";
import { A, deployed, type AgentTab, type PaymentStatus } from "./tabb";

export function usePoolStats() {
  const pool = { address: A.pool, abi: tabbPoolAbi } as const;
  const { data, isLoading } = useReadContracts({
    contracts: [
      { ...pool, functionName: "totalAssets" },
      { ...pool, functionName: "utilization" },
      { ...pool, functionName: "supplyRate" },
      { ...pool, functionName: "availableLiquidity" },
      { ...pool, functionName: "debtOf", args: [A.agentCreditManager] },
      { ...pool, functionName: "borrowRateOf", args: [A.agentCreditManager] },
      { ...pool, functionName: "treasuryAssets" },
      { address: A.agentCreditManager, abi: agentCreditManagerAbi, functionName: "agentCount" },
    ],
    query: { enabled: deployed },
  });
  const r = (i: number) => data?.[i]?.result as bigint | undefined;
  return {
    isLoading,
    totalAssets: r(0),
    utilization: r(1),
    supplyRate: r(2),
    liquidity: r(3),
    agentDebt: r(4),
    agentBorrowRate: r(5),
    treasury: r(6),
    agentCount: r(7),
  };
}

export function useUsdgBalance(owner?: `0x${string}`, spender?: `0x${string}`) {
  const { data } = useReadContracts({
    contracts: [
      { address: A.usdg, abi: mockUsdgAbi, functionName: "balanceOf", args: [owner!] },
      { address: A.usdg, abi: mockUsdgAbi, functionName: "allowance", args: [owner!, spender ?? owner!] },
    ],
    query: { enabled: deployed && !!owner },
  });
  return { balance: data?.[0]?.result as bigint | undefined, allowance: data?.[1]?.result as bigint | undefined };
}

export interface TabRow {
  agentId: bigint;
  tab: AgentTab;
  debt: bigint;
  limit: bigint;
  available: bigint;
  payment: PaymentStatus;
}

/** Reads every tab ever opened (MVP: no indexer, enumerate agentIds on-chain). */
export function useAllTabs() {
  const mgr = { address: A.agentCreditManager, abi: agentCreditManagerAbi } as const;
  const { data: count } = useReadContract({ ...mgr, functionName: "agentCount", query: { enabled: deployed } });
  const n = Number(count ?? 0n);
  const { data: idsData } = useReadContracts({
    contracts: Array.from({ length: n }, (_, i) => ({ ...mgr, functionName: "agentIds", args: [BigInt(i)] }) as const),
    query: { enabled: deployed && n > 0 },
  });
  const ids = (idsData ?? []).map((d) => d.result as bigint).filter((x) => x !== undefined);
  const { data, isLoading } = useReadContracts({
    contracts: ids.flatMap(
      (id) =>
        [
          { ...mgr, functionName: "tabOf", args: [id] },
          { ...mgr, functionName: "debtOf", args: [id] },
          { ...mgr, functionName: "creditLimitOf", args: [id] },
          { ...mgr, functionName: "availableCredit", args: [id] },
          { ...mgr, functionName: "paymentStatus", args: [id] },
        ] as const,
    ),
    query: { enabled: deployed && ids.length > 0 },
  });
  const rows: TabRow[] = [];
  ids.forEach((agentId, i) => {
    const base = i * 5;
    const tab = data?.[base]?.result as AgentTab | undefined;
    if (!tab) return;
    rows.push({
      agentId,
      tab,
      debt: (data?.[base + 1]?.result as bigint) ?? 0n,
      limit: (data?.[base + 2]?.result as bigint) ?? 0n,
      available: (data?.[base + 3]?.result as bigint) ?? 0n,
      payment: data?.[base + 4]?.result as PaymentStatus,
    });
  });
  return { rows, isLoading: isLoading && n > 0 };
}

export function useMyTabs() {
  const { address } = useAccount();
  const { rows, isLoading } = useAllTabs();
  return { rows: rows.filter((r) => address && r.tab.owner.toLowerCase() === address.toLowerCase()), isLoading };
}
