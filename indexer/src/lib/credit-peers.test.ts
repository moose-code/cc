// promise: bounded Credit hydration uses actual same-block peers without changing ordered ownership or trusting stale logs.
import assert from "node:assert/strict";
import test from "node:test";
import { CREDIT_TRANSFER_TOPIC, hydrateCreditPeers } from "./credit-peers.ts";

const address = "0x" + "11".repeat(20);
const blockHash = "0x" + "22".repeat(32);
const expected = { address, blockHash };
const topic = (id: bigint) => "0x" + id.toString(16).padStart(64, "0");
const log = (id: bigint) => ({ address, blockHash, topics: [CREDIT_TRANSFER_TOPIC, topic(0n), topic(1n), topic(id)] });

test("hydrates only the current noncontiguous peer group, deduplicated and bounded to 64", async () => {
  const ids = Array.from({ length: 150 }, (_, i) => BigInt(i * 3));
  const logs = ids.flatMap((id) => [log(id), log(id)]);
  const calls: bigint[][] = [];
  await hydrateCreditPeers(logs, ids[70], expected, async (peers) => { calls.push([...peers]); });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].length, 64);
  assert.equal(new Set(calls[0]).size, 64);
  assert.ok(calls[0].includes(ids[70]));
  assert.ok(calls[0].every((id) => ids.includes(id)));
  assert.ok(!calls[0].includes(ids[0]) && !calls[0].includes(ids[149]));
});

test("single-token and short final groups retain zero and repeated IDs", async () => {
  const ids = Array.from({ length: 65 }, (_, i) => BigInt(i));
  const calls: bigint[][] = [];
  await hydrateCreditPeers([log(0n), log(0n)], 0n, expected, async (peers) => { calls.push([...peers]); });
  await hydrateCreditPeers(ids.map(log), 64n, expected, async (peers) => { calls.push([...peers]); });
  assert.deepEqual(calls, [[0n], [64n]]);
});

test("validates all logs and current ID before any hydration", async () => {
  let calls = 0;
  const hydrate = async () => { calls++; };
  for (const invalid of [null, { ...log(1n), address: "0x" + "33".repeat(20) },
    { ...log(1n), blockHash: "0x" + "44".repeat(32) },
    { ...log(1n), topics: [topic(1n), topic(0n), topic(0n), topic(1n)] },
    { ...log(1n), topics: [CREDIT_TRANSFER_TOPIC, topic(0n), topic(0n), "0x1"] }]) {
    await assert.rejects(hydrateCreditPeers([log(1n), invalid], 1n, expected, hydrate), /do not match/);
  }
  await assert.rejects(hydrateCreditPeers([log(2n)], 1n, expected, hydrate), /missing/);
  assert.equal(calls, 0);
});

test("failed or rolled-back hydration is retried; replacement block logs cannot reuse orphan peers", async () => {
  const calls: bigint[][] = [];
  let attempts = 0;
  const hydrate = async (peers: readonly bigint[]) => {
    calls.push([...peers]);
    if (++attempts === 1) throw new Error("RPC unavailable");
  };
  await assert.rejects(hydrateCreditPeers([log(1n), log(2n)], 1n, expected, hydrate), /RPC unavailable/);
  await hydrateCreditPeers([log(1n), log(2n)], 1n, expected, hydrate);
  const replacement = { address, blockHash: "0x" + "55".repeat(32) };
  await assert.rejects(hydrateCreditPeers([log(1n), log(2n)], 1n, replacement, hydrate), /do not match/);
  await hydrateCreditPeers([1n, 9n].map((id) => ({ ...log(id), blockHash: replacement.blockHash })), 1n, replacement, hydrate);
  assert.deepEqual(calls, [[1n, 2n], [1n, 2n], [1n, 9n]]);
});
