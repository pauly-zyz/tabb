"use client";

import { useAccount, useConnect, useDisconnect, useSwitchChain } from "wagmi";
import { activeChain } from "@/lib/chains";
import { shortAddr } from "@/lib/format";
import { Button } from "./ui";

export function ConnectButton() {
  const { address, isConnected, chainId } = useAccount();
  const { connect, connectors, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();

  if (!isConnected) {
    const injected = connectors[0];
    return (
      <div className="flex gap-2">
        {connectors.map((c) => (
          <Button key={c.uid} onClick={() => connect({ connector: c })} disabled={isPending} className="!min-h-[38px] !py-1.5">
            {c === injected ? "Connect wallet" : c.name}
          </Button>
        ))}
      </div>
    );
  }
  if (chainId !== activeChain.id) {
    return (
      <Button variant="danger" className="!min-h-[38px] !py-1.5" onClick={() => switchChain({ chainId: activeChain.id })}>
        Switch to {activeChain.name}
      </Button>
    );
  }
  return (
    <Button variant="ghost" className="!min-h-[38px] !py-1.5 font-mono" onClick={() => disconnect()} title="Disconnect">
      {shortAddr(address)}
    </Button>
  );
}
