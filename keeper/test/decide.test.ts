// promise: every keeper gate restates its Core rule at the boundary, so the keeper never sends a call that reverts on a
// gate it can read, nor a paid call that pays it less than its own gas plus the margin
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseEther, parseGwei, zeroAddress, type Address } from "viem";
import {
  bookLatches,
  BUYBACK_GAS,
  buybackQuote,
  callerPayment,
  decide,
  GAS_GUESS,
  listingKey,
  observe,
  recheck,
  worstBaseFee,
  type Listing,
  type Policy,
  type State,
} from "../src/decide.ts";
import { DOORS, type Door } from "../src/config.ts";

const CORE = "0x00000000000000000000000000000000000000c0" as Address;
const SEAPORT_ADAPTER = "0x00000000000000000000000000000000000000a1" as Address;

// launch values of script/config/mainnet.json (decisions 119 and 130)
function state(over: Partial<State> = {}): State {
  return {
    core: CORE,
    blockNumber: 1_000n,
    timestamp: 10_000n,
    baseFee: parseGwei("1"),
    settings: {
      buybackSlice: parseEther("0.5"),
      buybackDelay: 25,
      keeperFee: parseEther("0.0003"),
      keeperMaxBaseFee: parseGwei("5"),
      callerFee: parseEther("0.0003"),
      callerMaxBaseFee: parseGwei("3"),
      redeemOn: true,
    },
    ethPot: parseEther("10"),
    potWithPending: parseEther("10"),
    pendingIncome: 0n,
    ethToBuyback: 0n,
    payeeOn: true,
    paused: false,
    retired: false,
    lastBuybackBlock: 0n,
    sniperSeconds: 1_800n,
    launchedAt: 1n,
    escrowBalance: 0n,
    pageReady: false,
    balanceModule: zeroAddress,
    atFloor: [],
    ...over,
  };
}

function policy(over: Partial<{ [d in Door]: { maxBaseFee: bigint; tip: bigint } }> = {}, delay = 120): Policy {
  const doors = {} as Policy["doors"];
  for (const d of DOORS) doors[d] = { maxBaseFee: d === "buyListing" || d === "buyback" ? parseGwei("5") : parseGwei("3"), tip: parseGwei(d === "compose" ? "0.02" : "0.05") };
  return { doors: { ...doors, ...over }, doorsOn: new Set(DOORS), margin: parseEther("0.00005"), listingDelaySec: delay };
}

const gas = (g: string) => ({ baseFee: parseGwei(g) });
const doorsOf = (r: ReturnType<typeof decide>) => r.calls.map((c) => c.door);
const reason = (r: ReturnType<typeof decide>, d: Door) => r.skips.filter((s) => s.door === d).map((s) => s.reason).join(" | ");

// ------------------------------------------------------------------ buyback

test("buyback: the delay opens at lastBuybackBlock + buybackDelay, the next block included", () => {
  const p = policy();
  // the next block is blockNumber + 1; open = 975 + 25 = 1000 < 1001, and 977 + 25 = 1002 > 1001
  const open = decide(state({ ethToBuyback: parseEther("1"), lastBuybackBlock: 976n }), [], gas("1"), p, new Map());
  assert.deepEqual(doorsOf(open), ["buyback"]);
  const shut = decide(state({ ethToBuyback: parseEther("1"), lastBuybackBlock: 977n }), [], gas("1"), p, new Map());
  assert.deepEqual(doorsOf(shut), []);
  assert.match(reason(shut, "buyback"), /TooSoon: open at block 1002/);
});

test("buyback: a slice under 2 * maxPay is SliceTooSmall, at 2 * maxPay the Core takes it", () => {
  const p = policy();
  const g = gas("1");
  const b = worstBaseFee(g, p.doors.buyback);
  const maxPay = BUYBACK_GAS * b + parseEther("0.0003");
  assert.equal(buybackQuote(state({ ethToBuyback: 2n * maxPay }), 2_000n, 270_000n, b).ok, true);
  const under = decide(state({ ethToBuyback: 2n * maxPay - 1n }), [], g, p, new Map());
  assert.deepEqual(doorsOf(under), []);
  assert.match(reason(under, "buyback"), /SliceTooSmall/);
});

test("buyback: a slice near 2 * maxPay scales the fee to almost nothing, so the keeper's tip is a loss and it waits", () => {
  const p = policy();
  const g = gas("1");
  const maxPay = BUYBACK_GAS * worstBaseFee(g, p.doors.buyback) + parseEther("0.0003");
  const at = decide(state({ ethToBuyback: 2n * maxPay }), [], g, p, new Map());
  assert.deepEqual(doorsOf(at), []);
  assert.match(reason(at, "buyback"), /unprofitable/);
});

test("buyback: an empty pot is NothingToBuy", () => {
  const r = decide(state({ ethToBuyback: 0n }), [], gas("1"), policy(), new Map());
  assert.match(reason(r, "buyback"), /NothingToBuy/);
});

test("buyback: the fee is scaled by spent over buybackSlice - maxPay, and the full slice pays the whole fee", () => {
  const s = state({ ethToBuyback: parseEther("0.5") });
  const full = buybackQuote(s, 2_000n, 270_000n, parseGwei("1"));
  assert.ok(full.ok);
  assert.equal(full.payment, 270_000n * parseGwei("1") + parseEther("0.0003"));
  const half = buybackQuote({ ...s, ethToBuyback: parseEther("0.25") }, 2_000n, 270_000n, parseGwei("1"));
  assert.ok(half.ok);
  const maxPay = BUYBACK_GAS * parseGwei("1") + parseEther("0.0003");
  const fee = (parseEther("0.0003") * (parseEther("0.25") - maxPay)) / (parseEther("0.5") - maxPay);
  assert.equal(half.payment, 270_000n * parseGwei("1") + fee);
});

// ------------------------------------------------------------------ the 5 gwei cap

test("cap: a base fee above the door ceiling skips the door, at the ceiling it runs", () => {
  const s = state({ ethToBuyback: parseEther("1") });
  assert.deepEqual(doorsOf(decide(s, [], gas("5"), policy(), new Map())), ["buyback"]);
  const over = decide(s, [], { baseFee: parseGwei("5") + 1n }, policy(), new Map());
  assert.deepEqual(doorsOf(over), []);
  assert.match(reason(over, "buyback"), /above the door ceiling/);
});

test("cap: above keeperMaxBaseFee the refund stops at 5 gwei and the paid door loses, so it is skipped", () => {
  // the owner lets the keeper send at 10 gwei; the Core still refunds at 5 gwei
  const p = policy({ buyback: { maxBaseFee: parseGwei("10"), tip: parseGwei("0.05") } });
  const r = decide(state({ ethToBuyback: parseEther("1") }), [], gas("6"), p, new Map());
  assert.deepEqual(doorsOf(r), []);
  assert.match(reason(r, "buyback"), /unprofitable/);
});

test("cap: the worst base fee is the next block's 9/8 rise, bounded by the door ceiling", () => {
  const p = policy().doors.buyback;
  assert.equal(worstBaseFee(gas("4"), p), parseGwei("4.5"));
  assert.equal(worstBaseFee(gas("4.8"), p), parseGwei("5"));
});

// ------------------------------------------------------------------ listings

function listing(over: Partial<Listing> = {}): Listing {
  return { venue: "seaport", adapter: SEAPORT_ADAPTER, id: 7n, price: parseEther("0.01"), bid: parseEther("0.012"), params: "0x1234", valid: true, ...over };
}

test("listing: swept only after it has been sweepable for the listing delay (decision 129)", () => {
  const p = policy({}, 120);
  const l = listing();
  const t0 = decide(state({ timestamp: 1_000n }), [l], gas("1"), p, new Map());
  assert.deepEqual(doorsOf(t0), []);
  assert.match(reason(t0, "buyListing"), /seen 0 s ago, delay 120 s/);
  const t1 = decide(state({ timestamp: 1_119n }), [l], gas("1"), p, t0.seen);
  assert.deepEqual(doorsOf(t1), []);
  const t2 = decide(state({ timestamp: 1_120n }), [l], gas("1"), p, t1.seen);
  assert.deepEqual(doorsOf(t2), ["buyListing"]);
  assert.deepEqual(t2.calls[0].args, [SEAPORT_ADAPTER, 7n, "0x1234"]);
});

test("listing: a listing that leaves the sweepable set restarts its delay; a new price is a new listing", () => {
  const seen = observe(new Map([[listingKey(listing()), 1_000n]]), [], 1_100n);
  assert.equal(seen.size, 0);
  const again = observe(new Map([[listingKey(listing()), 1_000n]]), [listingKey(listing({ price: parseEther("0.011") }))], 1_100n);
  assert.deepEqual([...again.values()], [1_100n]);
});

test("listing: the payment is min(gas refund + keeperFee, bid - price, ethPot - price); a small gap is unprofitable", () => {
  const p = policy({}, 0);
  // a gap of 0.0001 eth caps the payment under the cost of ~520k gas at 1.125 gwei plus the tip
  const thin = listing({ price: parseEther("0.0119") });
  const r = decide(state(), [thin], gas("1"), p, new Map());
  assert.deepEqual(doorsOf(r), []);
  assert.match(reason(r, "buyListing"), /unprofitable: payment 100000000000000/);
  // the pot cap: a pot just above the price
  const pot = decide(state({ potWithPending: parseEther("0.0101") }), [listing()], gas("1"), p, new Map());
  assert.deepEqual(doorsOf(pot), []);
});

test("listing: above the bid or the pot, or not fillable, it is not swept", () => {
  const p = policy({}, 0);
  assert.deepEqual(doorsOf(decide(state(), [listing({ price: parseEther("0.013") })], gas("1"), p, new Map())), []);
  const potShort = decide(state({ potWithPending: parseEther("0.005") }), [listing()], gas("1"), p, new Map());
  assert.match(reason(potShort, "buyListing"), /PotTooSmall/);
  const cancelled = decide(state(), [listing({ valid: false, why: "order cancelled" })], gas("1"), p, new Map());
  assert.match(reason(cancelled, "buyListing"), /order cancelled/);
});

test("listing: the best gap goes first (Activity.s.sol rule), and every sweep precedes the buyback", () => {
  const p = policy({}, 0);
  const a = listing({ id: 1n, price: parseEther("0.010") });
  const b = listing({ id: 2n, price: parseEther("0.008") });
  const r = decide(state({ ethToBuyback: parseEther("1") }), [a, b], gas("1"), p, new Map());
  assert.deepEqual(r.calls.map((c) => c.key), [listingKey(b), listingKey(a), "buyback"]);
});

test("listing: nothing is swept after migrate (Retired)", () => {
  assert.deepEqual(doorsOf(decide(state({ retired: true }), [listing()], gas("1"), policy({}, 0), new Map())), []);
});

// ------------------------------------------------------------------ compose and redeem (decision 130)

test("compose: paid at the launch values under 3 gwei, skipped above, unpaid settings never compose", () => {
  const s = state({ pageReady: true });
  assert.deepEqual(doorsOf(decide(s, [], gas("1"), policy(), new Map())), ["compose"]);
  // at 2.9 gwei the worst base fee passes 3 gwei, where the refund stops
  const high = decide(s, [], gas("2.9"), policy({ compose: { maxBaseFee: parseGwei("5"), tip: parseGwei("0.05") } }), new Map());
  assert.deepEqual(doorsOf(high), []);
  assert.match(reason(high, "compose"), /unprofitable/);
  const unpaid = decide({ ...s, settings: { ...s.settings, callerFee: 0n, callerMaxBaseFee: 0n } }, [], gas("1"), policy(), new Map());
  assert.deepEqual(doorsOf(unpaid), []);
  assert.equal(callerPayment({ ...s, settings: { ...s.settings, callerFee: 0n, callerMaxBaseFee: 0n } }, 8_000_000n, 13_700_000n, parseGwei("1")), 0n);
});

test("compose: not ready is NotReady", () => {
  assert.match(reason(decide(state(), [], gas("1"), policy(), new Map()), "compose"), /NotReady/);
});

test("redeem: logged only while no balance module is set; paid once one is", () => {
  const dry = decide(state({ atFloor: [3n] }), [], gas("1"), policy(), new Map());
  assert.equal(dry.calls.length, 1);
  assert.equal(dry.calls[0].dryOnly, true);
  assert.deepEqual(dry.calls[0].args, [3n]);
  const live = decide(state({ atFloor: [3n], balanceModule: "0x00000000000000000000000000000000000000b0" }), [], gas("1"), policy(), new Map());
  assert.equal(live.calls[0].dryOnly, undefined);
  const off = decide(state({ atFloor: [3n], balanceModule: "0x00000000000000000000000000000000000000b0", settings: { ...state().settings, redeemOn: false } }), [], gas("1"), policy(), new Map());
  assert.match(reason(off, "redeemStatement"), /RedeemOff/);
});

// ------------------------------------------------------------------ book and escrow

test("book: only when the window is over, the payee share is not latched and income is pending", () => {
  const base = { payeeOn: false, launchedAt: 1_000n, sniperSeconds: 1_800n, pendingIncome: 1n };
  assert.equal(bookLatches(state({ ...base, timestamp: 2_799n })).ok, false);
  assert.equal(bookLatches(state({ ...base, timestamp: 2_800n })).ok, true);
  assert.match(bookLatches(state({ ...base, timestamp: 2_800n, pendingIncome: 0n })).reason, /no unbooked income/);
  assert.match(bookLatches(state({ ...base, timestamp: 2_800n, payeeOn: true })).reason, /already latched/);
  assert.match(bookLatches(state({ ...base, timestamp: 2_800n, launchedAt: 0n })).reason, /not recorded/);
  assert.deepEqual(doorsOf(decide(state({ ...base, timestamp: 2_800n }), [], gas("1"), policy(), new Map())), ["book"]);
});

test("escrow: collected when it holds more than the gas that moves it", () => {
  const cost = GAS_GUESS.collectEscrow * (worstBaseFee(gas("1"), policy().doors.collectEscrow) + parseGwei("0.05"));
  assert.deepEqual(doorsOf(decide(state({ escrowBalance: cost }), [], gas("1"), policy(), new Map())), ["collectEscrow"]);
  const small = decide(state({ escrowBalance: cost - 1n }), [], gas("1"), policy(), new Map());
  assert.match(reason(small, "collectEscrow"), /under the gas cost/);
});

// ------------------------------------------------------------------ recheck at the simulated gas

test("recheck: a paid door that measured more gas than its guess is rechecked at the measure", () => {
  const s = state({ ethToBuyback: parseEther("1") });
  const p = policy();
  const c = decide(s, [], gas("1"), p, new Map()).calls[0];
  assert.equal(recheck(c, s, undefined, 270_000n, gas("1"), p).ok, true);
  // gas above BUYBACK_GAS is not refunded: at 2,000,000 gas the payment stops at 600,000 gas
  assert.equal(recheck(c, s, undefined, 2_000_000n, gas("1"), p).ok, false);
});

test("doors off by config are never decided", () => {
  const p = { ...policy(), doorsOn: new Set<Door>(["book"]) };
  assert.deepEqual(doorsOf(decide(state({ ethToBuyback: parseEther("1"), pageReady: true }), [listing()], gas("1"), p, new Map())), []);
});
