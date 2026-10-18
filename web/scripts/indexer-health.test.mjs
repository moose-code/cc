// promise: the website never serves another Core's indexed history, even when both piles are empty.
import assert from "node:assert/strict";
import { test } from "node:test";
import { indexedBlockForChain, matchesIndexerIdentity } from "../lib/indexer-health.ts";

const core = "0x1111111111111111111111111111111111111111";
const coin = "0x2222222222222222222222222222222222222222";
const row = { core, coin, deployBlock: 123n };

test("indexer mode requires the exact Core, coin and deploy block", () => {
  assert.equal(indexedBlockForChain({ other: { id: 31337, block: { number: 200 } } }, 1), undefined);
  assert.equal(indexedBlockForChain({ mainnet: { id: 1, block: { number: 200 } } }, 1), 200);
  assert.equal(matchesIndexerIdentity(core, coin, 123n, row), true);
  assert.equal(matchesIndexerIdentity(core.toUpperCase(), coin.toUpperCase(), 123n, row), true);
  assert.equal(matchesIndexerIdentity(core, coin, 123n, { ...row, core: coin }), false);
  assert.equal(matchesIndexerIdentity(core, coin, 123n, { ...row, coin: core }), false);
  assert.equal(matchesIndexerIdentity(core, coin, 123n, { ...row, deployBlock: 124n }), false);
  assert.equal(matchesIndexerIdentity(core, coin, 123n, undefined), false);
  assert.equal(matchesIndexerIdentity(core, undefined, 123n, row), false);
  assert.equal(matchesIndexerIdentity(core, coin, undefined, row), false);
});
