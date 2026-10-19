// promise: the keeper simulates the fee-bearing pending call, refuses a pending base fee above its ceiling, and treats an unpaid paid door as a breaker failure
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseEther, parseGwei } from "viem";
import { loadConfig, type Deployment } from "../src/config.ts";
import { Executor } from "../src/exec.ts";
import { Breaker, Ledger } from "../src/ledger.ts";
import type { Intended, Policy, State } from "../src/decide.ts";

const keeper = "0x00000000000000000000000000000000000000f1";
const rec: Deployment = {
  chainId: 31337, core: "0x00000000000000000000000000000000000000c0",
  controller: "0x00000000000000000000000000000000000000c1",
  seaportAdapter: "0x00000000000000000000000000000000000000a1",
  strategyAdapter: "0x00000000000000000000000000000000000000a2",
};
const cfg = loadConfig({ RECORD: "x", RPC_URLS: "http://127.0.0.1:8545", IMPERSONATE: keeper }, () => rec);
const policy: Policy = {
  doors: cfg.doors, doorsOn: cfg.doorsOn, margin: cfg.margin, listingDelaySec: cfg.listingDelaySec,
  bookMinWei: cfg.bookMinWei, bookMinSec: cfg.bookMinSec,
};
const call: Intended = {
  door: "refreshReference", functionName: "refreshReference", args: [], gas: 60_000n,
  payment: 0n, cost: 0n, key: "refreshReference",
};
const state = {
  controller: rec.controller, core: rec.core, blockNumber: 1n, baseFee: parseGwei("1"),
  potWithPending: parseEther("1"), settings: { callerFee: parseEther("0.0003"), callerMaxBaseFee: parseGwei("3") },
} as State;

test("executor: a pending base fee above the door ceiling skips before simulation", async () => {
  let simulated = false;
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("3.1") }),
    estimateGas: async () => { simulated = true; return 60_000n; },
  };
  const exec = new Executor(client, cfg, policy, { address: keeper }, new Ledger(undefined, cfg.dailyBudget), new Breaker(1, 60));
  const out = await exec.run(call, state);
  assert.deepEqual(out, { kind: "skipped", reason: `pending base fee ${parseGwei("3.1")} above the door ceiling ${parseGwei("3")}` });
  assert.equal(simulated, false);
});

test("executor: a fee-bearing pending simulation that receives no caller payment trips the breaker", async () => {
  const before = parseEther("1");
  const spent = 60_000n * parseGwei("1");
  const gasArgs: any[] = [];
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async (args: unknown) => { gasArgs.push(args); return 60_000n; },
    getBalance: async ({ blockNumber }: { blockNumber?: bigint }) => blockNumber ? before - spent : before,
    request: async () => "0x" + "11".repeat(32),
    getTransactionReceipt: async () => ({ status: "success", gasUsed: 60_000n, effectiveGasPrice: parseGwei("1"), blockNumber: 2n }),
  };
  const breaker = new Breaker(1, 60);
  const exec = new Executor(client, cfg, policy, { address: keeper, impersonate: true }, new Ledger(undefined, cfg.dailyBudget), breaker);
  const out = await exec.run(call, state);
  assert.equal(out.kind, "sent");
  if (out.kind === "sent") assert.equal(out.received, 0n);
  assert.equal(breaker.paused("refreshReference"), true);
  assert.equal(gasArgs.length, 1);
  assert.equal(gasArgs[0].blockTag, "pending");
  assert.equal(gasArgs[0].maxFeePerGas, cfg.doors.refreshReference.maxBaseFee + cfg.doors.refreshReference.tip);
  assert.equal(gasArgs[0].maxPriorityFeePerGas, cfg.doors.refreshReference.tip);
});

// promise: a confirmed receipt spends daily budget even when the historical balance read fails
test("executor: a failed receipt-block balance read records gas and trips the breaker", async () => {
  const spent = 60_000n * parseGwei("1");
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => 60_000n,
    getBalance: async ({ blockNumber }: { blockNumber?: bigint }) => {
      if (blockNumber) throw new Error("historical balance unavailable");
      return parseEther("1");
    },
    request: async () => "0x" + "22".repeat(32),
    getTransactionReceipt: async () => ({ status: "success", gasUsed: 60_000n, effectiveGasPrice: parseGwei("1"), blockNumber: 2n }),
  };
  const ledger = new Ledger(undefined, cfg.dailyBudget);
  const breaker = new Breaker(1, 60);
  const exec = new Executor(client, cfg, policy, { address: keeper, impersonate: true }, ledger, breaker);
  const out = await exec.run(call, state);
  assert.equal(out.kind, "sent");
  if (out.kind === "sent") assert.deepEqual([out.spent, out.received], [spent, 0n]);
  assert.equal(ledger.snapshot().spent, spent);
  assert.equal(ledger.remaining(), cfg.dailyBudget - spent);
  assert.equal(breaker.paused("refreshReference"), true);
});
