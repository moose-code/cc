"use client";

import { useState } from "react";
import { useAccount, usePublicClient, useWriteContract } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { errMsg } from "./live";

// Gas limit = node estimate * 1.25. Prices move with block time, so a call can
// take a longer path at execution than at estimation; the margin covers it.
const GAS_BUFFER_BPS = 12500n;

export type Write = (req: any) => Promise<`0x${string}`>;

// run(steps): steps receive `write`, which sets `gas` from estimateContractGas
// times GAS_BUFFER_BPS, sends with the connected account and waits for the
// receipt. After the steps every query refetches. The error of a failed step is
// kept in `err`.
export function useTx() {
  const { writeContractAsync } = useWriteContract();
  const client = usePublicClient();
  const { address } = useAccount();
  const qc = useQueryClient();
  const [pending, setPending] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const write: Write = async (req) => {
    if (!client || !address) throw new Error("wallet not connected");
    const est = await client.estimateContractGas({ ...req, account: address });
    const hash = await writeContractAsync({ ...req, gas: (est * GAS_BUFFER_BPS + 9999n) / 10000n });
    await client.waitForTransactionReceipt({ hash });
    return hash;
  };

  const run = async (steps: (write: Write) => Promise<void>) => {
    setErr(null);
    setPending(true);
    try {
      await steps(write);
      await qc.invalidateQueries();
    } catch (e) {
      setErr(errMsg(e));
    } finally {
      setPending(false);
    }
  };

  return { run, pending, err };
}
