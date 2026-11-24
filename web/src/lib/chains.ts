import { defineChain } from "viem";
import { foundry } from "viem/chains";

/** Robinhood Chain (Arbitrum Orbit L2). RPC comes from env — no URL is hardcoded. */
export const robinhoodChain = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [process.env.NEXT_PUBLIC_ROBINHOOD_RPC_URL || ""] } },
});

/** Robinhood Chain testnet (chain ID 46630, verified via eth_chainId on the public RPC). */
export const robinhoodTestnet = defineChain({
  id: 46630,
  name: "Robinhood Chain Testnet",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: [process.env.NEXT_PUBLIC_ROBINHOOD_TESTNET_RPC_URL || "https://rpc.testnet.chain.robinhood.com"] },
  },
  blockExplorers: { default: { name: "Explorer", url: "https://explorer.testnet.chain.robinhood.com" } },
  testnet: true,
});

export const anvilChain = defineChain({
  ...foundry,
  name: "Anvil (local)",
  rpcUrls: { default: { http: [process.env.NEXT_PUBLIC_RPC_URL || "http://127.0.0.1:8545"] } },
});

const SUPPORTED = [robinhoodChain, robinhoodTestnet, anvilChain] as const;

/**
 * Chain the app targets. Defaults to Robinhood Chain testnet (46630) until the audited mainnet deploy exists.
 * Set NEXT_PUBLIC_CHAIN_ID=4663 for mainnet or 31337 for local anvil.
 */
export const activeChain =
  SUPPORTED.find((c) => c.id === Number(process.env.NEXT_PUBLIC_CHAIN_ID || 46630)) ?? robinhoodTestnet;

export const activeRpc = activeChain.rpcUrls.default.http[0] || "";
