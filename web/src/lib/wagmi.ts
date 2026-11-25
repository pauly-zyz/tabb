import { createConfig, fallback, http, unstable_connector } from "wagmi";
import { injected, walletConnect } from "wagmi/connectors";
import { activeChain, anvilChain, robinhoodChain, robinhoodTestnet } from "./chains";

const wcProjectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID;

export const wagmiConfig = createConfig({
  chains: [activeChain],
  connectors: [
    injected({ shimDisconnect: true }),
    ...(wcProjectId ? [walletConnect({ projectId: wcProjectId, showQrModal: true })] : []),
  ],
  transports: {
    // If the public RPC fails in the user's browser (rate limit, network filter), reads fall back to the wallet's RPC.
    [robinhoodChain.id]: fallback([http(robinhoodChain.rpcUrls.default.http[0]), unstable_connector(injected)]),
    [robinhoodTestnet.id]: fallback([http(robinhoodTestnet.rpcUrls.default.http[0]), unstable_connector(injected)]),
    [anvilChain.id]: http(anvilChain.rpcUrls.default.http[0]),
  },
  ssr: true, // hydrate as disconnected, then reconnect (avoids hydration mismatch with static export)
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
