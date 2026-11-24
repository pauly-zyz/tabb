"use client";

import { Notice } from "./ui";

/** Mandatory risk warning shown before every draw (borrow). */
export function RiskAck({ checked, onChange }: { checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <div className="space-y-2">
      <Notice tone="warn">
        <p className="font-semibold">Risk warning — read before borrowing</p>
        <ul className="mt-1 list-disc space-y-0.5 pl-4 text-xs leading-relaxed">
          <li>Your USDG stake is first-loss capital. If the tab defaults, it is slashed to repay lenders.</li>
          <li>You must pay at least the minimum payment every 30 days. Missing it (plus a 7-day grace) makes the tab delinquent: spending freezes and 100% of revenue goes to repayment.</li>
          <li>After 30 days delinquent, anyone can trigger default: unspent funds, splitter balance and stake are seized; the agent and owner are blacklisted.</li>
          <li>Borrowed funds can only be spent with curated payees. Interest accrues continuously (base rate + agent spread).</li>
          <li>Unaudited software. Smart-contract, oracle and operational risks apply. Do not borrow more than you can repay.</li>
        </ul>
      </Notice>
      <label className="flex cursor-pointer items-start gap-2 text-sm text-zinc-300">
        <input
          type="checkbox"
          className="mt-0.5 h-5 w-5 accent-lime-400"
          checked={checked}
          onChange={(e) => onChange(e.target.checked)}
        />
        <span>I understand these risks and that my stake can be slashed.</span>
      </label>
    </div>
  );
}
