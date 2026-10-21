// promise: the keeper refreshes the standing bid policy's CC reference (decision 258) through the policy's own
// permissionless, unpaid refreshReference(): only when the treasury's redemptionPolicy() answers VERSION()
// "standing-bid-v1", only while the treasury's CC redemption is on unless BID_REFRESH_ALWAYS=1, and only when the
// policy's refreshDue() is true, gated on the door's base fee ceiling and not on the keeper's profit; the call goes
// to the policy address read at the state's block, every read is tolerant of a treasury or policy without the view,
// and the tick log carries the bid budget and the policy version
import { test } from "node:test";
import assert from "node:assert/strict";
import { encodeFunctionData, getAddress, parseEther, parseGwei, toFunctionSelector, zeroAddress, type Address, type PublicClient } from "viem";
import { standingBidAbi } from "@cc/engine/abis";
import { DOORS, describe, loadConfig, type Deployment, type Door } from "../src/config.ts";
import { decide, GAS_GUESS, ownCost, recheck, refreshBidReferenceDue, STANDING_BID_VERSION, type Intended, type Policy, type State } from "../src/decide.ts";
import { readStandingBid } from "../src/chain.ts";
import { Executor } from "../src/exec.ts";
import { Breaker, Ledger, PendingStore } from "../src/ledger.ts";

const TREASURY = getAddress("0x00000000000000000000000000000000000000b0");
const POLICY = getAddress("0x00000000000000000000000000000000000000b1");
const KEEPER = getAddress("0x00000000000000000000000000000000000000f1");

const rec: Deployment = {
  chainId: 31337,
  core: "0x00000000000000000000000000000000000000c0",
  controller: "0x00000000000000000000000000000000000000c1",
  seaportAdapter: "0x00000000000000000000000000000000000000a1",
  strategyAdapter: "0x00000000000000000000000000000000000000a2",
};
const base = { RECORD: "x", RPC_URLS: "http://127.0.0.1:8545", IMPERSONATE: KEEPER };
const cfg = loadConfig(base, () => rec);

// ------------------------------------------------------------------ config

test("refreshBidReference config: the door is in the default set at the unpaid 3 gwei ceiling, takes its own ceiling, and BID_REFRESH_ALWAYS parses", () => {
  assert.ok(DOORS.includes("refreshBidReference"));
  assert.ok(cfg.doorsOn.has("refreshBidReference"), "on by default: the policy is discovered on chain, nothing to configure");
  assert.equal(cfg.doors.refreshBidReference.maxBaseFee, parseGwei("3"));
  assert.equal(cfg.doors.refreshBidReference.tip, parseGwei("0.05"));
  assert.equal(cfg.bidRefreshAlways, false);
  const tuned = loadConfig({ ...base, MAX_BASEFEE_GWEI_REFRESH_BID_REFERENCE: "1.5", BID_REFRESH_ALWAYS: "1", DOORS: "book,refreshBidReference" }, () => rec);
  assert.equal(tuned.doors.refreshBidReference.maxBaseFee, parseGwei("1.5"));
  assert.equal(tuned.bidRefreshAlways, true);
  assert.deepEqual([...tuned.doorsOn], ["book", "refreshBidReference"]);
  assert.equal(describe(tuned).bidRefreshAlways, true, "the start log shows the switch");
  assert.equal(loadConfig({ ...base, BID_REFRESH_ALWAYS: "0" }, () => rec).bidRefreshAlways, false);
});

// ------------------------------------------------------------------ decision

function policy(doorsOn: Iterable<Door> = ["refreshBidReference"], bidRefreshAlways = false): Policy {
  return {
    doors: cfg.doors,
    doorsOn: new Set(doorsOn),
    margin: cfg.margin,
    listingDelaySec: cfg.listingDelaySec,
    bookMinWei: cfg.bookMinWei,
    bookMinSec: cfg.bookMinSec,
    bidRefreshAlways,
  };
}

// only the fields the door reads; the other doors are off in these policies
function state(over: Partial<State> = {}): State {
  return {
    core: rec.core,
    controller: rec.controller,
    blockNumber: 1_000n,
    timestamp: 10_000n,
    baseFee: parseGwei("1"),
    paused: false,
    retired: false,
    balanceModule: TREASURY,
    bidPolicy: POLICY,
    bidPolicyVersion: STANDING_BID_VERSION,
    bidRefreshDue: true,
    ccRedemptionEnabled: true,
    bidBudgetAvailable: parseEther("50"),
    ...over,
  } as State;
}

const gas = { baseFee: parseGwei("1") };
const reason = (r: ReturnType<typeof decide>) => r.skips.filter((s) => s.door === "refreshBidReference").map((s) => s.reason).join(" | ");

test("refreshBidReference: due when the policy says so: one unpaid call to the policy, ungated on profit, under the door ceiling", () => {
  const p = policy();
  const s = state();
  assert.equal(STANDING_BID_VERSION, "standing-bid-v1");
  const r = decide(s, [], gas, p, new Map());
  assert.equal(r.calls.length, 1);
  const c = r.calls[0];
  assert.equal(c.door, "refreshBidReference");
  assert.equal(c.functionName, "refreshReference");
  assert.equal(c.target, "bidPolicy");
  assert.equal(c.key, "refreshBidReference");
  assert.deepEqual(c.args, []);
  assert.equal(c.payment, 0n, "the policy pays no caller, unlike the Core's refreshReference door");
  assert.equal(c.cost, ownCost(GAS_GUESS.refreshBidReference, gas, cfg.doors.refreshBidReference), "the estimated cost is carried to the log");
  assert.ok(c.payment < c.cost + p.margin, "the door would fail the paid rule, and is decided anyway");
  assert.deepEqual(c.note, { policy: POLICY, version: STANDING_BID_VERSION, ccRedemptionEnabled: true, bidBudgetAvailable: parseEther("50") });
  // the recheck at the measured gas passes too: the measured cost is logged, never a gate
  const re = recheck(c, s, undefined, 130_000n, gas, p);
  assert.equal(re.ok, true);
  assert.equal(re.cost, ownCost(130_000n, gas, cfg.doors.refreshBidReference));
  // the door's base fee ceiling still holds
  const high = decide(s, [], { baseFee: parseGwei("3") + 1n }, p, new Map());
  assert.deepEqual(high.calls, []);
  assert.match(reason(high), /above the door ceiling/);
  // a Core pause does not stop the policy's upkeep
  const paused = decide(state({ paused: true }), [], gas, p, new Map());
  assert.deepEqual(paused.calls.map((c) => c.door), ["refreshBidReference"]);
});

test("refreshBidReference: not due, or unread, sends nothing and says why", () => {
  const notDue = decide(state({ bidRefreshDue: false }), [], gas, policy(), new Map());
  assert.deepEqual(notDue.calls, []);
  assert.match(reason(notDue), /no refresh due/);
  const unread = decide(state({ bidRefreshDue: undefined }), [], gas, policy(), new Map());
  assert.deepEqual(unread.calls, []);
  assert.equal(reason(unread), "refreshDue not read");
});

// promise: while ccRedemptionEnabled() is false nothing prices at the bid, so the keeper spends no gas on the reference
// unless the owner asks for it with BID_REFRESH_ALWAYS=1 (warming the reference before the switch)
test("refreshBidReference: redemption off skips with RedemptionOff; BID_REFRESH_ALWAYS=1 refreshes anyway", () => {
  const off = decide(state({ ccRedemptionEnabled: false }), [], gas, policy(), new Map());
  assert.deepEqual(off.calls, []);
  assert.match(reason(off), /^RedemptionOff: ccRedemptionEnabled is off/);
  const unread = decide(state({ ccRedemptionEnabled: undefined }), [], gas, policy(), new Map());
  assert.deepEqual(unread.calls, []);
  assert.equal(reason(unread), "ccRedemptionEnabled not read");
  const always = decide(state({ ccRedemptionEnabled: false }), [], gas, policy(["refreshBidReference"], true), new Map());
  assert.deepEqual(always.calls.map((c) => c.door), ["refreshBidReference"]);
  // the switch does not bypass the policy's own gate
  const alwaysNotDue = decide(state({ ccRedemptionEnabled: false, bidRefreshDue: false }), [], gas, policy(["refreshBidReference"], true), new Map());
  assert.deepEqual(alwaysNotDue.calls, []);
});

test("refreshBidReference: another policy version, a policy without VERSION, no policy and no module leave the door off with a reason", () => {
  const proRata = refreshBidReferenceDue(state({ bidPolicyVersion: "pro-rata-v1" }), policy());
  assert.equal(proRata.ok, false);
  assert.equal(proRata.reason, `redemption policy ${POLICY} answers VERSION "pro-rata-v1", not standing-bid-v1`);
  const noVersion = refreshBidReferenceDue(state({ bidPolicyVersion: undefined }), policy());
  assert.equal(noVersion.ok, false);
  assert.equal(noVersion.reason, `redemption policy ${POLICY} answers VERSION nothing, not standing-bid-v1`);
  const noPolicy = refreshBidReferenceDue(state({ bidPolicy: undefined, bidPolicyVersion: undefined, bidRefreshDue: undefined }), policy());
  assert.equal(noPolicy.ok, false);
  assert.match(noPolicy.reason, /no redemption policy/);
  const noModule = refreshBidReferenceDue(state({ balanceModule: zeroAddress, bidPolicy: undefined }), policy());
  assert.equal(noModule.ok, false);
  assert.equal(noModule.reason, "no balance module bound");
  // the version gate comes before the switch and the due flag: a wrong policy is never refreshed, whatever they say
  const wrongDue = decide(state({ bidPolicyVersion: "pro-rata-v1", bidRefreshDue: true }), [], gas, policy(["refreshBidReference"], true), new Map());
  assert.deepEqual(wrongDue.calls, []);
  assert.match(reason(wrongDue), /not standing-bid-v1/);
  // off by config: neither decided nor skipped
  const off = decide(state(), [], gas, policy([]), new Map());
  assert.deepEqual(off.calls, []);
  assert.equal(reason(off), "");
});

// ------------------------------------------------------------------ chain reads

type Answer = { status: "success"; result: unknown } | { status: "failure"; error: Error };
const fail: Answer = { status: "failure", error: new Error("execution reverted") };
const ok = (result: unknown): Answer => ({ status: "success", result });

function client(answers: { [fn: string]: Answer }) {
  const calls: { functionName: string; address: Address; blockNumber?: bigint }[] = [];
  const c = {
    multicall: async ({ contracts, allowFailure, blockNumber }: { contracts: readonly { functionName: string; address: Address }[]; allowFailure?: boolean; blockNumber?: bigint }) => {
      assert.equal(allowFailure, true, "every read is tolerant");
      for (const call of contracts) calls.push({ functionName: call.functionName, address: call.address, blockNumber });
      return contracts.map((call) => answers[call.functionName] ?? fail);
    },
  } as unknown as Pick<PublicClient, "multicall">;
  return { c, calls };
}

test("standing bid reads: the treasury's policy, switch and budget, then the policy's version and refreshDue, pinned to the block", async () => {
  const full = client({ redemptionPolicy: ok(POLICY), ccRedemptionEnabled: ok(true), bidBudgetAvailable: ok(7n), VERSION: ok(STANDING_BID_VERSION), refreshDue: ok(true) });
  assert.deepEqual(await readStandingBid(full.c, TREASURY, 77n), { policy: POLICY, version: STANDING_BID_VERSION, refreshDue: true, ccRedemptionEnabled: true, bidBudgetAvailable: 7n });
  assert.deepEqual(full.calls, [
    { functionName: "redemptionPolicy", address: TREASURY, blockNumber: 77n },
    { functionName: "ccRedemptionEnabled", address: TREASURY, blockNumber: 77n },
    { functionName: "bidBudgetAvailable", address: TREASURY, blockNumber: 77n },
    { functionName: "VERSION", address: POLICY, blockNumber: 77n },
    { functionName: "refreshDue", address: POLICY, blockNumber: 77n },
  ]);
});

// promise: a treasury built before the budget, a policy without the standing bid views, or no policy at all never stall
// the tick: the missing field reads undefined and the door skips with its reason
test("standing bid reads: an older treasury, the first policy and no policy read tolerant; no module reads nothing", async () => {
  const older = client({ redemptionPolicy: ok(POLICY), ccRedemptionEnabled: ok(false), VERSION: ok("pro-rata-v1") });
  assert.deepEqual(await readStandingBid(older.c, TREASURY, 77n), { policy: POLICY, version: "pro-rata-v1", refreshDue: undefined, ccRedemptionEnabled: false, bidBudgetAvailable: undefined });
  const mute = client({ redemptionPolicy: ok(POLICY), ccRedemptionEnabled: ok(true), bidBudgetAvailable: ok(0n) });
  assert.deepEqual(await readStandingBid(mute.c, TREASURY, 77n), { policy: POLICY, version: undefined, refreshDue: undefined, ccRedemptionEnabled: true, bidBudgetAvailable: 0n });
  const none = client({ redemptionPolicy: ok(zeroAddress), ccRedemptionEnabled: ok(false), bidBudgetAvailable: ok(0n) });
  assert.deepEqual(await readStandingBid(none.c, TREASURY, 77n), { ccRedemptionEnabled: false, bidBudgetAvailable: 0n });
  assert.deepEqual(none.calls.map((c) => c.address), [TREASURY, TREASURY, TREASURY], "a zero policy is not read");
  const noView = client({});
  assert.deepEqual(await readStandingBid(noView.c, TREASURY, 77n), { ccRedemptionEnabled: undefined, bidBudgetAvailable: undefined });
  const noModule = client({ redemptionPolicy: ok(POLICY) });
  assert.deepEqual(await readStandingBid(noModule.c, zeroAddress, 77n), {});
  assert.deepEqual(noModule.calls, []);
});

// ------------------------------------------------------------------ execution

const call: Intended = {
  door: "refreshBidReference", functionName: "refreshReference", target: "bidPolicy", args: [],
  gas: GAS_GUESS.refreshBidReference, payment: 0n, cost: 0n, key: "refreshBidReference",
};
const execState = state({ potWithPending: parseEther("1") });

test("executor: a bid policy call goes to the policy read at the state's block with the policy's refreshReference calldata; the other targets are unchanged", async () => {
  const seen: { to: Address; data: `0x${string}` }[] = [];
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async ({ to, data }: { to: Address; data: `0x${string}` }) => { seen.push({ to, data }); return 90_000n; },
  };
  const exec = new Executor(client, { ...cfg, dryRun: true }, policy(), { address: KEEPER }, new Ledger(undefined, cfg.dailyBudget), new Breaker(1, 60), new PendingStore());
  assert.equal(exec.target(call, execState), POLICY);
  assert.equal(exec.target({ ...call, target: "controller" }, execState), rec.controller);
  assert.equal(exec.target({ ...call, target: undefined }, execState), rec.core);
  const out = await exec.run(call, execState);
  assert.deepEqual(out, { kind: "dry", gas: 90_000n }, "a dry run simulates and sends nothing");
  assert.equal(seen.length, 1);
  assert.equal(seen[0].to, POLICY);
  assert.equal(seen[0].data, encodeFunctionData({ abi: standingBidAbi, functionName: "refreshReference" }));
  assert.equal(seen[0].data, toFunctionSelector("refreshReference()"), "StandingBidPolicy.refreshReference takes no argument");
});

test("executor: a bid policy call with no policy in the state is refused before any simulation", async () => {
  let simulated = false;
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => { simulated = true; return 90_000n; },
  };
  const exec = new Executor(client, cfg, policy(), { address: KEEPER }, new Ledger(undefined, cfg.dailyBudget), new Breaker(1, 60), new PendingStore());
  assert.deepEqual(await exec.run(call, state({ bidPolicy: undefined })), { kind: "failed", reason: "no standing bid policy for the refreshBidReference call" });
  assert.equal(simulated, false);
});

test("executor: a confirmed policy refresh with no refund is a success, not an underpaid paid door", async () => {
  const spent = 90_000n * parseGwei("1");
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => 90_000n,
    getBalance: async ({ blockNumber }: { blockNumber?: bigint }) => blockNumber ? parseEther("1") - spent : parseEther("1"),
    getTransactionCount: async () => 0,
    request: async ({ params }: { params: { to: Address }[] }) => { assert.equal(params[0].to, POLICY); return "0x" + "88".repeat(32); },
    getTransactionReceipt: async () => ({ status: "success", gasUsed: 90_000n, effectiveGasPrice: parseGwei("1"), blockNumber: 2n }),
  };
  const breaker = new Breaker(1, 60);
  const exec = new Executor(client, cfg, policy(), { address: KEEPER, impersonate: true }, new Ledger(undefined, cfg.dailyBudget), breaker, new PendingStore());
  const out = await exec.run(call, execState);
  assert.equal(out.kind, "sent");
  if (out.kind === "sent") assert.deepEqual([out.status, out.spent, out.received], ["success", spent, 0n]);
  assert.equal(breaker.paused("refreshBidReference"), false);
});
