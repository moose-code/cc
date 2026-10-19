import assert from "node:assert/strict";
import test from "node:test";
import { createRpcDispatcher, RpcProxyError } from "../lib/rpc-proxy.ts";
import { handleRpcRequest } from "../lib/rpc-handler.ts";

const result = (value) => new Response(JSON.stringify({ jsonrpc: "2.0", id: 1, result: value }));
const envelope = (method, params = [], id = 1) => ({ jsonrpc: "2.0", id, method, params });
const address = "0x" + "1".repeat(40);
const urls = ["https://first.invalid", "https://second.invalid"];

// promise: concurrent identical reads share one physical attempt and cache results while preserving each caller's id.
test("deduplication and cache preserve JSON-RPC ids", async () => {
  let calls = 0;
  const rpc = createRpcDispatcher({ urls, intervalMs: 1, fetchFn: async () => { calls++; await new Promise((r) => setTimeout(r, 5)); return result("0x12"); } });
  const out = await rpc.dispatch([envelope("eth_blockNumber", [], "one"), envelope("eth_blockNumber", [], 2)]);
  assert.deepEqual(out.body.map((x) => [x.id, x.result]), [["one", "0x12"], [2, "0x12"]]);
  assert.equal(await rpc.request("eth_blockNumber"), "0x12");
  assert.equal(calls, 1);
});

// promise: physical attempts are paced and at most two run concurrently; overload fails without bypassing the queue.
test("physical throttle, concurrency and bounded admission", async () => {
  const starts = [];
  let active = 0, maxActive = 0;
  const rpc = createRpcDispatcher({ urls, intervalMs: 20, maxQueue: 1, fetchFn: async () => {
    starts.push(Date.now()); maxActive = Math.max(maxActive, ++active);
    await new Promise((r) => setTimeout(r, 45)); active--; return result("0x1");
  } });
  const pending = [rpc.request("eth_getBalance", [address, "0x1"]), rpc.request("eth_getBalance", [address, "0x2"])];
  await assert.rejects(rpc.request("eth_getBalance", [address, "0x3"]), (e) => e instanceof RpcProxyError && e.status === 429);
  await Promise.all(pending);
  assert.equal(starts.length, 2);
  assert.ok(starts[1] - starts[0] >= 18);
  assert.ok(maxActive <= 2);
});

// promise: failure tries the next provider once, while execution reverts retain their code and data without fallback.
test("ordered failover and preserved sanitized execution errors", async () => {
  const hosts = [];
  let revert = false;
  const rpc = createRpcDispatcher({ urls, intervalMs: 1, fetchFn: async (url) => {
    hosts.push(url);
    if (revert) return new Response(JSON.stringify({ jsonrpc: "2.0", id: 1, error: { code: 3, message: "execution reverted https://private.invalid/secret", data: "0xdead" } }));
    return url === urls[0] ? new Response("unavailable", { status: 503 }) : result("0x1");
  } });
  assert.equal(await rpc.request("eth_chainId"), "0x1");
  assert.deepEqual(hosts, urls);
  hosts.length = 0; revert = true;
  const out = await rpc.dispatch(envelope("eth_call", [{ to: address, data: "0x" }], "revert-id"));
  assert.equal(out.status, 200);
  assert.deepEqual(out.body.error, { code: 3, message: "execution reverted [upstream]", data: "0xdead" });
  assert.equal(out.body.id, "revert-id");
  assert.deepEqual(hosts, [urls[0]]);
});

// promise: an upstream that ignores abort still releases its request slot at the independent deadline.
test("deadline bounds an uncooperative provider", async () => {
  const hosts = [], signals = [];
  const rpc = createRpcDispatcher({ urls, intervalMs: 1, timeoutMs: 15, fetchFn: async (url, init) => {
    hosts.push(url); signals.push(init.signal);
    return url === urls[0] ? new Promise(() => {}) : result("0x1");
  } });
  assert.equal(await rpc.request("eth_chainId"), "0x1");
  assert.deepEqual(hosts, urls);
  assert.equal(signals[0].aborted, true);
});

// promise: writes, malformed batches and unbounded logs are rejected before any upstream request.
test("adversarial admission rejects writes and unbounded requests", async () => {
  let calls = 0;
  const rpc = createRpcDispatcher({ urls, fetchFn: async () => { calls++; return result("0x1"); } });
  for (const payload of [
    envelope("eth_sendRawTransaction", ["0xdead"]), envelope("personal_sign", []), envelope("debug_traceCall", []),
    envelope("eth_getLogs", [{ fromBlock: "0x1", toBlock: "0x1389" }]),
    envelope("eth_getLogs", [{ fromBlock: "0x1", toBlock: "latest" }]),
    envelope("eth_call", [{ to: "not-an-address" }]), { jsonrpc: "2.0", method: "eth_chainId" },
    [], Array.from({ length: 21 }, () => envelope("eth_chainId")),
    [envelope("eth_chainId"), envelope("eth_sendTransaction", [{}])],
  ]) await assert.rejects(rpc.dispatch(payload), RpcProxyError);
  assert.equal(calls, 0);
});

// promise: pending and estimate-gas reads are never cached; empty pre-coin code remains a short-lived result.
test("pending and gas estimates bypass cache", async () => {
  let calls = 0;
  const rpc = createRpcDispatcher({ urls, intervalMs: 1, fetchFn: async () => { calls++; return result("0x"); } });
  for (let i = 0; i < 2; i++) await rpc.request("eth_estimateGas", [{ to: address }]);
  for (let i = 0; i < 2; i++) await rpc.request("eth_getCode", [address, "pending"]);
  assert.equal(calls, 4);
});

// promise: the HTTP handler rejects oversized and malformed bodies without attempting RPC and disables response caching.
test("HTTP body limits and malformed JSON", async () => {
  for (const body of ["{", "x".repeat(128 * 1024 + 1)]) {
    const out = await handleRpcRequest(new Request("https://cc.artcoins.art/api/rpc", { method: "POST", body }));
    assert.equal(out.status, 400);
    assert.equal(out.headers.get("cache-control"), "no-store");
  }
});

// promise: the website's 23-event Core/controller scan fits the bounded log-topic filter.
test("Core event OR filter supports all 23 event selectors", async () => {
  const topics = [Array.from({ length: 23 }, (_, i) => "0x" + i.toString(16).padStart(64, "0"))];
  const rpc = createRpcDispatcher({ urls, fetchFn: async () => result([]) });
  assert.deepEqual(await rpc.request("eth_getLogs", [{ fromBlock: "0x1", toBlock: "0x1388", topics }]), []);
});

// promise: one overall deadline cancels queued work and active attempts instead of leaving abandoned requests running.
test("overall deadline removes waiting jobs and releases active slots", async () => {
  let calls = 0, healthy = false;
  const signals = [];
  const rpc = createRpcDispatcher({ urls, intervalMs: 1, timeoutMs: 1_000, requestTimeoutMs: 25, fetchFn: async (_url, init) => {
    calls++; signals.push(init.signal);
    return healthy ? result("0x1") : new Promise(() => {});
  } });
  const settled = await Promise.allSettled(Array.from({ length: 5 }, (_, i) => rpc.request("eth_getBalance", [address, "0x" + (i + 1).toString(16)])));
  assert.ok(settled.every((x) => x.status === "rejected" && x.reason.status === 504));
  assert.ok(calls >= 2 && calls <= 5);
  const atDeadline = calls;
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(calls, atDeadline);
  assert.ok(signals.every((signal) => signal.aborted));
  healthy = true;
  assert.equal(await rpc.request("eth_getBalance", [address, "0x99"]), "0x1");
  assert.equal(calls, atDeadline + 1);
});

// promise: oversized upstream bodies cannot enter the JSON parser or cache, and failures disclose no upstream URL.
test("upstream response size is bounded", async () => {
  let calls = 0;
  const rpc = createRpcDispatcher({ urls, intervalMs: 1, fetchFn: async () => {
    calls++;
    return new Response(new Uint8Array(10 * 1024 * 1024 + 1));
  } });
  const out = await rpc.dispatch(envelope("eth_chainId", [], "bounded"));
  assert.equal(out.status, 502);
  assert.equal(out.body.id, "bounded");
  assert.equal(out.body.error.message, "RPC providers unavailable");
  assert.equal(calls, 2);
});
