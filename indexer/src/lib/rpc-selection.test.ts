// promise: a chain-id-1 fork reads only its explicitly pinned loopback RPC; live chain 1 keeps public fallback.
import { test } from "node:test";
import assert from "node:assert/strict";
import { localRpc } from "./rpc-selection.ts";

test("chain-id-1 fork requires an explicit RPC matching its record", () => {
  const fork = "http://127.0.0.1:8627";
  assert.equal(localRpc(1, fork, fork), fork);
  assert.throws(() => localRpc(1, fork, undefined), /Refusing public fallback/);
  assert.throws(() => localRpc(1, fork, "https://gateway.tenderly.co/public/mainnet"), /Refusing public fallback/);
  assert.throws(() => localRpc(1, fork, "http://127.0.0.1:8545"), /Refusing public fallback/);
  assert.throws(() => localRpc(1, undefined, fork), /Refusing public fallback/);
});

test("live chain 1 keeps endpoint fallback and local chain uses its record RPC", () => {
  assert.equal(localRpc(1, undefined, undefined), undefined);
  assert.equal(localRpc(1, "https://rpc.example.org", undefined), undefined);
  assert.equal(localRpc(31337, "http://127.0.0.1:8545", undefined), "http://127.0.0.1:8545");
  assert.equal(localRpc(11155111, "http://127.0.0.1:8545", undefined), undefined);
});
