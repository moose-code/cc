import assert from "node:assert/strict";
import { test } from "node:test";
import { allPassed, pageMatches } from "./reconcile.ts";

// promise: the indexed pile order is compared with the on-chain page position by position
test("pageMatches compares order", () => {
  assert.ok(pageMatches([1n, 2n, 3n], [1n, 2n, 3n]));
  assert.ok(!pageMatches([1n, 2n, 3n], [1n, 3n, 2n]));
  assert.ok(!pageMatches([1n, 2n], [1n, 2n, 3n]));
});

test("allPassed fails on any false check", () => {
  assert.ok(allPassed({ pileSize: true, heldStatements: true, pileFirstPage: true, ethPot: true }));
  assert.ok(!allPassed({ pileSize: true, heldStatements: false, pileFirstPage: true, ethPot: true }));
});
