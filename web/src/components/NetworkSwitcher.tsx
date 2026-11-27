"use client";

import { activeChain, SELECTABLE, selectNetwork } from "@/lib/chains";

/** Picks the network the app targets (Robinhood Chain by default, or Elysium). Hidden on testnet/local builds. */
export function NetworkSwitcher() {
  if (!SELECTABLE.some((c) => c.id === activeChain.id)) return null;
  return (
    <label className="relative">
      <span className="sr-only">Network</span>
      <select
        aria-label="Network"
        value={activeChain.id}
        onChange={(e) => selectNetwork(Number(e.target.value))}
        className="h-[38px] cursor-pointer rounded-xl border border-ink-600 bg-ink-800 px-2 text-sm text-zinc-200 hover:bg-ink-700"
      >
        {SELECTABLE.map((c) => (
          <option key={c.id} value={c.id}>
            {c.name}
          </option>
        ))}
      </select>
    </label>
  );
}
