"use client";

import { useState } from "react";
import { isAddress } from "viem";
import { useAccount, useReadContracts, useSwitchChain } from "wagmi";
import { activeChain } from "@/lib/chains";
import { NetworkBanner } from "@/components/NetworkBanner";
import { Button, Card, Input, Notice, Row, SectionTitle, TxStatus } from "@/components/ui";
import { shortAddr } from "@/lib/format";
import { A, deployed } from "@/lib/tabb";
import { useTx } from "@/lib/useTx";

const adminAbi = [
  { type: "function", name: "owner", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "pendingOwner", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "acceptOwnership", stateMutability: "nonpayable", inputs: [], outputs: [] },
  { type: "function", name: "pausedFlags", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "pause", stateMutability: "nonpayable", inputs: [{ type: "uint256" }], outputs: [] },
  { type: "function", name: "unpause", stateMutability: "nonpayable", inputs: [{ type: "uint256" }], outputs: [] },
  {
    type: "function",
    name: "setPayee",
    stateMutability: "nonpayable",
    inputs: [{ type: "address" }, { type: "bool" }, { type: "string" }],
    outputs: [],
  },
  { type: "function", name: "isPayee", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "bool" }] },
] as const;

const CONTRACTS = [
  ["Agent pool", "pool"],
  ["Agent credit manager", "agentCreditManager"],
  ["Risk config", "riskConfig"],
  ["Stake vault", "stakeVault"],
  ["Credit score", "creditScore"],
  ["Payee registry", "payeeRegistry"],
] as const;

const PAUSE_OPEN_AND_DRAW = 3n;

export default function AdminPage() {
  const { address, isConnected, chainId } = useAccount();
  const { switchChain } = useSwitchChain();
  const wrongChain = isConnected && chainId !== activeChain.id;
  const reads = useReadContracts({
    contracts: CONTRACTS.flatMap(([, k]) => [
      { address: A[k], abi: adminAbi, functionName: "owner" as const },
      { address: A[k], abi: adminAbi, functionName: "pendingOwner" as const },
    ]),
    query: { enabled: deployed, refetchInterval: 15_000 },
  });
  const pendingOwners = CONTRACTS.map((_, i) => reads.data?.[i * 2 + 1]?.result as `0x${string}` | undefined);
  const expectedOwner = pendingOwners.find((x) => x && !/^0x0{40}$/i.test(x));
  const flags = useReadContracts({
    contracts: [{ address: A.agentCreditManager, abi: adminAbi, functionName: "pausedFlags" }],
    query: { enabled: deployed },
  });
  const paused = ((flags.data?.[0]?.result as bigint | undefined) ?? 0n) & PAUSE_OPEN_AND_DRAW;

  return (
    <div className="space-y-5">
      <SectionTitle title="Admin" subtitle="Protocol owner tools: accept ownership, curate payees, pause new borrowing." />
      <NetworkBanner />
      <Notice tone="warn">
        Only the protocol owner (and payee curators) can use these actions. Everything else on this page is read-only.
      </Notice>
      {deployed && (
        <>
          <Card className="space-y-3">
            <h3 className="font-semibold">Ownership</h3>
            <p className="text-sm text-zinc-400">
              The deploy hands ownership over with Ownable2Step. The new owner must accept it on every contract.
            </p>
            <div className="rounded-xl bg-ink-800 p-3 text-sm">
              <Row k="Connected wallet" v={isConnected ? shortAddr(address) : "not connected"} />
              <Row k="Network" v={!isConnected ? "—" : wrongChain ? `wrong (chain ${chainId})` : activeChain.name} />
              {expectedOwner && <Row k="Pending owner" v={shortAddr(expectedOwner)} />}
            </div>
            {!isConnected && (
              <Notice tone="warn">Connect the pending owner wallet with the button at the top right.</Notice>
            )}
            {wrongChain && (
              <Button variant="danger" onClick={() => switchChain({ chainId: activeChain.id })}>
                Switch wallet to {activeChain.name}
              </Button>
            )}
            {isConnected && !wrongChain && expectedOwner && address?.toLowerCase() !== expectedOwner.toLowerCase() && (
              <Notice tone="danger">
                The connected wallet ({shortAddr(address)}) is not the pending owner ({shortAddr(expectedOwner)}). Switch
                accounts in your wallet.
              </Notice>
            )}
            {(reads.isError || reads.data?.some((r) => r.status === "failure")) && (
              <Notice tone="warn">
                Could not read the current owners from the RPC
                {reads.error ? ` (${reads.error.message.split("\n")[0]})` : ""}. You can still press Accept ownership —
                the contract rejects it if your wallet is not the pending owner.{" "}
                <button className="underline" onClick={() => reads.refetch()}>
                  Retry
                </button>
              </Notice>
            )}
            {CONTRACTS.map(([label, k], i) => (
              <OwnerRow
                key={k}
                label={label}
                target={A[k]}
                owner={reads.data?.[i * 2]?.result as `0x${string}` | undefined}
                pending={pendingOwners[i]}
                me={address}
                ready={isConnected && !wrongChain}
              />
            ))}
          </Card>
          <PayeeCard />
          <PauseCard paused={paused !== 0n} />
        </>
      )}
    </div>
  );
}

function OwnerRow(p: {
  label: string;
  target: `0x${string}`;
  owner?: `0x${string}`;
  pending?: `0x${string}`;
  me?: string;
  ready: boolean;
}) {
  const tx = useTx();
  const hasPending = !!p.pending && !/^0x0{40}$/i.test(p.pending);
  const isPendingMe = hasPending && !!p.me && p.pending!.toLowerCase() === p.me.toLowerCase();
  const isOwnerMe = !!p.me && !!p.owner && p.owner.toLowerCase() === p.me.toLowerCase();
  const unknown = p.pending === undefined; // read failed: let the owner try anyway
  return (
    <div className="rounded-xl border border-ink-700 p-3 text-sm">
      <Row k={p.label} v={shortAddr(p.target)} />
      <Row k="Owner" v={p.owner ? shortAddr(p.owner) : "—"} />
      {hasPending && <Row k="Pending owner" v={shortAddr(p.pending!)} />}
      {isOwnerMe && <div className="mt-1 text-xs font-semibold text-tab-400">✓ You own this contract</div>}
      {(hasPending || unknown) && !isOwnerMe && (
        <div className="mt-2">
          <Button
            disabled={tx.busy || !p.ready || (!unknown && !isPendingMe)}
            onClick={() =>
              tx.send(
                { address: p.target, abi: adminAbi, functionName: "acceptOwnership", chainId: activeChain.id },
                "Accept",
              )
            }
          >
            Accept ownership
          </Button>
          <TxStatus status={tx.status} error={tx.error} />
        </div>
      )}
    </div>
  );
}

function PayeeCard() {
  const tx = useTx();
  const [payee, setPayee] = useState("");
  const [label, setLabel] = useState("");
  const valid = isAddress(payee) && label.trim().length > 0;
  return (
    <Card className="space-y-3">
      <h3 className="font-semibold">Curated payees</h3>
      <p className="text-sm text-zinc-400">
        Borrowed USDG can only be paid to these addresses (compute, APIs, data). Only add vetted providers; never an
        exchange, bridge or an address a borrower controls.
      </p>
      <Input label="Payee address" value={payee} onChange={(e) => setPayee(e.target.value.trim())} placeholder="0x…" />
      <Input label="Label" value={label} onChange={(e) => setLabel(e.target.value)} placeholder="Provider name" />
      <div className="flex flex-wrap gap-2">
        <Button
          disabled={!valid || tx.busy}
          onClick={() =>
            tx.send(
              { address: A.payeeRegistry, abi: adminAbi, functionName: "setPayee", args: [payee, true, label.trim()] },
              "Add payee",
            )
          }
        >
          Add payee
        </Button>
        <Button
          variant="ghost"
          disabled={!isAddress(payee) || tx.busy}
          onClick={() =>
            tx.send(
              { address: A.payeeRegistry, abi: adminAbi, functionName: "setPayee", args: [payee, false, label.trim()] },
              "Remove payee",
            )
          }
        >
          Remove
        </Button>
      </div>
      <TxStatus status={tx.status} error={tx.error} />
    </Card>
  );
}

function PauseCard({ paused }: { paused: boolean }) {
  const tx = useTx();
  return (
    <Card className="space-y-3">
      <h3 className="font-semibold">Emergency pause</h3>
      <p className="text-sm text-zinc-400">
        Pauses opening new tabs and drawing on the agent credit manager. Repayments, revenue splits and keeper actions
        always stay available. The guardian or owner can pause; only the owner can unpause.
      </p>
      <Row k="New tabs & draws" v={paused ? "Paused" : "Live"} />
      <Button
        variant={paused ? "primary" : "danger"}
        disabled={tx.busy}
        onClick={() =>
          tx.send(
            {
              address: A.agentCreditManager,
              abi: adminAbi,
              functionName: paused ? "unpause" : "pause",
              args: [PAUSE_OPEN_AND_DRAW],
            },
            paused ? "Unpause" : "Pause",
          )
        }
      >
        {paused ? "Unpause" : "Pause new tabs & draws"}
      </Button>
      <TxStatus status={tx.status} error={tx.error} />
    </Card>
  );
}
