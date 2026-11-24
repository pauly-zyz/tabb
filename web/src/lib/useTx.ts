"use client";

import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useConfig, useWriteContract } from "wagmi";
import { waitForTransactionReceipt } from "wagmi/actions";
import { BaseError } from "viem";

type Status = "idle" | "pending" | "confirming" | "success" | "error";

/** Sends a contract write, waits for the receipt, then refreshes all reads. */
export function useTx() {
  const config = useConfig();
  const qc = useQueryClient();
  const { writeContractAsync } = useWriteContract();
  const [status, setStatus] = useState<Status>("idle");
  const [error, setError] = useState<string>();
  const [hash, setHash] = useState<`0x${string}`>();

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  async function send(request: any, label?: string): Promise<boolean> {
    setError(undefined);
    setStatus("pending");
    try {
      const h = await writeContractAsync(request);
      setHash(h);
      setStatus("confirming");
      const r = await waitForTransactionReceipt(config, { hash: h });
      if (r.status !== "success") throw new Error(`${label ?? "Transaction"} reverted`);
      setStatus("success");
      await qc.invalidateQueries();
      return true;
    } catch (e) {
      const msg = e instanceof BaseError ? e.shortMessage : e instanceof Error ? e.message : String(e);
      setError(msg);
      setStatus("error");
      return false;
    }
  }

  return { send, status, error, hash, busy: status === "pending" || status === "confirming" };
}
