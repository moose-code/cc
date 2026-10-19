// promise: indexer failover shares endpoint request budgets and preserves malformed, pruned, unavailable and reverted response handling.
import assert from "node:assert/strict";
import test from "node:test";
import { fallbackTransport } from "./rpc.ts";

function response(id: number, result: unknown) {
  return new Response(JSON.stringify({ jsonrpc: "2.0", id, result }), {
    headers: { "content-type": "application/json" },
  });
}

test("RPC fallback shares each endpoint rate limit across concurrent requests", async (t) => {
  const starts: number[] = [];
  t.mock.method(globalThis, "fetch", async (_url: unknown, init: RequestInit) => {
    starts.push(Math.floor(Date.now() / 1000));
    const body = JSON.parse(String(init.body));
    return response(body.id, "0x1");
  });
  const transport = fallbackTransport([{ url: "https://primary.invalid", rps: 8 }])({});
  await Promise.all(Array.from({ length: 24 }, () => transport.request({ method: "eth_blockNumber" })));
  const perSecond = new Map<number, number>();
  for (const second of starts) perSecond.set(second, (perSecond.get(second) ?? 0) + 1);
  assert.equal(starts.length, 24);
  assert.ok(Math.max(...perSecond.values()) <= 8, JSON.stringify([...perSecond]));
});

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
  const transport = fallbackTransport([
    { url: "https://primary.invalid", rps: 100 },
    { url: "https://secondary.invalid", rps: 100 },
  ])({});
  assert.deepEqual(await transport.request({ method: "eth_getLogs", params: [{}] }), []);
  assert.deepEqual(hosts, ["primary.invalid", "secondary.invalid"]);
  hosts.length = 0;
  scenario = "pruned";
  assert.equal(await transport.request({ method: "eth_getBalance", params: ["0x0", "latest"] }), "0x1");
  assert.deepEqual(hosts, ["primary.invalid", "secondary.invalid"]);
  hosts.length = 0;
  scenario = "unavailable";
  assert.equal(await transport.request({ method: "eth_blockNumber" }), "0x1");
  assert.deepEqual(hosts, ["primary.invalid", "secondary.invalid"]);
  hosts.length = 0;
  scenario = "revert";
  await assert.rejects(transport.request({ method: "eth_call", params: [{}, "latest"] }), /execution reverted/);
  assert.deepEqual(hosts, ["primary.invalid"]);
});
