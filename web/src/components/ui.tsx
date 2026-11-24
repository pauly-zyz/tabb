"use client";

import type { ButtonHTMLAttributes, InputHTMLAttributes, ReactNode } from "react";

export function Card({ children, className = "" }: { children: ReactNode; className?: string }) {
  return <div className={`rounded-2xl border border-ink-700 bg-ink-900/80 p-4 sm:p-5 ${className}`}>{children}</div>;
}

export function SectionTitle({ title, subtitle }: { title: string; subtitle?: string }) {
  return (
    <div className="mb-4">
      <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">{title}</h1>
      {subtitle && <p className="mt-1 text-sm text-zinc-400">{subtitle}</p>}
    </div>
  );
}

export function Stat({ label, value, hint }: { label: string; value: ReactNode; hint?: string }) {
  return (
    <div className="rounded-xl border border-ink-700 bg-ink-800/60 p-3">
      <div className="text-xs uppercase tracking-wide text-zinc-500">{label}</div>
      <div className="mt-1 text-lg font-semibold tabular-nums">{value}</div>
      {hint && <div className="mt-0.5 text-xs text-zinc-500">{hint}</div>}
    </div>
  );
}

export function Button({
  children,
  variant = "primary",
  className = "",
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: "primary" | "ghost" | "danger" }) {
  const styles = {
    primary: "bg-tab-400 text-ink-950 hover:bg-tab-500 disabled:bg-ink-600 disabled:text-zinc-500",
    ghost: "border border-ink-600 bg-ink-800 text-zinc-200 hover:bg-ink-700 disabled:text-zinc-600",
    danger: "bg-red-500/90 text-white hover:bg-red-500 disabled:bg-ink-600 disabled:text-zinc-500",
  }[variant];
  return (
    <button
      className={`inline-flex min-h-[44px] items-center justify-center rounded-xl px-4 py-2 text-sm font-semibold transition disabled:cursor-not-allowed ${styles} ${className}`}
      {...rest}
    >
      {children}
    </button>
  );
}

export function Input({ label, suffix, ...rest }: InputHTMLAttributes<HTMLInputElement> & { label?: string; suffix?: string }) {
  return (
    <label className="block">
      {label && <span className="mb-1 block text-xs font-medium text-zinc-400">{label}</span>}
      <div className="flex items-center rounded-xl border border-ink-600 bg-ink-950 focus-within:border-tab-500">
        <input
          className="w-full min-w-0 bg-transparent px-3 py-3 text-base outline-none placeholder:text-zinc-600"
          {...rest}
        />
        {suffix && <span className="pr-3 text-sm text-zinc-500">{suffix}</span>}
      </div>
    </label>
  );
}

export function Row({ k, v }: { k: string; v: ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-3 py-1.5 text-sm">
      <span className="text-zinc-400">{k}</span>
      <span className="text-right font-medium tabular-nums">{v}</span>
    </div>
  );
}

export function Notice({ tone = "info", children }: { tone?: "info" | "warn" | "danger"; children: ReactNode }) {
  const styles = {
    info: "border-sky-500/30 bg-sky-500/10 text-sky-200",
    warn: "border-amber-500/30 bg-amber-500/10 text-amber-200",
    danger: "border-red-500/30 bg-red-500/10 text-red-200",
  }[tone];
  return <div className={`rounded-xl border px-3 py-2.5 text-sm ${styles}`}>{children}</div>;
}

const BADGE: Record<string, string> = {
  Active: "bg-tab-400/15 text-tab-400",
  Delinquent: "bg-amber-400/15 text-amber-300",
  Defaulted: "bg-red-500/15 text-red-300",
  Closed: "bg-zinc-500/15 text-zinc-300",
  None: "bg-zinc-500/15 text-zinc-400",
};

export function Badge({ label }: { label: string }) {
  return <span className={`rounded-full px-2.5 py-0.5 text-xs font-semibold ${BADGE[label] ?? BADGE.None}`}>{label}</span>;
}

export function TxStatus({ status, error }: { status: string; error?: string }) {
  if (status === "idle") return null;
  if (status === "error") return <p className="mt-2 break-words text-xs text-red-300">⚠ {error}</p>;
  const text = { pending: "Confirm in your wallet…", confirming: "Waiting for confirmation…", success: "Confirmed ✓" }[
    status
  ];
  return <p className={`mt-2 text-xs ${status === "success" ? "text-tab-400" : "text-zinc-400"}`}>{text}</p>;
}

export function Meter({ value, max, danger = 0.9 }: { value: number; max: number; danger?: number }) {
  const pct = max > 0 ? Math.min(100, (value / max) * 100) : 0;
  const color = pct / 100 >= danger ? "bg-red-400" : pct / 100 >= 0.7 ? "bg-amber-400" : "bg-tab-400";
  return (
    <div className="h-2 w-full overflow-hidden rounded-full bg-ink-700" role="meter" aria-valuenow={pct}>
      <div className={`h-full ${color} transition-all`} style={{ width: `${pct}%` }} />
    </div>
  );
}
