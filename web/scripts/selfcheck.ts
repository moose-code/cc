// Runnable check for the sell replays. No chain needed.
//   npm run check
import assert from "node:assert/strict";
import { replayBalance, replayEth, type EthReplay } from "../lib/sell.ts";

const a: EthReplay = {
  price: 1000n,
  peak: 1000n,
  pot: 10_000n,
  start: 0n,
  bucket: 0n,
  nowBucket: 7n,
  dropPerCreditBps: 50n,
  dropFloorBps: 5000n,
  ceilBps: 10000n,
  rateCap: 10n ** 18n,
  refScore: 1000n,
};

// credits of score refScore (score / refScore is 1): each pays the full rate and drops the rate by dropPerCreditBps
const ref = (k: number): bigint[] => Array<bigint>(k).fill(a.refScore);

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
// per point: a credit of score 2 * refScore pays twice the rate and drops it twice as far (1 percent)
assert.equal(replayEth([2000n], a), 2000n);
assert.equal(replayEth([2000n, 1000n], a), 2000n + 990n);
// balance: score * unit less the margin, per credit
assert.equal(replayBalance([3n, 5n], 1000n, 100n), 2970n + 4950n);

console.log("selfcheck ok");
