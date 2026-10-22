// promise: the keeper distributes the artist and operator split (a Splits v2 push split at the Core's `artist`) in
// ETH once it holds SPLIT_MIN_ETH and, when SPLIT_MIN_BALANCE is set, in the Core's balance token once it holds that;
// the call restates the split configuration the owner gave, names the keeper as distributor, is gated on the door's
// base fee ceiling and not on the keeper's profit, goes to the split through the Splits v2 ABI, and a bad SPLIT_*
// configuration stops the keeper at start instead of reverting on chain
import { test } from "node:test";
import assert from "node:assert/strict";
import { encodeFunctionData, getAddress, parseEther, parseGwei, toFunctionSelector, zeroAddress, type Address, type PublicClient } from "viem";
import { splitV2Abi } from "@cc/engine/abis";
import { DOORS, loadConfig, splitConfig, type Deployment, type Door } from "../src/config.ts";
import { decide, GAS_GUESS, ownCost, recheck, splitLegs, type Intended, type Policy, type State } from "../src/decide.ts";
import { readSplitBalances } from "../src/chain.ts";
import { Executor } from "../src/exec.ts";
import { Breaker, Ledger, PendingStore } from "../src/ledger.ts";

// checksummed, as the config stores them
const SPLIT = getAddress("0x00000000000000000000000000000000000000d0");
const ARTIST = getAddress("0x00000000000000000000000000000000000000d1");
const OPERATOR = getAddress("0x00000000000000000000000000000000000000d2");
const KEEPER = getAddress("0x00000000000000000000000000000000000000f1");
const TOKEN = getAddress("0x00000000000000000000000000000000000000e0");

const rec: Deployment = {
  chainId: 31337,
  core: "0x00000000000000000000000000000000000000c0",
  controller: "0x00000000000000000000000000000000000000c1",
  seaportAdapter: "0x00000000000000000000000000000000000000a1",
  strategyAdapter: "0x00000000000000000000000000000000000000a2",
};
const base = { RECORD: "x", RPC_URLS: "http://127.0.0.1:8545", IMPERSONATE: KEEPER };
// the owner's split: 5/6 to the artist, 1/6 to the operator
// given lowercase, as an operator may type them; the config checksums
const good = { SPLIT_ADDRESS: SPLIT.toLowerCase(), SPLIT_RECIPIENTS: `${ARTIST},${OPERATOR}`.toLowerCase(), SPLIT_ALLOCATIONS: "5,1" };

// ------------------------------------------------------------------ config

test("split config: the owner's split parses, the total defaults to the sum, the thresholds to 0.25 ETH and BALANCE off", () => {
  const c = loadConfig({ ...base, ...good }, () => rec);
  assert.deepEqual(c.split, {
    address: SPLIT,
    recipients: [ARTIST, OPERATOR],
    allocations: [5n, 1n],
    totalAllocation: 6n,
    distributionIncentive: 0,
    minEth: parseEther("0.25"),
    minBalance: undefined,
  });
  assert.ok(c.doorsOn.has("distributeSplit"), "the door is in the default set once a split is configured");
  assert.equal(c.doors.distributeSplit.maxBaseFee, parseGwei("3"), "an unpaid door's 3 gwei ceiling");
  const full = loadConfig({ ...base, ...good, SPLIT_TOTAL_ALLOCATION: "6", SPLIT_DISTRIBUTION_INCENTIVE: "65535", SPLIT_MIN_ETH: "0.5", SPLIT_MIN_BALANCE: "1000" }, () => rec);
  assert.equal(full.split?.distributionIncentive, 65535);
  assert.equal(full.split?.minEth, parseEther("0.5"));
  assert.equal(full.split?.minBalance, parseEther("1000"), "whole tokens, 18 decimals");
});

test("split config: no SPLIT_ADDRESS (or the zero address) leaves the door off; an explicit DOORS entry without one refuses", () => {
  const off = loadConfig(base, () => rec);
  assert.equal(off.split, undefined);
  assert.equal(off.doorsOn.has("distributeSplit"), false);
  assert.deepEqual([...off.doorsOn], DOORS.filter((d) => d !== "distributeSplit"));
  assert.equal(splitConfig({ SPLIT_ADDRESS: zeroAddress, SPLIT_RECIPIENTS: ARTIST, SPLIT_ALLOCATIONS: "1" }), undefined);
  assert.throws(() => loadConfig({ ...base, DOORS: "book,distributeSplit" }, () => rec), /DOORS names distributeSplit but SPLIT_ADDRESS is unset/);
  const only = loadConfig({ ...base, DOORS: "book" }, () => rec);
  assert.deepEqual([...only.doorsOn], ["book"]);
});

test("split config: missing or mismatched recipients and allocations, a wrong total and a wide incentive are start errors", () => {
  assert.throws(() => splitConfig({ SPLIT_ADDRESS: "0x1234" }), /SPLIT_ADDRESS must be an address/);
  assert.throws(() => splitConfig({ SPLIT_ADDRESS: SPLIT }), /SPLIT_RECIPIENTS is empty/);
  assert.throws(() => splitConfig({ ...good, SPLIT_RECIPIENTS: `${ARTIST},notanaddress` }), /non address/);
  assert.throws(() => splitConfig({ ...good, SPLIT_ALLOCATIONS: "5" }), /SPLIT_RECIPIENTS has 2 entries, SPLIT_ALLOCATIONS 1/);
  assert.throws(() => splitConfig({ ...good, SPLIT_ALLOCATIONS: "5,x" }), /non integer/);
  assert.throws(() => splitConfig({ ...good, SPLIT_TOTAL_ALLOCATION: "7" }), /sum to 6, SPLIT_TOTAL_ALLOCATION is 7/);
  assert.throws(() => splitConfig({ ...good, SPLIT_TOTAL_ALLOCATION: "6.5" }), /SPLIT_TOTAL_ALLOCATION must be an integer/);
  assert.throws(() => splitConfig({ ...good, SPLIT_ALLOCATIONS: "0,0" }), /SPLIT_TOTAL_ALLOCATION is 0/);
  assert.throws(() => splitConfig({ ...good, SPLIT_DISTRIBUTION_INCENTIVE: "65536" }), /at most 65535/);
  assert.throws(() => splitConfig({ ...good, SPLIT_DISTRIBUTION_INCENTIVE: "-1" }), /at most 65535/);
});

// ------------------------------------------------------------------ decision

const cfg = loadConfig({ ...base, ...good }, () => rec);
const withBalance = loadConfig({ ...base, ...good, SPLIT_MIN_BALANCE: "100" }, () => rec);

function policy(c = cfg, doorsOn: Iterable<Door> = ["distributeSplit"]): Policy {
  return {
    doors: c.doors,
    doorsOn: new Set(doorsOn),
    margin: c.margin,
    listingDelaySec: c.listingDelaySec,
    bookMinWei: c.bookMinWei,
    bookMinSec: c.bookMinSec,
    refresh: c.refresh,
    split: c.split ? { ...c.split, distributor: KEEPER } : undefined,
  };
}

// only the fields the split door reads; the other doors are off in these policies
function state(over: Partial<State> = {}): State {
  return {
    core: rec.core,
    controller: rec.controller,
    blockNumber: 1_000n,
    timestamp: 10_000n,
    baseFee: parseGwei("1"),
    paused: false,
    retired: false,
    balanceToken: zeroAddress,
    ...over,
  } as State;
}

const gas = { baseFee: parseGwei("1") };
const reason = (r: ReturnType<typeof decide>) => r.skips.filter((s) => s.door === "distributeSplit").map((s) => s.reason).join(" | ");
const SPLIT_STRUCT = { recipients: [ARTIST, OPERATOR], allocations: [5n, 1n], totalAllocation: 6n, distributionIncentive: 0 };

test("distributeSplit: under SPLIT_MIN_ETH the keeper waits with the balance in the reason; an unread balance is never guessed", () => {
  const under = decide(state({ splitEth: parseEther("0.25") - 1n }), [], gas, policy(), new Map());
  assert.deepEqual(under.calls, []);
  assert.match(reason(under), /split ETH 249999999999999999 under SPLIT_MIN_ETH 250000000000000000/);
  const unread = decide(state({ splitEth: undefined }), [], gas, policy(), new Map());
  assert.deepEqual(unread.calls, []);
  assert.match(reason(unread), /split ETH balance not read/);
});

test("distributeSplit: at SPLIT_MIN_ETH the keeper plans distribute(split, ETH, keeper) to the split, unpaid and ungated on profit", () => {
  const p = policy();
  const s = state({ splitEth: parseEther("0.25") });
  const r = decide(s, [], gas, p, new Map());
  assert.equal(r.calls.length, 1);
  const c = r.calls[0];
  assert.equal(c.door, "distributeSplit");
  assert.equal(c.functionName, "distribute");
  assert.equal(c.target, "split");
  assert.equal(c.key, "distributeSplit:eth");
  assert.deepEqual(c.args, [SPLIT_STRUCT, zeroAddress, KEEPER]);
  assert.equal(c.payment, 0n, "no Core payment: the incentive, if any, arrives from the split itself");
  assert.equal(c.cost, ownCost(GAS_GUESS.distributeSplit, gas, cfg.doors.distributeSplit), "the estimated cost is carried to the log");
  assert.ok(c.cost + p.margin > 0n && c.payment < c.cost, "the door would fail the paid rule, and is decided anyway");
  assert.deepEqual(c.note, { split: SPLIT, token: zeroAddress, amount: parseEther("0.25"), distributor: KEEPER, incentive: 0 });
  // the recheck at the measured gas passes too: the measured cost is logged, never a gate
  const re = recheck(c, s, undefined, 400_000n, gas, p);
  assert.equal(re.ok, true);
  assert.equal(re.cost, ownCost(400_000n, gas, cfg.doors.distributeSplit));
  // the base fee ceiling of the door still holds
  const high = decide(s, [], { baseFee: parseGwei("3") + 1n }, p, new Map());
  assert.deepEqual(high.calls, []);
  assert.match(reason(high), /above the door ceiling/);
  // the split configuration is the one the owner gave, so a nonzero incentive and total reach the call unchanged
  const incentive = loadConfig({ ...base, ...good, SPLIT_DISTRIBUTION_INCENTIVE: "1000", SPLIT_TOTAL_ALLOCATION: "6" }, () => rec);
  const ri = decide(s, [], gas, policy(incentive), new Map());
  assert.deepEqual(ri.calls[0].args[0], { ...SPLIT_STRUCT, distributionIncentive: 1000 });
});

test("distributeSplit: the BALANCE leg runs only with SPLIT_MIN_BALANCE set and a balance token bound", () => {
  const rich = { splitEth: 0n, splitBalance: parseEther("100") };
  // leg off: the token balance is ignored even when it is read
  const off = decide(state({ ...rich, balanceToken: TOKEN }), [], gas, policy(cfg), new Map());
  assert.deepEqual(off.calls, []);
  assert.doesNotMatch(reason(off), /BALANCE/);
  // leg on, no token bound
  const unbound = decide(state(rich), [], gas, policy(withBalance), new Map());
  assert.deepEqual(unbound.calls, []);
  assert.match(reason(unbound), /no balance token bound/);
  // leg on, token bound, under the threshold
  const under = decide(state({ ...rich, splitBalance: parseEther("100") - 1n, balanceToken: TOKEN }), [], gas, policy(withBalance), new Map());
  assert.deepEqual(under.calls, []);
  assert.match(reason(under), /split BALANCE 99999999999999999999 under SPLIT_MIN_BALANCE 100000000000000000000/);
  // leg on, token bound, unread
  const unread = decide(state({ splitEth: 0n, balanceToken: TOKEN }), [], gas, policy(withBalance), new Map());
  assert.match(reason(unread), /split BALANCE balance not read/);
  // leg on, token bound, at the threshold: the call names the live balance token
  const due = decide(state({ ...rich, balanceToken: TOKEN }), [], gas, policy(withBalance), new Map());
  assert.equal(due.calls.length, 1);
  assert.equal(due.calls[0].key, "distributeSplit:balance");
  assert.deepEqual(due.calls[0].args, [SPLIT_STRUCT, TOKEN, KEEPER]);
});

test("distributeSplit: both legs qualify in one tick, ETH first, each its own transaction", () => {
  const s = state({ splitEth: parseEther("1"), splitBalance: parseEther("500"), balanceToken: TOKEN });
  const r = decide(s, [], gas, policy(withBalance), new Map());
  assert.deepEqual(r.calls.map((c) => c.key), ["distributeSplit:eth", "distributeSplit:balance"]);
  assert.deepEqual(r.calls.map((c) => c.args[1]), [zeroAddress, TOKEN]);
  assert.deepEqual(splitLegs(s, withBalance.split!).skips, [], "nothing waits when both legs are due");
});

test("distributeSplit: the door is off without SPLIT_ADDRESS, and a policy that names it without a split skips with a reason", () => {
  const off = loadConfig(base, () => rec);
  // the configured door set, reduced to this door: empty, so the decision neither plans nor skips it
  const r = decide(state({ splitEth: parseEther("1") }), [], gas, policy(off, [...off.doorsOn].filter((d) => d === "distributeSplit")), new Map());
  assert.deepEqual(r.calls, []);
  assert.equal(reason(r), "", "the door is not in the set, so it is neither decided nor skipped");
  const named = decide(state({ splitEth: parseEther("1") }), [], gas, policy(off, ["distributeSplit"]), new Map());
  assert.deepEqual(named.calls, []);
  assert.equal(reason(named), "no split configured");
});

// ------------------------------------------------------------------ chain reads

function client(opts: { eth?: bigint; balance?: { status: "success"; result: bigint } | { status: "failure"; error: Error }; ethFails?: boolean }) {
  const calls: { kind: string; address: Address; blockNumber?: bigint; args?: unknown }[] = [];
  const c = {
    getBalance: async ({ address, blockNumber }: { address: Address; blockNumber?: bigint }) => {
      calls.push({ kind: "getBalance", address, blockNumber });
      if (opts.ethFails) throw new Error("node fault");
      return opts.eth ?? 0n;
    },
    multicall: async ({ contracts, allowFailure, blockNumber }: { contracts: readonly { functionName: string; address: Address; args?: unknown }[]; allowFailure?: boolean; blockNumber?: bigint }) => {
      assert.equal(allowFailure, true);
      for (const call of contracts) calls.push({ kind: call.functionName, address: call.address, blockNumber, args: call.args });
      return contracts.map(() => opts.balance ?? { status: "failure", error: new Error("unexpected") });
    },
  } as unknown as Pick<PublicClient, "getBalance" | "multicall">;
  return { c, calls };
}

test("split reads: the ETH balance is pinned to the block; balanceOf only with the BALANCE leg on and a token bound; failures read undefined", async () => {
  const ethOnly = client({ eth: parseEther("0.3"), balance: { status: "success", result: 7n } });
  assert.deepEqual(await readSplitBalances(ethOnly.c, cfg.split!, TOKEN, 77n), { eth: parseEther("0.3"), balance: undefined });
  assert.deepEqual(ethOnly.calls, [{ kind: "getBalance", address: SPLIT, blockNumber: 77n }]);
  const noToken = client({ eth: 1n, balance: { status: "success", result: 7n } });
  assert.deepEqual(await readSplitBalances(noToken.c, withBalance.split!, zeroAddress, 77n), { eth: 1n, balance: undefined });
  assert.deepEqual(noToken.calls.map((c) => c.kind), ["getBalance"]);
  const both = client({ eth: 1n, balance: { status: "success", result: 7n } });
  assert.deepEqual(await readSplitBalances(both.c, withBalance.split!, TOKEN, 77n), { eth: 1n, balance: 7n });
  assert.deepEqual(both.calls, [
    { kind: "getBalance", address: SPLIT, blockNumber: 77n },
    { kind: "balanceOf", address: TOKEN, blockNumber: 77n, args: [SPLIT] },
  ]);
  const faulty = client({ ethFails: true, balance: { status: "failure", error: new Error("execution reverted") } });
  assert.deepEqual(await readSplitBalances(faulty.c, withBalance.split!, TOKEN, 77n), { eth: undefined, balance: undefined });
});

// ------------------------------------------------------------------ execution

const call: Intended = {
  door: "distributeSplit", functionName: "distribute", target: "split", args: [SPLIT_STRUCT, zeroAddress, KEEPER],
  gas: GAS_GUESS.distributeSplit, payment: 0n, cost: 0n, key: "distributeSplit:eth",
};
const execState = state({ splitEth: parseEther("1"), potWithPending: parseEther("1") });

test("executor: a split call goes to the configured split with the Splits v2 distribute calldata; the controller and Core targets are unchanged", async () => {
  const seen: { to: Address; data: `0x${string}` }[] = [];
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async ({ to, data }: { to: Address; data: `0x${string}` }) => { seen.push({ to, data }); return 90_000n; },
  };
  const exec = new Executor(client, { ...cfg, dryRun: true }, policy(), { address: KEEPER }, new Ledger(undefined, cfg.dailyBudget), new Breaker(1, 60), new PendingStore());
  assert.equal(exec.target(call, execState), SPLIT);
  assert.equal(exec.target({ ...call, target: "controller" }, execState), rec.controller);
  assert.equal(exec.target({ ...call, target: undefined }, execState), rec.core);
  const out = await exec.run(call, execState);
  assert.deepEqual(out, { kind: "dry", gas: 90_000n }, "a dry run simulates and sends nothing");
  assert.equal(seen.length, 1);
  assert.equal(seen[0].to, SPLIT);
  assert.equal(seen[0].data, encodeFunctionData({ abi: splitV2Abi, functionName: "distribute", args: [SPLIT_STRUCT, zeroAddress, KEEPER] }));
  // the selector is PushSplit.distribute(SplitV2Lib.Split, address, address) of the Splits v2 push split
  assert.equal(seen[0].data.slice(0, 10), toFunctionSelector("distribute((address[],uint256[],uint256,uint16),address,address)"));
});

test("executor: a split call without a configured split is refused before any simulation", async () => {
  let simulated = false;
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => { simulated = true; return 90_000n; },
  };
  const off = loadConfig(base, () => rec);
  const exec = new Executor(client, off, policy(off, ["distributeSplit"]), { address: KEEPER }, new Ledger(undefined, off.dailyBudget), new Breaker(1, 60), new PendingStore());
  assert.deepEqual(await exec.run(call, execState), { kind: "failed", reason: "no split configured for the distributeSplit call" });
  assert.equal(simulated, false);
});

test("executor: a confirmed distribute with no refund is a success, not an underpaid paid door", async () => {
  const spent = 90_000n * parseGwei("1");
  const client: any = {
    getBlock: async () => ({ baseFeePerGas: parseGwei("1") }),
    estimateGas: async () => 90_000n,
    getBalance: async ({ blockNumber }: { blockNumber?: bigint }) => blockNumber ? parseEther("1") - spent : parseEther("1"),
    getTransactionCount: async () => 0,
    request: async ({ params }: { params: { to: Address }[] }) => { assert.equal(params[0].to, SPLIT); return "0x" + "77".repeat(32); },
    getTransactionReceipt: async () => ({ status: "success", gasUsed: 90_000n, effectiveGasPrice: parseGwei("1"), blockNumber: 2n }),
  };
  const breaker = new Breaker(1, 60);
  const exec = new Executor(client, cfg, policy(), { address: KEEPER, impersonate: true }, new Ledger(undefined, cfg.dailyBudget), breaker, new PendingStore());
  const out = await exec.run(call, execState);
  assert.equal(out.kind, "sent");
  if (out.kind === "sent") assert.deepEqual([out.status, out.spent, out.received], ["success", spent, 0n]);
  assert.equal(breaker.paused("distributeSplit"), false);
});
