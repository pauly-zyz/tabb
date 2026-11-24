import { defineChain } from "viem";
import { foundry } from "viem/chains";

/** Robinhood Chain (Arbitrum Orbit L2). RPC comes from env — no URL is hardcoded. */
export const robinhoodChain = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [process.env.NEXT_PUBLIC_ROBINHOOD_RPC_URL || ""] } },
});

export const anvilChain = defineChain({
  ...foundry,
  name: "Anvil (local)",
  rpcUrls: { default: { http: [process.env.NEXT_PUBLIC_RPC_URL || "http://127.0.0.1:8545"] } },
});

const SUPPORTED = [robinhoodChain, anvilChain] as const;

/** Chain the app targets. Defaults to Robinhood Chain; set NEXT_PUBLIC_CHAIN_ID=31337 for local anvil. */
export const activeChain =
  SUPPORTED.find((c) => c.id === Number(process.env.NEXT_PUBLIC_CHAIN_ID || 4663)) ?? robinhoodChain;

export const activeRpc = activeChain.rpcUrls.default.http[0] || "";
