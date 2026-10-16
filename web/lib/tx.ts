"use client";

import { useState } from "react";
import { useAccount, usePublicClient, useWriteContract } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { CANCELLED, txError } from "@cc/engine/errors";

// Gas limit = node estimate * 1.25. Prices move with block time, so a call can
// take a longer path at execution than at estimation; the margin covers it.
const GAS_BUFFER_BPS = 12500n;

export type Write = (req: any) => Promise<`0x${string}`>;

export type StepStatus = "todo" | "wallet" | "pending" | "done" | "failed";
export type Step = { label: string; status: StepStatus; hash?: `0x${string}` };
export type Plan = { label: string; done?: boolean };

export { CANCELLED, txError } from "@cc/engine/errors";

// run(steps, plan): `steps` receives `write`, which sets `gas` from
// estimateContractGas times GAS_BUFFER_BPS, sends with the connected account and
// waits for the receipt. Each `write` call advances to the next plan entry that
// is not `done` and reports it in `steps` as wallet, pending (with the hash),
// done or failed (a cancelled one returns to todo). After the run every query
// refetches. A failed step leaves the decoded message in `err`; reset() clears `steps` and `err`.
export function useTx() {
  const { writeContractAsync } = useWriteContract();
  const client = usePublicClient();
  const { address } = useAccount();
  const qc = useQueryClient();
  const [pending, setPending] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [steps, setSteps] = useState<Step[]>([]);

  const reset = () => {
    setErr(null);
    setSteps([]);
  };

  const run = async (fn: (write: Write) => Promise<void>, plan: Plan[] = []) => {
    setErr(null);
    setPending(true);
    setSteps(plan.map((p) => ({ label: p.label, status: p.done ? "done" : "todo" })));
    let cur = -1;
    const patch = (p: Partial<Step>) => setSteps((s) => s.map((x, j) => (j === cur ? { ...x, ...p } : x)));

    const write: Write = async (req) => {
      if (!client || !address) throw new Error("wallet not connected");
      do cur++;
      while (plan[cur]?.done);
      patch({ status: "wallet" });
      const est = await client.estimateContractGas({ ...req, account: address });
      const hash = await writeContractAsync({ ...req, gas: (est * GAS_BUFFER_BPS + 9999n) / 10000n });
      patch({ status: "pending", hash });
      const receipt = await client.waitForTransactionReceipt({ hash });
      if (receipt.status !== "success") throw new Error("transaction reverted");
      patch({ status: "done" });
      return hash;
    };

    try {
      await fn(write);
    } catch (e) {
      const msg = txError(e);
      // a rejected request leaves the step to retry; a failed one keeps its hash
      setSteps((s) => s.map((x, j) => (j === cur && x.status !== "done" ? { ...x, status: msg === CANCELLED ? "todo" : "failed" } : x)));
      setErr(msg);
    } finally {
      // after a failure too: completed approvals change the plan of the retry
      await qc.invalidateQueries();
      setPending(false);
    }
  };

  return { run, pending, err, steps, reset };
}
