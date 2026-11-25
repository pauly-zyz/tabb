import { createConfig, http } from "wagmi";
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
    [robinhoodChain.id]: http(robinhoodChain.rpcUrls.default.http[0] || undefined),
    [robinhoodTestnet.id]: http(robinhoodTestnet.rpcUrls.default.http[0]),
    [anvilChain.id]: http(anvilChain.rpcUrls.default.http[0]),
  },
  ssr: true, // hydrate as disconnected, then reconnect (avoids hydration mismatch with static export)
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
