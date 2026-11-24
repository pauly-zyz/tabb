"use client";

import { useAccount } from "wagmi";
import { parseUnits } from "viem";
import { mockUsdgAbi } from "@/abi";
import { A, addrs } from "@/lib/tabb";
import { useTx } from "@/lib/useTx";
import { Button, TxStatus } from "./ui";

/** Local/testnet-mock only: mint test USDG. */
export function Faucet() {
  const { address } = useAccount();
  const tx = useTx();
  if (!addrs?.mocks || !address) return null;
  return (
    <div>
      <Button
        variant="ghost"
        disabled={tx.busy}
        onClick={() =>
          tx.send({ address: A.usdg, abi: mockUsdgAbi, functionName: "mint", args: [address, parseUnits("10000", 6)] })
        }
      >
        Faucet: get 10,000 test USDG
      </Button>
      <TxStatus status={tx.status} error={tx.error} />
    </div>
  );
}
