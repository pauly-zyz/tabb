"use client";

import { useAccount, useConnect, useConnections, useDisconnect, useSwitchChain } from "wagmi";
import { activeChain } from "@/lib/chains";
import { shortAddr } from "@/lib/format";
import { Button } from "./ui";

export function ConnectButton() {
  const { address, isConnected, chainId, connector } = useAccount();
  const { connect, connectors, isPending } = useConnect();
  const { disconnectAsync } = useDisconnect();
  const connections = useConnections();
  // Disconnect every connected wallet (wagmi can auto-reconnect several extensions at once) so the user explicitly
  // picks the wallet that will sign.
  const disconnectAll = async () => {
    for (const c of connections) await disconnectAsync({ connector: c.connector }).catch(() => {});
  };
  const { switchChain } = useSwitchChain();

  if (!isConnected) {
    // Prefer wallets announced via EIP-6963 (named). The generic injected connector targets window.ethereum, which
    // another extension (e.g. Phantom, Bitget) may hijack so signature requests go to a wallet the user isn't using.
    const named = connectors.filter((c) => c.id !== "injected");
    const list = named.length > 0 ? named : connectors;
    return (
      <div className="flex flex-wrap justify-end gap-2">
        {list.map((c) => (
          <Button key={c.uid} onClick={() => connect({ connector: c })} disabled={isPending} className="!min-h-[38px] !py-1.5">
            {c.id === "injected" ? "Connect wallet" : c.name}
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
    <Button variant="ghost" className="!min-h-[38px] !py-1.5 font-mono" onClick={disconnectAll} title="Disconnect">
      {connector?.name && connector.id !== "injected" ? `${connector.name} · ` : ""}
      {shortAddr(address)}
    </Button>
  );
}
