import { formatUnits, parseUnits } from "viem";
import { USDG_DECIMALS } from "./tabb";

export function fmtUsdg(v: bigint | undefined, digits = 2): string {
  if (v === undefined) return "—";
  const n = Number(formatUnits(v, USDG_DECIMALS));
  return n.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

export function parseUsdg(s: string): bigint | undefined {
  try {
    if (!s || Number(s) <= 0) return undefined;
    return parseUnits(s as `${number}`, USDG_DECIMALS);
  } catch {
    return undefined;
  }
}

/** WAD (1e18 = 100%) to percent string */
export function fmtWadPct(v: bigint | undefined, digits = 2): string {
  if (v === undefined) return "—";
  return `${(Number(v) / 1e16).toFixed(digits)}%`;
}

export function fmtBps(v: number | bigint | undefined): string {
  if (v === undefined) return "—";
  return `${(Number(v) / 100).toFixed(2)}%`;
}

export function shortAddr(a?: string): string {
  if (!a) return "—";
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

export function fmtDate(ts: bigint | number | undefined): string {
  if (!ts || Number(ts) === 0) return "—";
  return new Date(Number(ts) * 1000).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

export function daysFromNow(ts: bigint | number): string {
  const d = (Number(ts) * 1000 - Date.now()) / 86_400_000;
  if (d >= 0) return `in ${Math.ceil(d)}d`;
  return `${Math.floor(-d)}d ago`;
}
