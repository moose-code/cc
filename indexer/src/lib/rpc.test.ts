// promise: healthy public requests share endpoint budgets and round-robin state across constructors without using reserve RPC.
import assert from "node:assert/strict";
import test from "node:test";
import { fallbackTransport } from "./rpc.ts";

function response(id: number, result: unknown) {
  return new Response(JSON.stringify({ jsonrpc: "2.0", id, result }), {
    headers: { "content-type": "application/json" },
  });
}

test("RPC public balancing shares each endpoint rate limit across concurrent constructors", async (t) => {
  const starts: { host: string; second: number }[] = [];
  t.mock.method(globalThis, "fetch", async (url: string, init: RequestInit) => {
    starts.push({ host: new URL(url).host, second: Math.floor(Date.now() / 1000) });
    const body = JSON.parse(String(init.body));
    return response(body.id, "0x1");
  });
  const endpoints = [8, 8, 5, 10, 5, 5].map((rps, i) => ({ url: `https://public-${i}.invalid`, rps }));
  const factory = fallbackTransport(endpoints, { url: "https://reserve.invalid", rps: 8 });
  await Promise.all(Array.from({ length: 72 }, () => factory({}).request({ method: "eth_blockNumber" })));
  const perSecond = new Map<string, number>();
  for (const { host, second } of starts) {
    const key = `${host}:${second}`;
    perSecond.set(key, (perSecond.get(key) ?? 0) + 1);
  }
  assert.equal(starts.length, 72);
  for (const endpoint of endpoints) {
    const host = new URL(endpoint.url).host;
    assert.equal(starts.filter((s) => s.host === host).length, 12);
    for (const [key, count] of perSecond) {
      if (key.startsWith(`${host}:`)) assert.ok(count <= endpoint.rps, `${key}: ${count} > ${endpoint.rps}`);
    }
  }
  assert.equal(starts.filter((s) => s.host === "reserve.invalid").length, 0);
});

// promise: malformed, pruned and unavailable public responses fail over before reserve; execution reverts stop immediately.
test("RPC fallback retains ordered failover without hidden wire retries or retrying deterministic reverts", async (t) => {
  const hosts: string[] = [];
  let scenario: "malformed" | "pruned" | "unavailable" | "revert" = "malformed";
  t.mock.method(globalThis, "fetch", async (url: string, init: RequestInit) => {
    const host = new URL(url).host;
    hosts.push(host);
    const body = JSON.parse(String(init.body));
    if (host === "primary.invalid" && scenario === "malformed") return response(body.id, {});
    if (host === "primary.invalid" && scenario === "unavailable") return new Response("Unavailable", { status: 503 });
    if (host === "primary.invalid") {
      return new Response(JSON.stringify({ jsonrpc: "2.0", id: body.id, error: {
        code: -32602, message: scenario === "pruned" ? "missing trie node" : "execution reverted",
      } }), { headers: { "content-type": "application/json" } });
    }
    return response(body.id, scenario === "malformed" ? [] : "0x1");
  });
  const transport = () => fallbackTransport([
    { url: "https://primary.invalid", rps: 100 },
    { url: "https://secondary.invalid", rps: 100 },
  ], { url: "https://reserve.invalid", rps: 100 })({});
  assert.deepEqual(await transport().request({ method: "eth_getLogs", params: [{}] }), []);
  assert.deepEqual(hosts, ["primary.invalid", "secondary.invalid"]);
  hosts.length = 0;
  scenario = "pruned";
  assert.equal(await transport().request({ method: "eth_getBalance", params: ["0x0", "latest"] }), "0x1");
  assert.deepEqual(hosts, ["primary.invalid", "secondary.invalid"]);
  hosts.length = 0;
  scenario = "unavailable";
  assert.equal(await transport().request({ method: "eth_blockNumber" }), "0x1");
  assert.deepEqual(hosts, ["primary.invalid", "secondary.invalid"]);
  hosts.length = 0;
  scenario = "revert";
  await assert.rejects(transport().request({ method: "eth_call", params: [{}, "latest"] }), /execution reverted/);
  assert.deepEqual(hosts, ["primary.invalid"]);
});

// promise: the reserve receives exactly one attempt only after every public endpoint fails.
test("RPC reserve is the final attempt after all public endpoints fail", async (t) => {
  const hosts: string[] = [];
  t.mock.method(globalThis, "fetch", async (url: string, init: RequestInit) => {
    const host = new URL(url).host;
    hosts.push(host);
    const body = JSON.parse(String(init.body));
    return host === "reserve.invalid" ? response(body.id, "0x1") : new Response("Unavailable", { status: 503 });
  });
  const transport = fallbackTransport([
    { url: "https://primary.invalid", rps: 100 },
    { url: "https://secondary.invalid", rps: 100 },
  ], { url: "https://reserve.invalid", rps: 100 })({});
  assert.equal(await transport.request({ method: "eth_blockNumber" }), "0x1");
  assert.deepEqual(hosts, ["primary.invalid", "secondary.invalid", "reserve.invalid"]);
});
