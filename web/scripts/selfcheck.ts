// Runnable check for the sell estimate. No chain needed.
//   npm run check
import assert from "node:assert/strict";
import { estimateSell } from "../lib/sell.ts";

const s = { ethRate: 1000n, ethPrice: 1000n, ethPot: 10_000n, dropPerCreditBps: 50, dropFloorBps: 5000 };

assert.equal(estimateSell(0, s), 0n);
assert.equal(estimateSell(1, s), 1000n);
// the second credit pays the rate after one 0.5% drop
assert.equal(estimateSell(2, s), 1000n + 995n);
// the pot bounds the total
assert.equal(estimateSell(50, { ...s, ethPot: 2500n }), 2500n);
// the rate never falls under dropFloorBps of the first fill
assert.ok(estimateSell(200, { ...s, ethPot: 10n ** 9n }) >= 500n * 200n);
// an ethRate above ethPot (unbooked fees) lifts the pot to the rate
assert.equal(estimateSell(1, { ...s, ethPot: 400n, ethRate: 1000n }), 1000n);

console.log("selfcheck ok");
