import { defineChain } from "viem";
import { foundry } from "viem/chains";

/**
 * Same-origin RPC proxy (Vercel rewrite in vercel.json → official Robinhood RPC). Some networks cannot reach
 * *.chain.robinhood.com directly; the proxy lives on the site's own domain. Also used as the RPC the wallet adds.
 */
function proxied(path: string, direct: string): string {
  if (typeof window === "undefined" || /^(localhost|127\.0\.0\.1)$/.test(window.location.hostname)) return direct;
  return `${window.location.origin}${path}`;
}

/** Robinhood Chain mainnet (Arbitrum Orbit L2, chain ID 4663, verified via eth_chainId on the public RPC). */
export const robinhoodChain = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: {
      http: [
        process.env.NEXT_PUBLIC_ROBINHOOD_RPC_URL || proxied("/rpc/mainnet", "https://rpc.mainnet.chain.robinhood.com"),
      ],
    },
  },
});

/** Robinhood Chain testnet (chain ID 46630, verified via eth_chainId on the public RPC). */
export const robinhoodTestnet = defineChain({
  id: 46630,
  name: "Robinhood Chain Testnet",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: {
      http: [
        process.env.NEXT_PUBLIC_ROBINHOOD_TESTNET_RPC_URL ||
          proxied("/rpc/testnet", "https://rpc.testnet.chain.robinhood.com"),
      ],
    },
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
 * Chain the app targets. Defaults to Robinhood Chain mainnet (4663), the public launch target. Until the audited
 * mainnet addresses are filled in config/addresses.ts the UI shows "not deployed yet" and disables actions.
 * Set NEXT_PUBLIC_CHAIN_ID=46630 for testnet or 31337 for local anvil.
 */
export const activeChain =
  SUPPORTED.find((c) => c.id === Number(process.env.NEXT_PUBLIC_CHAIN_ID || 4663)) ?? robinhoodChain;

export const activeRpc = activeChain.rpcUrls.default.http[0] || "";
