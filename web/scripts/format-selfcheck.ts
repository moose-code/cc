// Runnable check for the per-point price display. No chain needed.
//   node --experimental-strip-types scripts/format-selfcheck.ts
import assert from "node:assert/strict";
import { ethPerPointPrice, subscriptZeros } from "../lib/price-format.ts";

// promise: the header bid per point is readable at real bid sizes, never "<0.01"
assert.equal(ethPerPointPrice(4_507_972_118_932_936n / 100n), "0.0₄450");
assert.equal(ethPerPointPrice(4_510_000_000_000_000n), "0.00451");
assert.equal(ethPerPointPrice(25_000_000_000_000_000n), "0.03");
assert.equal(ethPerPointPrice(0n), "0");
// the shared subscript helper keeps the USD price digits ($0.0₄983)
assert.equal(subscriptZeros(0.0000983), "0.0₄983");
console.log("format selfcheck ok");
