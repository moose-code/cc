// promise: the keeper simulates the fee-bearing pending call, refuses a pending base fee above its ceiling, and treats an unpaid paid door as a breaker failure
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseEther, parseGwei, keccak256 } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { mkdtempSync, mkdirSync, rmdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadConfig, type Deployment } from "../src/config.ts";
import { Executor } from "../src/exec.ts";
import { Breaker, Ledger, PendingStore, utcDay } from "../src/ledger.ts";
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
  const exec = new Executor(client, cfg, policy, { address: keeper }, new Ledger(undefined, cfg.dailyBudget), new Breaker(1, 60), new PendingStore());
  const out = await exec.run(call, state);
  assert.deepEqual(out, { kind: "skipped", reason: `pending base fee ${parseGwei("3.1")} above the door ceiling ${parseGwei("3")}` });
  assert.equal(simulated, false);
});

// promise: only a decoded order fault may suppress a listing; an RPC failure leaves it retryable
test("executor: listing faults exclude transport and estimate failures", async () => {
  const listingCall: Intended = { ...call, door: "buyListing", functionName: "buyListing", args: [rec.seaportAdapter, 42n, "0x"], key: "buyListing:42" };
  let failure: unknown = Object.assign(new Error("RPC unavailable"), { shortMessage: "RPC unavailable" });
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => { throw failure; },
  };
  const exec = new Executor(client, cfg, policy, { address: keeper }, new Ledger(undefined, cfg.dailyBudget), new Breaker(1, 60), new PendingStore());
  const transport = await exec.run(listingCall, state);
  assert.equal(transport.kind, "failed");
  if (transport.kind === "failed") assert.equal(transport.listingFault, false);
  failure = { data: { errorName: "CallFailed" } };
  const generic = await exec.run(listingCall, state);
  assert.equal(generic.kind, "failed");
  if (generic.kind === "failed") assert.equal(generic.listingFault, false);
  failure = { data: { errorName: "NoCredit" } };
  const order = await exec.run(listingCall, state);
  assert.equal(order.kind, "failed");
  if (order.kind === "failed") assert.equal(order.listingFault, true);
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
    getTransactionCount: async () => 0,
    getTransactionReceipt: async () => ({ status: "success", gasUsed: 60_000n, effectiveGasPrice: parseGwei("1"), blockNumber: 2n }),
  };
  const breaker = new Breaker(1, 60);
  const exec = new Executor(client, cfg, policy, { address: keeper, impersonate: true }, new Ledger(undefined, cfg.dailyBudget), breaker, new PendingStore());
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
    getTransactionCount: async () => 0,
    getTransactionReceipt: async () => ({ status: "success", gasUsed: 60_000n, effectiveGasPrice: parseGwei("1"), blockNumber: 2n }),
  };
  const ledger = new Ledger(undefined, cfg.dailyBudget);
  const breaker = new Breaker(1, 60);
  const exec = new Executor(client, cfg, policy, { address: keeper, impersonate: true }, ledger, breaker, new PendingStore());
  const out = await exec.run(call, state);
  assert.equal(out.kind, "sent");
  if (out.kind === "sent") assert.deepEqual([out.spent, out.received], [spent, 0n]);
  assert.equal(ledger.snapshot().spent, spent);
  assert.equal(ledger.remaining(), cfg.dailyBudget - spent);
  assert.equal(breaker.paused("refreshReference"), true);
});

// promise: an accepted or uncertain raw transaction keeps its nonce reserved across restart until receipt accounting completes
test("executor: a timed-out signed send blocks the next send and reconciles after restart", async () => {
  const dir = mkdtempSync(join(tmpdir(), "keeper-pending-"));
  const account = privateKeyToAccount(generatePrivateKey());
  const localCfg = { ...cfg, receiptTimeoutSec: 0, stateDir: dir };
  let sends = 0;
  let mined = false;
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => 60_000n,
    getBalance: async ({ blockNumber }: { blockNumber?: bigint }) => blockNumber ? parseEther("1") - 60_000n * parseGwei("1") : parseEther("1"),
    getTransactionCount: async () => 7,
    request: async ({ params }: { params: string[] }) => {
      sends++;
      const expected = keccak256(params[0] as `0x${string}`);
      assert.equal(new PendingStore(dir).current?.hash, expected, "durable pending marker precedes relay submission");
      return expected;
    },
    getTransactionReceipt: async () => { if (!mined) throw new Error("not found"); return { status: "success", gasUsed: 60_000n, effectiveGasPrice: parseGwei("1"), blockNumber: 2n }; },
  };
  const pending = new PendingStore(dir);
  const exec = new Executor(client, localCfg, policy, { address: account.address, account }, new Ledger(dir, cfg.dailyBudget), new Breaker(2, 60), pending);
  const first = await exec.run(call, state);
  assert.equal(first.kind, "failed");
  assert.equal(sends, 1);
  assert.equal(new PendingStore(dir).current?.nonce, 7);
  assert.equal((await exec.run(call, state)).kind, "skipped");
  assert.equal(sends, 1);
  const restarted = new Executor(client, localCfg, policy, { address: account.address, account }, new Ledger(dir, cfg.dailyBudget), new Breaker(2, 60), new PendingStore(dir));
  assert.equal((await restarted.reconcile())?.kind, "skipped");
  mined = true;
  assert.equal((await restarted.reconcile())?.kind, "reconciled");
  assert.equal(new PendingStore(dir).current, undefined);
  assert.equal(new Ledger(dir, cfg.dailyBudget).snapshot().txs, 1);
});

// promise: a relay transport error cannot release a signed nonce whose acceptance is unknown
test("executor: uncertain relay response leaves the signed transaction pending", async () => {
  const dir = mkdtempSync(join(tmpdir(), "keeper-relay-uncertain-"));
  const account = privateKeyToAccount(generatePrivateKey());
  let sends = 0;
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => 60_000n,
    getBalance: async () => parseEther("1"),
    getTransactionCount: async () => 4,
    request: async () => { sends++; throw new Error("relay transport lost response"); },
  };
  const exec = new Executor(client, { ...cfg, stateDir: dir }, policy, { address: account.address, account }, new Ledger(dir, cfg.dailyBudget), new Breaker(2, 60), new PendingStore(dir));
  assert.equal((await exec.run(call, state)).kind, "failed");
  assert.equal(new PendingStore(dir).current?.nonce, 4);
  assert.equal((await exec.run(call, state)).kind, "skipped");
  assert.equal(sends, 1);
});

// promise: a confirmed receipt never clears its pending marker or daily gas liability when ledger persistence fails
test("executor: receipt accounting failure retains pending and breaker, then records once", async () => {
  const dir = mkdtempSync(join(tmpdir(), "keeper-ledger-fail-"));
  const ledger = new Ledger(dir, cfg.dailyBudget);
  const blocked = join(dir, `ledger-${utcDay(Date.now())}.json`);
  const pending = new PendingStore(dir);
  const breaker = new Breaker(1, 60);
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => 60_000n,
    getBalance: async ({ blockNumber }: { blockNumber?: bigint }) => blockNumber ? parseEther("1") - 60_000n * parseGwei("1") : parseEther("1"),
    getTransactionCount: async () => 0,
    request: async () => { mkdirSync(blocked); return "0x" + "44".repeat(32); },
    getTransactionReceipt: async () => ({ status: "success", gasUsed: 60_000n, effectiveGasPrice: parseGwei("1"), blockNumber: 2n }),
  };
  const exec = new Executor(client, cfg, policy, { address: keeper, impersonate: true }, ledger, breaker, pending);
  assert.equal((await exec.run(call, state)).kind, "failed");
  assert.equal(breaker.paused("refreshReference"), true);
  assert.ok(pending.current);
  rmdirSync(blocked);
  assert.equal((await exec.reconcile())?.kind, "reconciled");
  assert.equal(ledger.snapshot().txs, 1);
  assert.equal(pending.current, undefined);
});
