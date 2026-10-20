// promise: OpenSea refreshes end within their request budget and a malformed listing leaves other signed orders usable
import { test } from "node:test";
import assert from "node:assert/strict";
import { fetchListings, CREDITS, SEAPORT_16 } from "@cc/engine/opensea";

const offerer = "0x00000000000000000000000000000000000000f1";
const zero = "0x0000000000000000000000000000000000000000";
const hash = "0x" + "11".repeat(32);
const basic = {
  considerationToken: zero, considerationIdentifier: "0", considerationAmount: "900", offerer,
  zone: zero, offerToken: CREDITS, offerIdentifier: "42", offerAmount: "1", basicOrderType: "0",
  startTime: "1", endTime: "9999999999", zoneHash: "0x" + "00".repeat(32), salt: "5",
  offererConduitKey: "0x" + "00".repeat(32), fulfillerConduitKey: "0x" + "00".repeat(32),
  totalOriginalAdditionalRecipients: "0", additionalRecipients: [], signature: "0xabcd",
};

test("OpenSea: a malformed page entry is dropped while a valid order is signed", async () => {
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (url: string | URL) => {
    const path = new URL(url).pathname;
    const body = path.includes("/contract/") ? { collection: "credits" }
      : path.endsWith("/best") ? { listings: [
        { protocol_address: SEAPORT_16, protocol_data: { parameters: { offer: null } } },
        { protocol_address: SEAPORT_16, order_hash: hash, protocol_data: { parameters: {
          offer: [{ itemType: 2, token: CREDITS, startAmount: "1", endAmount: "1", identifierOrCriteria: "42" }],
          consideration: [{ itemType: 0, token: zero, startAmount: "900", endAmount: "900", recipient: offerer }],
          orderType: 0, offerer, startTime: "1", endTime: "9999999999",
        } } },
      ] } : { fulfillment_data: { transaction: { function: "fulfillBasicOrder_efficient_6GL6yc", input_data: { parameters: basic } } } };
    return new Response(JSON.stringify(body), { status: 200 });
  }) as typeof fetch;
  try {
    const r = await fetchListings({ key: "test", pages: 1, sign: 1 });
    assert.equal(r.fetched, 2);
    assert.equal(r.dropped["malformed listing"], 1);
    assert.deepEqual(r.orders.map((o) => o.id), ["42"]);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("OpenSea: a stalled request is aborted by the whole-refresh timeout", async () => {
  const realFetch = globalThis.fetch;
  const keepAlive = setInterval(() => {}, 1_000);
  globalThis.fetch = ((_url: unknown, init: RequestInit) => new Promise((_resolve, reject) => {
    init.signal?.addEventListener("abort", () => reject(init.signal?.reason), { once: true });
  })) as typeof fetch;
  try {
    await assert.rejects(fetchListings({ key: "test", timeoutMs: 10 }), /timeout|Timeout/i);
  } finally {
    clearInterval(keepAlive);
    globalThis.fetch = realFetch;
  }
});

test("OpenSea: a malformed fulfillment does not discard another signed order", async () => {
  const realFetch = globalThis.fetch;
  const badHash = "0x" + "22".repeat(32);
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    const path = new URL(url).pathname;
    const body = path.includes("/contract/") ? { collection: "credits" }
      : path.endsWith("/best") ? { listings: ["42", "43"].map((id, i) => ({
        protocol_address: SEAPORT_16, order_hash: i ? badHash : hash, protocol_data: { parameters: {
          offer: [{ itemType: 2, token: CREDITS, startAmount: "1", endAmount: "1", identifierOrCriteria: id }],
          consideration: [{ itemType: 0, token: zero, startAmount: "900", endAmount: "900", recipient: offerer }],
          orderType: 0, offerer, startTime: "1", endTime: "9999999999",
        } },
      })) }
      : { fulfillment_data: { transaction: { function: "fulfillBasicOrder_efficient_6GL6yc", input_data: {
        parameters: JSON.parse(String(init?.body)).listing.hash === badHash ? { ...basic, additionalRecipients: null } : basic,
      } } } };
    return new Response(JSON.stringify(body), { status: 200 });
  }) as typeof fetch;
  try {
    const r = await fetchListings({ key: "test", pages: 1, sign: 2 });
    assert.equal(r.dropped["malformed fulfillment"], 1);
    assert.deepEqual(r.orders.map((o) => o.id), ["42"]);
  } finally {
    globalThis.fetch = realFetch;
  }
});

// promise: a single slow fulfillment cannot erase another valid signed order from the same refresh
test("OpenSea: one fulfillment times out while another signed order remains", async () => {
  const realFetch = globalThis.fetch;
  const keepAlive = setInterval(() => {}, 1_000);
  const slowHash = "0x" + "33".repeat(32);
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    const path = new URL(url).pathname;
    if (path.includes("/contract/")) return new Response(JSON.stringify({ collection: "credits" }), { status: 200 });
    if (path.endsWith("/best")) return new Response(JSON.stringify({ listings: ["42", "43"].map((id, i) => ({
      protocol_address: SEAPORT_16, order_hash: i ? slowHash : hash, protocol_data: { parameters: {
        offer: [{ itemType: 2, token: CREDITS, startAmount: "1", endAmount: "1", identifierOrCriteria: id }],
        consideration: [{ itemType: 0, token: zero, startAmount: "900", endAmount: "900", recipient: offerer }],
        orderType: 0, offerer, startTime: "1", endTime: "9999999999",
      } },
    })) }), { status: 200 });
    if (JSON.parse(String(init?.body)).listing.hash === slowHash) return new Promise((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => reject(init.signal?.reason), { once: true });
    });
    return new Response(JSON.stringify({ fulfillment_data: { transaction: {
      function: "fulfillBasicOrder_efficient_6GL6yc", input_data: { parameters: basic },
    } } }), { status: 200 });
  }) as typeof fetch;
  try {
    const r = await fetchListings({ key: "test", pages: 1, sign: 2, timeoutMs: 200, fulfillmentTimeoutMs: 10 });
    assert.equal(r.dropped["fulfillment request failed"], 1);
    assert.deepEqual(r.orders.map((o) => o.id), ["42"]);
  } finally {
    clearInterval(keepAlive);
    globalThis.fetch = realFetch;
  }
});

// promise: the whole-refresh deadline preserves signed orders already returned by a fulfillment sibling
test("OpenSea: global timeout during fulfillments keeps a completed sibling", async () => {
  const realFetch = globalThis.fetch;
  const keepAlive = setInterval(() => {}, 1_000);
  const slowHash = "0x" + "44".repeat(32);
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    const path = new URL(url).pathname;
    if (path.includes("/contract/")) return new Response(JSON.stringify({ collection: "credits" }), { status: 200 });
    if (path.endsWith("/best")) return new Response(JSON.stringify({ listings: ["42", "43"].map((id, i) => ({
      protocol_address: SEAPORT_16, order_hash: i ? slowHash : hash, protocol_data: { parameters: {
        offer: [{ itemType: 2, token: CREDITS, startAmount: "1", endAmount: "1", identifierOrCriteria: id }],
        consideration: [{ itemType: 0, token: zero, startAmount: "900", endAmount: "900", recipient: offerer }],
        orderType: 0, offerer, startTime: "1", endTime: "9999999999",
      } },
    })) }), { status: 200 });
    if (JSON.parse(String(init?.body)).listing.hash === slowHash) return new Promise((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => reject(init?.signal?.reason), { once: true });
    });
    return new Response(JSON.stringify({ fulfillment_data: { transaction: {
      function: "fulfillBasicOrder_efficient_6GL6yc", input_data: { parameters: basic },
    } } }), { status: 200 });
  }) as typeof fetch;
  try {
    const r = await fetchListings({ key: "test", pages: 1, sign: 2, timeoutMs: 25, fulfillmentTimeoutMs: 200 });
    assert.equal(r.dropped["fulfillment request failed"], 1);
    assert.deepEqual(r.orders.map((o) => o.id), ["42"]);
  } finally {
    clearInterval(keepAlive);
    globalThis.fetch = realFetch;
  }
});


const abiWord = (n: number | bigint) => "0x" + BigInt(n).toString(16).padStart(64, "0");
const holder = (id: number) => "0x" + (0xf1 + id).toString(16).padStart(40, "0");
function rpcListing(id: number, withFee = false) {
  const offerer = holder(id);
  return { protocol_address: SEAPORT_16, order_hash: abiWord(id), protocol_data: { parameters: {
    offer: [{ itemType: 2, token: CREDITS, startAmount: "1", endAmount: "1", identifierOrCriteria: String(id) }],
    consideration: [{ itemType: 0, token: zero, startAmount: "900", endAmount: "900", recipient: offerer },
      ...(withFee ? [{ itemType: 0, token: zero, startAmount: "1", endAmount: "1", recipient: "0x0000a26b00c1f0df003000390027140000faa719" }] : [])],
    orderType: 0, offerer, startTime: "1", endTime: "9999999999",
  } } };
}
function osResponse(url: string | URL, init: RequestInit | undefined, listings: unknown[]) {
  const path = new URL(url).pathname;
  if (path.includes("/contract/")) return Response.json({ collection: "credits" });
  if (path.endsWith("/best")) return Response.json({ listings });
  const id = Number(BigInt(JSON.parse(String(init?.body)).listing.hash));
  return Response.json({ fulfillment_data: { transaction: { function: "fulfillBasicOrder_efficient_6GL6yc", input_data: {
    parameters: { ...basic, offerIdentifier: String(id), offerer: holder(id) },
  } } } });
}
function rpcResult(request: any, revertId?: number) {
  if (request.method === "eth_getBlockByNumber") return { jsonrpc: "2.0", id: request.id, result: { timestamp: "0x1" } };
  const data = request.params[0].data as string;
  const id = Number(BigInt("0x" + data.slice(10)));
  if (data.startsWith("0x6352211e")) return id === revertId
    ? { jsonrpc: "2.0", id: request.id, error: { code: 3, message: "execution reverted" } }
    : { jsonrpc: "2.0", id: request.id, result: "0x" + holder(id).slice(2).padStart(64, "0") };
  return { jsonrpc: "2.0", id: request.id, result: abiWord(1) };
}

// promise: provider429 falls back in configured order, bounded batches retain ID ordering, and owner reverts reject only that listing
test("OpenSea:429 fallback preserves bounded batch IDs and owner failures", async () => {
  const realFetch = globalThis.fetch;
  const starts: Record<string, number[]> = { primary: [], secondary: [] };
  const attempts: string[] = [];
  const listings = Array.from({ length: 23 }, (_, i) => rpcListing(i + 1));
  const batchSizes: number[] = [];
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    const host = new URL(url).hostname;
    if (host !== "primary" && host !== "secondary") return osResponse(url, init, listings);
    starts[host].push(Date.now()); attempts.push(host);
    const body = JSON.parse(String(init?.body));
    if (host === "primary") return Response.json({ jsonrpc: "2.0", id: null, error: { code: -32005 } }, { status: 429 });
    if (Array.isArray(body)) { batchSizes.push(body.length); return Response.json(body.map((r: any) => rpcResult(r, 5)).reverse()); }
    return Response.json(rpcResult(body));
  }) as typeof fetch;
  try {
    const r = await fetchListings({ key: "test", rpcUrls: ["https://primary", "https://secondary"], pages: 1, sign: 2, horizon: 0 });
    assert.equal(r.fit, 22); assert.equal(r.notHeld, 1);
    assert.deepEqual(r.orders.map(row => row.id), ["1", "2"]);
    assert.ok(batchSizes.includes(20)); assert.ok(batchSizes.every(size => size <= 20));
    for (let i = 0; i < attempts.length; i += 2) assert.deepEqual(attempts.slice(i, i + 2), ["primary", "secondary"]);
    for (const times of Object.values(starts)) for (let i = 1; i < times.length; i++) assert.ok(times[i] - times[i - 1] >= 235);
  } finally { globalThis.fetch = realFetch; }
});

// promise: invalid response IDs and unavailable allowlist reads fail the refresh rather than replacing a good cache with empty orders
test("OpenSea: malformed batch IDs and unavailable allowlist fail closed", async () => {
  const realFetch = globalThis.fetch;
  let fee = false;
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    if (new URL(url).hostname === "api.opensea.io") return osResponse(url, init, [rpcListing(1, fee)]);
    const body = JSON.parse(String(init?.body));
    return fee ? Response.json({ error: { code: -32005 } }, { status: 429 })
      : Response.json([{ ...rpcResult(body[0]), id: 99 }]);
  }) as typeof fetch;
  try {
    await assert.rejects(fetchListings({ key: "test", rpc: "https://bad-ids", pages: 1, sign: 1 }), /RPC unavailable/);
    fee = true;
    await assert.rejects(fetchListings({ key: "test", rpcUrls: ["https://bad-allow"], adapter: offerer, pages: 1, sign: 1 }), /RPC unavailable/);
  } finally { globalThis.fetch = realFetch; }
});

// promise: deterministic owner reverts do not invoke another provider and the whole deadline includes paced RPC waits
test("OpenSea: owner revert stays local and pacing respects the refresh deadline", async () => {
  const realFetch = globalThis.fetch;
  let primary = 0, reserve = 0;
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    const host = new URL(url).hostname;
    if (host === "api.opensea.io") return osResponse(url, init, [rpcListing(1)]);
    if (host === "revert-reserve") reserve++; else primary++;
    const body = JSON.parse(String(init?.body));
    return Response.json(Array.isArray(body) ? body.map((r: any) => rpcResult(r, 1)) : rpcResult(body));
  }) as typeof fetch;
  const keepAlive = setInterval(() => {}, 1_000);
  try {
    const r = await fetchListings({ key: "test", rpcUrls: ["https://revert-primary", "https://revert-reserve"], pages: 1, sign: 1 });
    assert.equal(r.fit, 0); assert.equal(r.notHeld, 1); assert.equal(reserve, 0);
    const before = primary, started = Date.now();
    await assert.rejects(fetchListings({ key: "test", rpcUrls: ["https://deadline-primary", "https://revert-reserve"], pages: 1, sign: 1, timeoutMs: 20 }), /abort|timeout/i);
    assert.ok(Date.now() - started < 200); assert.equal(primary, before + 1); assert.equal(reserve, 0);
  } finally { clearInterval(keepAlive); globalThis.fetch = realFetch; }
});


// promise: authorization failure rejects the refresh after one batch so the keeper retains its cache; an unavailable individual order still permits siblings
test("OpenSea:401/403 fail the refresh,400/404 retain successful sibling orders", async () => {
  const realFetch = globalThis.fetch;
  let status = 401, posts = 0;
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    const path = new URL(url).pathname;
    if (path.includes("/contract/")) return Response.json({ collection: "credits" });
    if (path.endsWith("/best")) return Response.json({ listings: Array.from({ length: 20 }, (_, i) => rpcListing(i + 1)) });
    posts++;
    if (status === 401 || status === 403 || JSON.parse(String(init?.body)).listing.hash === abiWord(2)) return Response.json({}, { status });
    return osResponse(url, init, []);
  }) as typeof fetch;
  try {
    for (status of [401, 403]) {
      posts = 0;
      await assert.rejects(fetchListings({ key: "test", pages: 1, sign: 20 }), (error: any) => error.name === `OpenSeaAuth${status}`);
      assert.equal(posts, 8);
    }
    for (status of [400, 404]) {
      const result = await fetchListings({ key: "test", pages: 1, sign: 2 });
      assert.deepEqual(result.orders.map(row => row.id), ["1"]);
      assert.equal(result.dropped["no basic fulfillment data"], 1);
    }
  } finally { globalThis.fetch = realFetch; }
});
