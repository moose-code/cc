// promise: Credits compare their live sale price with rating-adjusted nearby asks from both venues, never expired or duplicate asks.
import assert from "node:assert/strict";
import { compareMarketValue, marketAsks, marketFloor } from "../lib/credit-market-floor.ts";
import type { View } from "../lib/listings-api.ts";

const view = {
  status: { source: "api" },
  rows: [
    { id: "1", price: "100", score: "1000000", endTime: 200, hash: "", signed: false },
    { id: "2", price: "50", score: "1000000", endTime: 90, hash: "", signed: false },
    { id: "3", price: "1", score: "1300000", endTime: 200, hash: "", signed: false },
  ],
  strategy: { publishedAt: 100, rows: [
    { id: "1", price: "80", score: "1000000" },
    { id: "4", price: "90", score: "1100000" },
  ] },
} as View;
const asks = marketAsks(view, 100);
assert.equal(asks.length, 3, "expired ask omitted and duplicate Credit uses its lower venue ask");
assert.equal(marketFloor("5", 1_000_000n, asks), 80n);
assert.equal(marketFloor("1", 1_000_000n, asks), 81n, "the Credit itself cannot set its comparable floor");
assert.equal(marketFloor("5", 800_000n, asks), 64n, "reference ask scales to the target rating");
assert.equal(marketFloor("5", 100_000n, asks), undefined, "no nearby rating means no floor or highlight");
assert.ok(79n < marketFloor("5", 1_000_000n, asks)!);
assert.ok(!(80n < marketFloor("5", 1_000_000n, asks)!));
assert.equal(marketAsks({ ...view, status: { source: "off" } } as View, 100).length, 2, "off OpenSea does not contribute asks");
assert.equal(marketAsks({ ...view, strategy: { ...view.strategy, publishedAt: 0 } } as View, 100).length, 2, "unpublished Strategy does not contribute asks");
assert.equal(marketAsks(view, 100, { openSea: false, strategy: true }).length, 2, "healthy Strategy asks remain when OpenSea cannot be used");
assert.equal(marketAsks(view, 100, { openSea: false, strategy: false }).length, 0, "unhealthy venues provide no comparison");
assert.ok(compareMarketValue({ price: 80n, floor: 100n }, { price: 90n, floor: 100n }) < 0, "a below-market Credit sorts first");
assert.ok(compareMarketValue({ price: 80n, floor: 100n }, { price: 70n, floor: 80n }) < 0, "value uses rating-adjusted price ratio, not absolute price");
assert.equal(compareMarketValue({ price: 0n, floor: 100n }, { price: 0n, floor: 100n }), 0, "unavailable quotes keep their order");
console.log("credit market floor selfcheck passed");
