// promise: every request starts at the primary with one shared rate cap across constructors and no healthy fallthrough.
import assert from "node:assert/strict";
import test from "node:test";
import { fallbackTransport, rpcStats } from "./rpc.ts";

function response(id: number, result: unknown) {
  return new Response(JSON.stringify({ jsonrpc: "2.0", id, result }), {
    headers: { "content-type": "application/json" },
  });
}

test("RPC primary shares its rate and concurrency limit across concurrent constructors", async (t) => {
  const starts: { host: string; second: number }[] = [];
  let active = 0;
  let maxActive = 0;
  t.mock.method(globalThis, "fetch", async (url: string, init: RequestInit) => {
    starts.push({ host: new URL(url).host, second: Math.floor(Date.now() / 1000) });
    const body = JSON.parse(String(init.body));
    maxActive = Math.max(maxActive, ++active);
    await new Promise((resolve) => setTimeout(resolve, 1));
    active--;
    return response(body.id, "0x1");
  });
  const endpoints = [4, 8, 5, 10, 5, 5].map((rps, i) => ({ url: `https://public-${i}.invalid`, rps }));
  const factory = fallbackTransport(endpoints, { url: "https://reserve.invalid", rps: 8 });
  await Promise.all(Array.from({ length: 24 }, () => factory({}).request({ method: "eth_blockNumber" })));
  const perSecond = new Map<string, number>();
  for (const { host, second } of starts) {
    const key = `${host}:${second}`;
    perSecond.set(key, (perSecond.get(key) ?? 0) + 1);
  }
  assert.equal(starts.length, 24);
  assert.ok(starts.every((s) => s.host === "public-0.invalid"));
  assert.ok(Math.max(...perSecond.values()) <= 4, JSON.stringify([...perSecond]));
  assert.equal(maxActive, 1);
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

// promise: a physical request that ignores abort cannot hold a limiter slot or prevent fallback and queued work from settling.
test("RPC deadline releases an uncooperative fetch and its queued requests", async (t) => {
  const hosts: string[] = [];
  const signals: AbortSignal[] = [];
  let markStarted!: () => void;
  const started = new Promise<void>((resolve) => { markStarted = resolve; });
  t.mock.method(globalThis, "fetch", async (url: string, init: RequestInit) => {
    const host = new URL(url).host;
    hosts.push(host);
    if (host === "stalled.invalid") {
      signals.push(init.signal!);
      markStarted();
      return new Promise<Response>(() => {});
    }
    return response(JSON.parse(String(init.body)).id, "0x1");
  });
  const transport = fallbackTransport([
    { url: "https://stalled.invalid", rps: 4 },
    { url: "https://healthy.invalid", rps: 4 },
  ], { url: "https://unused-reserve.invalid", rps: 4 }, 30)({});
  const pending = Promise.all(Array.from({ length: 3 }, () => transport.request({ method: "eth_blockNumber" })));
  await started;
  assert.equal(rpcStats().get("stalled.invalid")?.active, 1);
  assert.equal(rpcStats().get("stalled.invalid")?.queued, 2);
  assert.deepEqual(await pending, ["0x1", "0x1", "0x1"]);
  assert.deepEqual(hosts.filter((h) => h === "stalled.invalid"), ["stalled.invalid", "stalled.invalid", "stalled.invalid"]);
  assert.equal(hosts.filter((h) => h === "healthy.invalid").length, 3);
  assert.equal(hosts.filter((h) => h === "unused-reserve.invalid").length, 0);
  assert.ok(signals.every((signal) => signal.aborted));
  const stats = rpcStats().get("stalled.invalid")!;
  assert.equal(stats.requests, 3);
  assert.equal(stats.errors, 3);
  assert.equal(stats.queued, 0);
  assert.equal(stats.active, 0);
  assert.ok(stats.lastStarted! <= stats.lastSettled!);
});
