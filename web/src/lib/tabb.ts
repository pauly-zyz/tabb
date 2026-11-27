import { addressesFor, isDeployed, type TabbAddresses } from "@config/addresses";
import { activeChain } from "./chains";

export const addrs: TabbAddresses | undefined = addressesFor(activeChain.id);
export const deployed = isDeployed(addrs);
/** Non-null view of the addresses; only use behind `deployed` checks. */
export const A = (addrs ?? ({} as TabbAddresses)) as TabbAddresses;

export const USDG_DECIMALS = 6;
/** Display symbol of the network's stablecoin (USDG on Robinhood Chain, USDC on Elysium). */
export const STABLE = addrs?.stableSymbol ?? "USDG";

export const STATUS = ["None", "Active", "Delinquent", "Defaulted", "Closed"] as const;
export type StatusName = (typeof STATUS)[number];

export interface AgentTab {
  owner: `0x${string}`;
  policyAccount: `0x${string}`;
  splitter: `0x${string}`;
  payout: `0x${string}`;
  status: number;
  splitBps: number;
  cycleDirty: boolean;
  openedAt: bigint;
  periodStart: bigint;
  delinquentSince: bigint;
  zeroDebtAt: bigint;
  cycleStart: bigint;
  scaledDebt: bigint;
  principal: bigint;
  periodBase: bigint;
  paidThisPeriod: bigint;
  cyclePeak: bigint;
  totalRepaid: bigint;
  revenueRepaid: bigint;
  lossWrittenOff: bigint;
  recovered: bigint;
}

export interface PaymentStatus {
  debt: bigint;
  periodEnd: bigint;
  minPaymentDue: bigint;
  paidThisPeriod: bigint;
  pastDue: boolean;
  delinquentEligibleAt: bigint;
  defaultEligibleAt: bigint;
}

/** Phase 2 (yield credit) addresses, if deployed on the active chain. */
export const Y = addrs?.yield;
export const yieldDeployed = deployed && !!Y;

export interface YieldTab {
  owner: `0x${string}`;
  adapter: `0x${string}`;
  open: boolean;
  openedAt: bigint;
  scaledDebt: bigint;
  principal: bigint;
  yieldRepaid: bigint;
  totalRepaid: bigint;
}
