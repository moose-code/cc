// Runnable check for the sell replays. No chain needed.
//   npm run check
import assert from "node:assert/strict";
import { replayBalance, replayBalanceFills, replayEth, replayEthFills, type EthReplay } from "../lib/sell.ts";

const a: EthReplay = {
  price: 1000n,
  peak: 1000n,
  pot: 10_000n,
  start: 0n,
  bucket: 0n,
  nowBucket: 7n,
  dropPer100PointsBps: 50n,
  dropFloorBps: 5000n,
  ceilBps: 10000n,
  rateCap: 10n ** 18n,
  scorePer100Points: 1000n,
};

// credits of score scorePer100Points (score / scorePer100Points is 1): each pays the full rate and drops the rate by dropPer100PointsBps
const ref = (k: number): bigint[] => Array<bigint>(k).fill(a.scorePer100Points);

assert.equal(replayEth(ref(0), a), 0n);
assert.equal(replayEth(ref(1), a), 1000n);
// the second credit pays the state after one 0.5% drop
assert.equal(replayEth(ref(2), a), 1000n + 995n);
// the pot bounds the total
assert.equal(replayEth(ref(50), { ...a, pot: 2500n }), 2500n);
// the state never falls under dropFloorBps of the minute's first fill
assert.ok(replayEth(ref(200), { ...a, pot: 10n ** 9n }) >= 500n * 200n);
// a fill earlier in the same minute holds the floor at that minute's start
assert.equal(replayEth(ref(2), { ...a, bucket: 7n, start: 1000n, dropFloorBps: 9990n }), 1000n + 999n);
// the ceiling caps the state after a fill
assert.equal(replayEth(ref(2), { ...a, ceilBps: 9000n }), 1000n + 900n);
// the rate cap bounds the state after a fill
assert.equal(replayEth(ref(2), { ...a, rateCap: 800n }), 1000n + 800n);
// per point: a credit of score 2 * scorePer100Points pays twice the rate and drops it twice as far (1 percent)
assert.equal(replayEth([2000n], a), 2000n);
assert.equal(replayEth([2000n, 1000n], a), 2000n + 990n);
// the sell page lists each credit's fill: the fills are in sell order and add up to the total
assert.deepEqual(replayEthFills([2000n, 1000n], a), [2000n, 990n]);
assert.deepEqual(replayEthFills(ref(50), { ...a, pot: 2500n }).reduce((t, x) => t + x, 0n), replayEth(ref(50), { ...a, pot: 2500n }));
// balance: score * unit * rate / 10000 per credit, the rate dropped per credit by dropPer100PointsBps * score / scorePer100Points
// in one rounding, never below the floor
const b = { rate: 10000n, unit: 100n, scorePer100Points: 10n, dropPer100PointsBps: 50n, dropFloorBps: 5000n, floorBps: 9000n };
// at par: 300, then the rate is 10000 * (100000 - 150) / 100000 = 9985 and the second credit pays 5 * 100 * 9985 / 10000
assert.equal(replayBalance([3n, 5n], b), 300n + 499n);
assert.deepEqual(replayBalanceFills([3n, 5n], b), [300n, 499n]);
// at the floor the drop cannot lower the rate: 270 then 450
assert.equal(replayBalance([3n, 5n], { ...b, rate: 9000n }), 270n + 450n);

console.log("selfcheck ok");

// ---- header acquire selection (lib/acquire.ts) ----
import { bucketCount, cheapestPerId, clearing, fitsBucket, shortlist, type Listing, type Priced, type SpendRoom } from "../lib/acquire.ts";

const L = (id: number, price: bigint, source: "strategy" | "opensea" = "strategy"): Listing => ({ id: BigInt(id), price, source, params: "0x" });
const P = (id: number, price: bigint, bid: bigint): Priced => ({ ...L(id, price), bid });

// nothing clears when every price is above its bid
assert.deepEqual(clearing([P(1, 110n, 100n), P(2, 101n, 100n)], 1000n, false), []);
// price equal to the bid clears; the pot bounds the price
assert.equal(clearing([P(1, 100n, 100n)], 100n, false).length, 1);
assert.equal(clearing([P(1, 100n, 100n)], 99n, false).length, 0);
// the largest bid minus price comes first (ids 2, 3 and 4 tie at 50); equal margins take the lower price
assert.deepEqual(clearing([P(1, 90n, 100n), P(2, 50n, 100n), P(3, 150n, 200n), P(4, 40n, 90n)], 1000n, false).map((l) => Number(l.id)), [4, 2, 3, 1]);
// a retired Core clears nothing; a zero price is not a listing
assert.equal(clearing([P(1, 50n, 100n)], 1000n, true).length, 0);
assert.equal(clearing([P(1, 0n, 100n)], 1000n, false).length, 0);
// spend cap: the first purchase of a bucket passes; later ones need spent + cost <= budget; uncapped always passes
const room = (spent: bigint): SpendRoom => ({ capped: true, budget: 100n, spent, nextIn: 30 });
assert.equal(fitsBucket(room(0n), 500n), true);
assert.equal(fitsBucket(room(60n), 40n), true);
assert.equal(fitsBucket(room(60n), 41n), false);
assert.equal(fitsBucket({ ...room(60n), capped: false }, 500n), true);
// greedy cheapest first: 20, 30 and 40 total 90
assert.equal(bucketCount(room(0n), [40n, 30n, 20n]), 3);
assert.equal(bucketCount(room(0n), [60n, 50n, 20n]), 2);
assert.equal(bucketCount(room(90n), [20n]), 0);
// a credit listed twice keeps its lower price
assert.deepEqual(cheapestPerId([L(1, 90n), L(1, 80n, "opensea"), L(2, 5n)]).map((l) => [Number(l.id), l.price, l.source]), [[1, 80n, "opensea"], [2, 5n, "strategy"]]);
// shortlist: estimated bid = rate * score / scorePer100Points; ids without a score are skipped; n bounds the result
const scores = new Map([[1n, 2000n], [2n, 1000n], [3n, 1000n]]);
assert.deepEqual(shortlist([L(1, 150n), L(2, 90n), L(3, 120n), L(4, 1n)], 100n, 1000n, scores, 2).map((l) => Number(l.id)), [1, 2]);
assert.equal(shortlist([L(1, 1n)], 100n, 0n, scores, 5).length, 0);
// a pricier high-rated listing beats cheap low-rated ones: rate 100, scorePer100Points 1000, id 9 scores 8000 (bid 800, price 500, margin 300), ids 1..8 score 1000 (bid 100)
const many = new Map<bigint, bigint>([[9n, 8000n], ...[1n, 2n, 3n, 4n, 5n, 6n, 7n, 8n].map((i): [bigint, bigint] => [i, 1000n])]);
const cheapLow = [1, 2, 3, 4, 5, 6, 7, 8].map((i) => L(i, BigInt(10 * i)));
assert.deepEqual(shortlist([...cheapLow, L(9, 500n, "opensea")], 100n, 1000n, many, 1).map((l) => Number(l.id)), [9]);

// ---- eth bid forecast (lib/climb.ts, mirror of CoreLib._climb / _recover) ----
import { bidAt, clearsIn, nextRise, priceAt, rateAt, type ClimbState } from "../lib/climb.ts";

const E = 10n ** 18n;
const cs: ClimbState = {
  r: 1n * E,
  t: 1000,
  anchorTime: 1000,
  lastFillRate: 1n * E,
  peakRate: 1n * E,
  peakTime: 1000,
  ceilBps: 11000,
  idleLoosenBps: 100,
  idleStepSeconds: 600,
  climbMultiplierBps: 10_000,
  rateCap: 100n * E,
  peakHalfLife: 3600,
  climbPerMinBps: 100,
  recoveryClimbPerMinBps: 300,
  recoveryGapBps: 1000,
  ethPot: 50n * E,
  pending: 0n,
};
const close = (a: number, b: number, tol = 1e-9) => assert.ok(Math.abs(a - b) <= tol * Math.abs(b), `${a} vs ${b}`);
// no time elapsed: the stored rate
close(priceAt(cs, 1000), 1e18);
// at the peak (above the recovery level) the slow climb compounds climbPerMinBps a minute: 1% in 60 s
close(priceAt(cs, 1060), 1.01e18);
// ten minutes: 1.01^10, under the ceiling (1.1 + idle loosening of 1%)
close(priceAt(cs, 1600), 1e18 * Math.pow(1.01, 10));
// the ceiling clamps the climb: ceilBps 11000 of the anchor, 1.1 plus one idle step of 1% after 10 minutes
close(priceAt(cs, 1000 + 86_400), Math.min(100e18, 50e18, 1e18 * 1.1 * (1 + 0.01 * 144)));
// a rate far under the decaying peak climbs at recoveryClimbPerMinBps (3% a minute) up to the recovery level
const rec: ClimbState = { ...cs, r: E / 2n, peakRate: 4n * E, lastFillRate: E / 2n };
close(priceAt(rec, 1060), 0.5e18 * 1.03);
// the pot bounds the read: a pot under the price state reads at the pot
assert.equal(rateAt({ ...cs, ethPot: E / 2n }, 1000), E / 2n > 0n ? 5e17 : 0);
// bidAt scales by score over scorePer100Points
close(bidAt(cs, 1000, 2000n, 1000n), 2e18);
// clearsIn: now, a reachable price (bisected time lands on the price), a price above the pot, a price above the cap
assert.deepEqual(clearsIn(cs, 1n * E, 1000n, 1000n, 1000), { kind: "now" });
const hit = clearsIn(cs, 1_050_000_000_000_000_000n, 1000n, 1000n, 1000);
assert.equal(hit.kind, "in");
if (hit.kind === "in") {
  close(bidAt(cs, 1000 + hit.seconds, 1000n, 1000n), 1.05e18, 1e-6);
  assert.ok(bidAt(cs, 1000 + hit.seconds - 120, 1000n, 1000n) < 1.05e18);
}
assert.deepEqual(clearsIn(cs, 60n * E, 1000n, 1000n, 1000), { kind: "pot" });
assert.deepEqual(clearsIn({ ...cs, ethPot: 500n * E }, 200n * E, 1000n, 1000n, 1000), { kind: "cap" });
// a higher rated credit reaches the same price sooner
const slow = clearsIn(cs, 3n * E, 1000n, 1000n, 1000);
const fast = clearsIn(cs, 3n * E, 2000n, 1000n, 1000);
assert.ok(slow.kind === "in" && fast.kind === "in" && fast.seconds < slow.seconds);
// the multiplier scales the loosening step and idleStepSeconds sets its length: 2.5x of 1% per 300 s is 2.5% a step (integer division as in the contract)
close(priceAt({ ...cs, climbMultiplierBps: 25_000, idleStepSeconds: 300 }, 1000 + 86_400), Math.min(100e18, 50e18, 1e18 * 1.1 * (1 + 0.025 * 288)));
// nextRise: below the ceiling the rate 60 s ahead and the seconds to the next minute of the chain clock
const up = nextRise(cs, 1010);
assert.ok(up.kind === "climb" && up.seconds === 10);
if (up.kind === "climb") close(up.rate, rateAt(cs, 1070));
// at the ceiling: the next idle step counted from anchorTime, the ceiling after it, the multiplier carried
const top = { ...cs, r: 100n * E, climbMultiplierBps: 24_000 };
const ev = nextRise(top, 1000 + 86_400 + 5);
assert.ok(ev.kind === "ceiling" && ev.seconds === 595 && ev.multiplier === 2.4);
if (ev.kind === "ceiling") close(ev.rate, Math.min(100e18, 50e18, 1e18 * 1.1 * (1 + 0.024 * 145)), 1e-9);
// at rateCap and at the pot
assert.equal(nextRise({ ...top, rateCap: 11n * E / 10n }, 1000 + 86_400).kind, "cap");
assert.equal(nextRise({ ...cs, ethPot: E / 2n }, 1000).kind, "pot");
console.log("climb selfcheck ok");
