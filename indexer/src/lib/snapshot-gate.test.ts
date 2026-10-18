import assert from "node:assert/strict";
import { test } from "node:test";
import { snapshotOnce } from "./snapshot-gate.ts";

// promise: a failed indexer read cannot mark a block complete, so retry writes its snapshot
test("snapshot retries after a transient read failure", async () => {
  const rows = new Map<bigint, number>();
  let attempts = 0;
  const find = async (n: bigint) => rows.get(n);
  const write = async () => {
    attempts += 1;
    if (attempts === 1) throw new Error("RPC unavailable");
    rows.set(42n, attempts);
  };
  await assert.rejects(snapshotOnce(42n, find, write), /RPC unavailable/);
  await snapshotOnce(42n, find, write);
  assert.equal(rows.get(42n), 2);
  await snapshotOnce(42n, find, write);
  assert.equal(attempts, 2, "a persisted snapshot avoids a duplicate read");
});

// promise: a rolled-back snapshot at the same height is rebuilt for the replacement canonical block
test("snapshot replays after a same-height rollback", async () => {
  const rows = new Map<bigint, string>();
  const find = async (n: bigint) => rows.get(n);
  let canonical = "orphan";
  const write = async () => { rows.set(42n, canonical); };
  await snapshotOnce(42n, find, write);
  assert.equal(rows.get(42n), "orphan");
  rows.delete(42n); // Ponder rolled back the orphaned block's DB writes.
  canonical = "replacement";
  await snapshotOnce(42n, find, write);
  assert.equal(rows.get(42n), "replacement");
});
