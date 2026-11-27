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

/** Elysium (Kinetiq) mainnet: Arbitrum Orbit L2 settling to HyperEVM, gas token HYPE (chain ID verified on-chain). */
export const elysiumChain = defineChain({
  id: 99901,
  name: "Elysium",
  nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
  rpcUrls: {
    default: {
      http: [process.env.NEXT_PUBLIC_ELYSIUM_RPC_URL || proxied("/rpc/elysium", "https://rpc.elysium.kinetiq.xyz")],
    },
  },
  blockExplorers: { default: { name: "Elysium Explorer", url: "https://elysium.kinetiq.xyz/explorer" } },
});

export const anvilChain = defineChain({
  ...foundry,
  name: "Anvil (local)",
  rpcUrls: { default: { http: [process.env.NEXT_PUBLIC_RPC_URL || "http://127.0.0.1:8545"] } },
});

const SUPPORTED = [robinhoodChain, elysiumChain, robinhoodTestnet, anvilChain] as const;

/** Production networks the user can pick in the UI. Robinhood Chain stays the default. */
export const SELECTABLE = [robinhoodChain, elysiumChain] as const;
export const NETWORK_KEY = "tabb.network";

const buildDefault =
  SUPPORTED.find((c) => c.id === Number(process.env.NEXT_PUBLIC_CHAIN_ID || 4663)) ?? robinhoodChain;

function storedChoice() {
  if (typeof window === "undefined") return undefined;
  try {
    const id = Number(window.localStorage.getItem(NETWORK_KEY));
    return SELECTABLE.find((c) => c.id === id);
  } catch {
    return undefined;
  }
}

/**
 * Chain the app targets: the user's pick (Robinhood Chain or Elysium, stored in localStorage) when the build targets
 * a production network, otherwise the build default (NEXT_PUBLIC_CHAIN_ID; 46630 testnet, 31337 anvil).
 */
export const activeChain = SELECTABLE.some((c) => c.id === buildDefault.id) ? storedChoice() ?? buildDefault : buildDefault;

export const activeRpc = activeChain.rpcUrls.default.http[0] || "";

/** Persist the chosen network and reload (addresses are resolved once at startup). */
export function selectNetwork(chainId: number) {
  try {
    window.localStorage.setItem(NETWORK_KEY, String(chainId));
  } catch {
    /* storage unavailable: nothing to persist */
  }
  window.location.reload();
}
