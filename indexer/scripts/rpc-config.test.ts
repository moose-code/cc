import assert from "node:assert/strict";
import { test, mock } from "node:test";
import { mainnet } from "viem/chains";
import { fallbackTransport, type Endpoint } from "../src/lib/rpc.ts";
import { sanitizedRpc, temporaryFallbackTransport, withFastFallback } from "../rpc-config.ts";

const publics: Endpoint[] = [
  { url: "https://gateway.tenderly.co/public/mainnet", rps: 4 },
  { url: "https://eth-mainnet.public.blastapi.io", rps: 8 },
  { url: "https://1rpc.io/eth", rps: 5 },
  { url: "https://ethereum-rpc.publicnode.com", rps: 10 },
  { url: "https://eth.drpc.org", rps: 5 },
  { url: "https://rpc.mevblocker.io", rps: 5 },
];
const fast = "https://eth-mainnet.g.alchemy.com/v2/public-fixture";
const until = () => new Date(Date.now() + 10 * 60_000).toISOString();
const configured = (calls = "10000", expiry = until()) => withFastFallback(publics, reserve, fast, "8", calls, expiry);
const reserve = { url: "https://reserve.invalid/public-fixture", rps: 10 };

// promise: Tenderly stays first, Alchemy is the first fallback, and the existing public caps and distinct reserve stay unchanged.
test("fast fallback priority and physical caps", () => {
  assert.deepEqual(withFastFallback(publics, reserve), { endpoints: publics, reserve });
  const selected = configured();
  assert.deepEqual(selected.endpoints, [publics[0], { url: fast, rps: 8 }, ...publics.slice(1)]);
  assert.deepEqual(selected.reserve, reserve);
  assert.equal(withFastFallback(publics, reserve, fast, "2", "10000", until()).endpoints[1].rps, 2);
  assert.equal(withFastFallback(publics, { url: fast, rps: 10 }, fast).reserve, undefined);
});

// promise: endpoint/cap errors fail without reflecting a credential-bearing URL into startup logs.
test("invalid fast fallback configuration is sanitized", () => {
  for (const value of ["not-a-url/public-fixture", "http://eth-mainnet.g.alchemy.com/v2/public-fixture", "https://base-mainnet.g.alchemy.com/v2/public-fixture", "https://eth-mainnet.g.alchemy.com.evil.invalid/public-fixture", "https://user:public-fixture@eth-mainnet.g.alchemy.com/v2/a"]) {
    assert.throws(() => withFastFallback(publics, reserve, value), (error) => {
      assert.doesNotMatch(String(error), /public-fixture/);
      return true;
    });
  }
  for (const value of ["0", "-1", "9", "1.5", "NaN", ""]) assert.throws(() => withFastFallback(publics, reserve, fast, value), /RPC_RPS_FAST_FALLBACK/);
});

// promise: actual fallback stops on a deterministic revert and exposes its code/data without any original endpoint URL or cause.
test("actual fallback revert and ordinary errors cannot disclose the endpoint credential", async () => {
  const hosts: string[] = [];
  mock.method(globalThis, "fetch", async (url: string, init: RequestInit) => {
    const body = JSON.parse(String(init.body));
    hosts.push(new URL(url).host);
    return new Response(JSON.stringify({ jsonrpc: "2.0", id: body.id, error: { code: 3, message: "execution reverted", data: "0xdead" } }));
  });
  try {
    const endpoint = { url: fast, rps: 4 };
    const transport = sanitizedRpc(fallbackTransport([endpoint, publics[0]]))({ chain: mainnet, retryCount: 0 });
    await assert.rejects(transport.request({ method: "eth_call", params: [{ to: "0x" + "1".repeat(40), data: "0x" }, "latest"] }), (error: unknown) => {
      const e = error as Error & { code: number; data: string };
      assert.equal(e.code, 3); assert.equal(e.data, "0xdead");
      assert.match(e.message, /execution reverted/);
      assert.doesNotMatch(String(e.stack) + JSON.stringify(e), /public-fixture|https:\/\/eth-mainnet.g.alchemy.com/);
      return true;
    });
    assert.deepEqual(hosts, ["eth-mainnet.g.alchemy.com"]);
    const generic = sanitizedRpc(() => ({ ...transport, request: async () => { throw new Error("failed " + fast); } }))({ chain: mainnet, retryCount: 0 });
    await assert.rejects(generic.request({ method: "eth_chainId" }), (error: unknown) => {
      assert.doesNotMatch(String(error) + JSON.stringify(error), /public-fixture/);
      return true;
    });
  } finally { mock.restoreAll(); }
});

// promise: paid access requires both a bounded request reservation and a near-term absolute UTC expiry, including reserve deduplication.
test("missing and invalid spending envelopes disable paid access", () => {
  for (const url of [fast, "https://eth-mainnet.g.alchemy.com:443/v2/another-public-fixture"]) {
    assert.deepEqual(withFastFallback(publics, { url, rps: 10 }), { endpoints: publics, reserve: undefined });
    assert.deepEqual(withFastFallback(publics, { url, rps: 10 }, fast, "8"), { endpoints: publics, reserve: undefined });
  }
  for (const calls of [undefined, "", "0", "-1", "10001", "1.5", "1e4", "NaN"]) {
    assert.deepEqual(withFastFallback(publics, { url: fast, rps: 10 }, fast, "8", calls, until()), { endpoints: publics, reserve: undefined });
  }
  for (const expiry of [undefined, "", "tomorrow", "2026-10-19", new Date(Date.now() - 1000).toISOString(), new Date(Date.now() + 26 * 60_000).toISOString()]) {
    assert.deepEqual(withFastFallback(publics, reserve, fast, "8", "10000", expiry), { endpoints: publics, reserve });
  }
});

// promise: a confirmed primary rate limit backs off for 30 seconds; shared constructors cannot exceed the paid reservation or resume it after expiry.
test("physical budget, primary backoff, expiry, and public fallback", async () => {
  const clock = Date.now.bind(Date);
  let offset = 0;
  const hosts: string[] = [];
  mock.method(Date, "now", () => clock() + offset);
  mock.method(console, "warn", () => {});
  mock.method(globalThis, "fetch", async (url: string, init: RequestInit) => {
    const body = JSON.parse(String(init.body));
    const host = new URL(url).host;
    hosts.push(host);
    return new Response(JSON.stringify({ jsonrpc: "2.0", id: body.id, ...(host === "gateway.tenderly.co" ? { error: { code: 429, message: "Request exceeds defined limit." } } : { result: "0x1" }) }));
  });
  try {
    const factory = temporaryFallbackTransport(configured("2"));
    const a = factory({ chain: mainnet, retryCount: 0 });
    const b = factory({ chain: mainnet, retryCount: 0 });
    await a.request({ method: "eth_chainId" });
    await b.request({ method: "eth_chainId" });
    assert.deepEqual(hosts, ["gateway.tenderly.co", "eth-mainnet.g.alchemy.com", "eth-mainnet.g.alchemy.com"]);
    await Promise.all(Array.from({ length: 4 }, () => b.request({ method: "eth_chainId" })));
    assert.equal(hosts.filter(h => h === "eth-mainnet.g.alchemy.com").length, 2);
    assert.equal(hosts.filter(h => h === "eth-mainnet.public.blastapi.io").length, 4);
    offset = 31_000;
    await a.request({ method: "eth_chainId" });
    assert.equal(hosts.filter(h => h === "gateway.tenderly.co").length, 2);
    const expiring = temporaryFallbackTransport(configured())({ chain: mainnet, retryCount: 0 });
    offset += 11 * 60_000;
    const before = hosts.filter(h => h === "eth-mainnet.g.alchemy.com").length;
    await expiring.request({ method: "eth_chainId" });
    assert.equal(hosts.filter(h => h === "eth-mainnet.g.alchemy.com").length, before);
    assert.equal(hosts.at(-1), "eth-mainnet.public.blastapi.io");
  } finally { mock.restoreAll(); }
});

// promise: physical requests share an eight-per-calendar-second cap across repeated Ponder transport construction.
test("boost physical limiter is shared across constructors", async () => {
  const times: number[] = [];
  mock.method(console, "warn", () => {});
  mock.method(globalThis, "fetch", async (url: string, init: RequestInit) => {
    const body = JSON.parse(String(init.body));
    const primary = new URL(url).host === "gateway.tenderly.co";
    if (!primary) times.push(Date.now());
    return new Response(JSON.stringify({ jsonrpc: "2.0", id: body.id, ...(primary ? { error: { code: 429, message: "Request exceeds defined limit." } } : { result: "0x1" }) }));
  });
  try {
    const factory = temporaryFallbackTransport(configured());
    const a = factory({ chain: mainnet, retryCount: 0 });
    const b = factory({ chain: mainnet, retryCount: 0 });
    await Promise.all(Array.from({ length: 12 }, (_, i) => (i % 2 ? a : b).request({ method: "eth_chainId" })));
    assert.equal(times.length, 12);
    const perSecond = new Map<number, number>();
    for (const time of times) { const sec = Math.floor(time / 1000); perSecond.set(sec, (perSecond.get(sec) ?? 0) + 1); }
    assert.ok([...perSecond.values()].every(n => n <= 8));
  } finally { mock.restoreAll(); }
});

// promise: HTTP 429 backs off, ordinary transport errors do not, and deterministic reverts still stop before public fallbacks without exposing a credential.
test("HTTP rate-limit classification and boosted revert sanitization", async () => {
  let mode: "http429" | "ordinary" | "revert" = "http429";
  const hosts: string[] = [];
  mock.method(console, "warn", () => {});
  mock.method(globalThis, "fetch", async (url: string, init: RequestInit) => {
    const body = JSON.parse(String(init.body));
    const host = new URL(url).host;
    hosts.push(host);
    if (host === "gateway.tenderly.co") return mode === "http429" ? new Response("busy", { status: 429 }) : new Response(JSON.stringify({ jsonrpc: "2.0", id: body.id, error: { code: -32000, message: "Request exceeds defined limit." } }));
    return new Response(JSON.stringify({ jsonrpc: "2.0", id: body.id, ...(mode === "revert" ? { error: { code: 3, message: "execution reverted", data: "0xdead" } } : { result: "0x1" }) }));
  });
  try {
    const limited = temporaryFallbackTransport(configured())({ chain: mainnet, retryCount: 0 });
    await limited.request({ method: "eth_chainId" });
    await limited.request({ method: "eth_chainId" });
    assert.equal(hosts.filter(h => h === "gateway.tenderly.co").length, 1);
    hosts.length = 0; mode = "ordinary";
    const ordinary = temporaryFallbackTransport(configured())({ chain: mainnet, retryCount: 0 });
    await ordinary.request({ method: "eth_chainId" });
    await ordinary.request({ method: "eth_chainId" });
    assert.equal(hosts.filter(h => h === "gateway.tenderly.co").length, 2);
    hosts.length = 0; mode = "revert";
    const reverting = sanitizedRpc(temporaryFallbackTransport(configured()))({ chain: mainnet, retryCount: 0 });
    await assert.rejects(reverting.request({ method: "eth_call", params: [{ to: "0x" + "1".repeat(40), data: "0x" }, "latest"] }), (error: unknown) => {
      const e = error as Error & { code: number; data: string };
      assert.equal(e.code, 3); assert.equal(e.data, "0xdead");
      assert.doesNotMatch(String(e.stack) + JSON.stringify(e), /public-fixture|https:\/\/eth-mainnet.g.alchemy.com/);
      return true;
    });
    assert.deepEqual(hosts, ["gateway.tenderly.co", "eth-mainnet.g.alchemy.com"]);
  } finally { mock.restoreAll(); }
});
