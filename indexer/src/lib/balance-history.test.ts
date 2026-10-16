import assert from "node:assert/strict";
import { test } from "node:test";
import { addTokenPayment } from "./balance-history.ts";

// promise: token replacement never adds different currencies or decimal scales together.
test("payout totals retain A18 and B6 separately when A is selected again", () => {
  const a = "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
  const b = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  const first = addTokenPayment({}, a, 10n ** 18n);
  const switched = addTokenPayment(first, b, 10n ** 6n);
  const returned = addTokenPayment(switched, a.toLowerCase(), 2n * 10n ** 18n);
  assert.deepEqual(returned, { [a.toLowerCase()]: "3000000000000000000", [b]: "1000000" });
  assert.deepEqual(first, { [a.toLowerCase()]: "1000000000000000000" });
});

// promise: payout counters stay exact beyond JavaScript's numeric range.
test("raw payout totals preserve every base unit", () => {
  const a = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  assert.equal(addTokenPayment({ [a]: "100000000000000000000000001" }, a, 1n)[a], "100000000000000000000000002");
});
