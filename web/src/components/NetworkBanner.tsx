"use client";

import { activeChain } from "@/lib/chains";
import { addrs, deployed } from "@/lib/tabb";
import { Notice } from "./ui";

export function NetworkBanner() {
  if (!deployed) {
    return (
      <Notice tone="warn">
        <b>Not deployed on {activeChain.name} yet.</b> Tabb is pre-audit; mainnet contracts will be deployed by the team
        after the audit. You can explore the interface, or run it against a local anvil deployment (see README).
      </Notice>
    );
  }
  if (addrs?.mocks) {
    return (
      <Notice tone="info">
        Local demo on <b>{activeChain.name}</b> with mock USDG and a mock ERC-8004 registry. Use the faucet to get test USDG.
      </Notice>
    );
  }
  return null;
}
