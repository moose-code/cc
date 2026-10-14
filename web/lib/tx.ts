"use client";

import { useState } from "react";
import { useAccount, usePublicClient, useWriteContract } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";

// Gas limit = node estimate * 1.25. Prices move with block time, so a call can
// take a longer path at execution than at estimation; the margin covers it.
const GAS_BUFFER_BPS = 12500n;

export type Write = (req: any) => Promise<`0x${string}`>;

export type StepStatus = "todo" | "wallet" | "pending" | "done" | "failed";
export type Step = { label: string; status: StepStatus; hash?: `0x${string}` };
export type Plan = { label: string; done?: boolean };

export const CANCELLED = "cancelled in wallet";

// One line for a failed transaction, from the viem error chain: shortMessage,
// metaMessages, details and errorName of up to 6 nested causes. Router and
// quoter reverts missing from the abi arrive as the 4 byte selector.
export function txError(e: unknown): string {
  const parts: string[] = [];
  let cur: any = e;
  for (let d = 0; cur && d < 6; d++, cur = cur.cause) {
    parts.push(cur.shortMessage, ...(cur.metaMessages ?? []), cur.details, cur.data?.errorName, cur.name);
    if (!cur.shortMessage && cur.message) parts.push(String(cur.message).split("\n")[0]);
  }
  const all = parts.filter(Boolean).join("\n");
  if (/user rejected|user denied|rejected the request/i.test(all)) return CANCELLED;
  if (/V4TooLittleReceived|V4TooMuchRequested|slippage|0x8b063d73|0x12bacdd3/i.test(all)) return "price moved, try again";
  if (/TransactionDeadlinePassed|0x5bf6f916/.test(all)) return "deadline passed, try again";
  if (/insufficient funds/i.test(all)) return "not enough eth for gas";
  const sig = all.match(/reverted with the following signature:\s*(0x[0-9a-f]{8})/i)?.[1];
  if (sig) return `reverted ${sig}`;
  const named = all.match(/(?:error|reverted with reason):?\s+(\w+)\(/i)?.[1];
  return (named ?? parts.find(Boolean) ?? "transaction failed").slice(0, 80);
}

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
