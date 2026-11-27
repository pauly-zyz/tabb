"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider } from "wagmi";
import { useEffect, useState, type ReactNode } from "react";
import { wagmiConfig } from "@/lib/wagmi";

export function Providers({ children }: { children: ReactNode }) {
  const [qc] = useState(() => new QueryClient({ defaultOptions: { queries: { refetchInterval: 12_000 } } }));
  // The selected network (Robinhood Chain / Elysium) lives in localStorage, so the static HTML cannot know it.
  // Render the app only after mount to avoid hydration mismatches between networks.
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={qc}>{mounted ? children : null}</QueryClientProvider>
    </WagmiProvider>
  );
}
