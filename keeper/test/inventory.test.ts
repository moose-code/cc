// promise: the strategy inventory follows the Credits transfers to and from the strategy without reading the held set
// again, re-reads the price of every credit that moved or sits in the rolling slice, replaces the newest blocks after
// a reorg, resumes from its file after a restart, and falls back to a full read once a day
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { indexerSeed, StrategyBook, type BookChain, type Move } from "../src/inventory.ts";
import { setSink } from "../src/log.ts";

setSink(() => {});

// a chain of transfers and prices with counters for the reads
function fake(held: bigint[], prices: { [id: string]: bigint }, head = 1000n) {
  const f = {
    head,
    held: new Set(held),
    prices: new Map(Object.entries(prices).map(([k, v]) => [BigInt(k), v])),
    moves: [] as Move[],
    heldReads: 0,
    priceReads: [] as bigint[][],
    seeded: undefined as { block: bigint; ids: bigint[] } | undefined,
    chain: undefined as unknown as BookChain,
    move(block: bigint, id: bigint, into: boolean, price?: bigint) {
      f.moves.push({ block, index: f.moves.length, id, into });
      if (into) {
        f.held.add(id);
        if (price !== undefined) f.prices.set(id, price);
      } else f.held.delete(id);
    },
  };
  f.chain = {
    head: async () => f.head,
    moves: async (from, to) => f.moves.filter((m) => m.block >= from && m.block <= to),
    held: async () => {
      f.heldReads++;
      return [...f.held];
    },
    prices: async (ids) => {
      f.priceReads.push(ids);
      return ids.map((id) => (f.held.has(id) ? (f.prices.get(id) ?? 0n) : 0n));
    },
    seed: async () => f.seeded,
  };
  return f;
}
const dir = () => join(mkdtempSync(join(tmpdir(), "keeper-inv-")), "strategy-inventory.json");
const listed = (m: Map<bigint, bigint>) => [...m].sort((a, b) => Number(a[0] - b[0])).map(([id, p]) => `${id}:${p}`);

test("transfers in, out and a re-listing change the listed set; a refresh without moves reads only the slice", async () => {
  const f = fake([1n, 2n, 3n], { 1: 10n, 2: 20n, 3: 0n });
  const b = new StrategyBook(f.chain, { key: "k", slice: 2 });
  assert.deepEqual(listed(await b.refresh()), ["1:10", "2:20"]);
  assert.equal(f.heldReads, 1);

  f.head = 1010n;
  f.move(1005n, 4n, true, 40n); // received and listed
  f.move(1006n, 2n, false); // sold
  f.move(1007n, 3n, false);
  f.move(1008n, 3n, true, 33n); // sent out and received again at a price
  f.priceReads.length = 0;
  assert.deepEqual(listed(await b.refresh()), ["1:10", "3:33", "4:40"]);
  assert.equal(f.heldReads, 1, "no second read of the held set");
  const read = new Set(f.priceReads.flat());
  for (const id of [3n, 4n]) assert.ok(read.has(id), `moved id ${id} priced again`);
  assert.ok(!read.has(2n), "a sold credit is not read");
  assert.ok(f.priceReads.flat().length <= 4, "moved ids plus a slice of 2");
});

test("a price change without an event is picked up when the rolling slice reaches the id", async () => {
  const ids = Array.from({ length: 10 }, (_, i) => BigInt(i + 1));
  const f = fake(ids, Object.fromEntries(ids.map((id) => [id.toString(), 100n])));
  const b = new StrategyBook(f.chain, { key: "k", slice: 3 });
  await b.refresh();
  f.prices.set(9n, 50n);
  let seen = 0;
  for (; seen < 4; seen++) {
    f.head += 1n;
    if ((await b.refresh()).get(9n) === 50n) break;
  }
  assert.ok(seen < 4, "reconciled within ceil(10 / 3) refreshes");
  assert.equal(f.heldReads, 1);
});

test("a reorg of the newest blocks replaces their moves", async () => {
  const f = fake([1n], { 1: 10n });
  const b = new StrategyBook(f.chain, { key: "k", slice: 1 });
  await b.refresh();
  f.head = 1005n;
  f.move(1004n, 2n, true, 20n);
  assert.deepEqual(listed(await b.refresh()), ["1:10", "2:20"]);
  // the block that held the transfer is replaced by one without it
  f.moves = [];
  f.held.delete(2n);
  f.head = 1006n;
  assert.deepEqual(listed(await b.refresh()), ["1:10"]);
  // a transfer that has aged past the reorg window stays applied
  f.head = 1020n;
  f.move(1019n, 3n, true, 30n);
  f.head = 1040n;
  assert.deepEqual(listed(await b.refresh()), ["1:10", "3:30"]);
  f.head = 1041n;
  assert.deepEqual(listed(await b.refresh()), ["1:10", "3:30"]);
});

test("a restart resumes from the state file without reading the held set", async () => {
  const file = dir();
  const f = fake([1n, 2n], { 1: 10n, 2: 20n });
  await new StrategyBook(f.chain, { key: "k", file }).refresh();
  f.head = 1020n;
  f.move(1015n, 3n, true, 30n);
  const again = new StrategyBook(f.chain, { key: "k", file });
  assert.deepEqual(listed(await again.refresh()), ["1:10", "2:20", "3:30"]);
  assert.equal(f.heldReads, 1);
  // a file under another key is discarded
  const other = new StrategyBook(f.chain, { key: "other", file });
  await other.refresh();
  assert.equal(f.heldReads, 2);
});

test("the held set is read in full once a day and when the full read flag is set", async () => {
  let now = 0;
  const f = fake([1n], { 1: 10n });
  const b = new StrategyBook(f.chain, { key: "k", now: () => now });
  await b.refresh();
  now = 3_600_000;
  await b.refresh();
  assert.equal(f.heldReads, 1);
  now = 86_400_000 + 1;
  await b.refresh();
  assert.equal(f.heldReads, 2);
  const forced = new StrategyBook(f.chain, { key: "k", fullRead: true });
  await forced.refresh();
  await forced.refresh();
  assert.equal(f.heldReads, 4);
});

test("a failed delta falls back to a full read; a failed price read keeps the last price", async () => {
  const f = fake([1n, 2n], { 1: 10n, 2: 20n });
  const b = new StrategyBook(f.chain, { key: "k", slice: 5 });
  await b.refresh();
  const prices = f.chain.prices;
  f.chain.prices = async (ids) => ids.map((id) => (id === 2n ? undefined : 11n));
  f.head += 1n;
  assert.deepEqual(listed(await b.refresh()), ["1:11", "2:20"]);
  f.chain.prices = prices;
  const moves = f.chain.moves;
  f.chain.moves = async () => {
    throw new Error("range too large");
  };
  f.head += 1n;
  await b.refresh();
  assert.equal(f.heldReads, 2);
  f.chain.moves = moves;
});

test("the first start seeds from the indexer and replays the transfers after its block", async () => {
  const f = fake([1n, 2n, 5n], { 1: 10n, 2: 20n, 5: 50n }, 1100n);
  f.seeded = { block: 1000n, ids: [1n, 2n] }; // the indexer is behind: credit 5 arrived after its block
  f.move(1050n, 5n, true, 50n);
  const b = new StrategyBook(f.chain, { key: "k" });
  assert.deepEqual(listed(await b.refresh()), ["1:10", "2:20", "5:50"]);
  assert.equal(f.heldReads, 0);
});

test("indexerSeed pages the active listings and reports the indexed block", async () => {
  const pages = [
    { items: [{ id: "1" }, { id: "2" }], pageInfo: { hasNextPage: true, endCursor: "c1" } },
    { items: [{ id: "7" }], pageInfo: { hasNextPage: false, endCursor: null } },
  ];
  const seen: unknown[] = [];
  const fetchFn = (async (_u: string, init: { body: string }) => {
    const { variables } = JSON.parse(init.body);
    seen.push(variables.after);
    const first = variables.after === null;
    return new Response(JSON.stringify({ data: { _meta: { status: { mainnet: { block: { number: 1234 } } } }, strategyListings: pages[first ? 0 : 1] } }));
  }) as unknown as typeof fetch;
  const s = await indexerSeed("http://127.0.0.1:1/graphql", fetchFn);
  assert.deepEqual(s, { block: 1234n, ids: [1n, 2n, 7n] });
  assert.deepEqual(seen, [null, "c1"]);
  await assert.rejects(indexerSeed("http://127.0.0.1:1/graphql", (async () => new Response("{}", { status: 500 })) as unknown as typeof fetch));
});
