// Runnable check for the credits sort orders (web/lib/credit-sort.ts). No chain needed.
//   npm run check
import assert from "node:assert/strict";
import { DEFAULT_SORT, nextSort, sortDef, sortRows, type SortRow } from "../lib/credit-sort.ts";

const row = (id: number, o: Partial<SortRow>): SortRow => ({ id, index: id, price: 100n, cost: 50n, acquiredAt: id, score: 6_000_000n, ...o });

// promise: best value leads by default, the price lowest against its band's median first
{
  assert.equal(DEFAULT_SORT, "value");
  const rows = [row(1, { price: 120n, median: 100n }), row(2, { price: 90n, median: 100n }), row(3, { price: 200n, median: 190n })];
  assert.deepEqual(sortRows(rows, "value", sortDef("value").dir).map((r) => r.id), [2, 3, 1]);
}

// promise: a value not known yet (a price not read, a band without sales) sorts last in either direction
{
  const rows = [row(1, { price: 0n }), row(2, { price: 300n }), row(3, { price: 100n })];
  assert.deepEqual(sortRows(rows, "price", 1).map((r) => r.id), [3, 2, 1]);
  assert.deepEqual(sortRows(rows, "price", -1).map((r) => r.id), [2, 3, 1]);
  assert.deepEqual(sortRows([row(1, { median: undefined }), row(2, { median: 100n })], "value", 1).map((r) => r.id), [2, 1]);
}

// promise: price per point ranks across ratings, and composing soon follows the queue
{
  const rows = [row(1, { price: 100n, score: 4_000_000n }), row(2, { price: 120n, score: 6_000_000n })];
  assert.deepEqual(sortRows(rows, "ppp", 1).map((r) => r.id), [2, 1]);
  assert.deepEqual(sortRows([row(1, { index: 5 }), row(2, { index: 0 })], "composing", 1).map((r) => r.id), [2, 1]);
}

// promise: a header click flips the current key's direction and starts another key in its own direction
{
  assert.deepEqual(nextSort({ key: "price", dir: 1 }, "price"), { key: "price", dir: -1 });
  assert.deepEqual(nextSort({ key: "price", dir: -1 }, "rating"), { key: "rating", dir: -1 });
}

console.log("credit sort selfcheck ok");
