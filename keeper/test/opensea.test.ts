// promise: OpenSea refreshes end within their request budget and a malformed listing leaves other signed orders usable
import { test } from "node:test";
import assert from "node:assert/strict";
import { fetchListings, CREDITS, SEAPORT_16, OpenSeaRateLimit, OpenSeaUnavailable, createMarketBook, OpenSeaPending } from "@cc/engine/opensea";

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

// promise: full discovery reaches a winner after listing 300, scores each unique id in bounded chunks, and ranks before bounded live reads.
test("OpenSea full scan: every page precedes scoring and only ranked contenders receive live reads", async () => {
  const realFetch = globalThis.fetch;
  const book = createMarketBook();
  let pages = 0, posts = 0;
  const ownerIds: number[] = [], chunks: number[] = [], waits: number[] = [];
  const urls: string[] = [];
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    const u = new URL(url); urls.push(u.pathname);
    if (u.host === "full-ranked") {
      assert.equal(pages, 5);
      const body = JSON.parse(String(init?.body));
      for (const r of Array.isArray(body) ? body : [body]) if (r.method === "eth_call") ownerIds.push(Number(BigInt("0x" + r.params[0].data.slice(10))));
      return Response.json(Array.isArray(body) ? body.map((r: any) => rpcResult(r)).reverse() : rpcResult(body));
    }
    if (u.pathname.includes("/contract/")) return Response.json({ collection: "credits" });
    if (u.pathname.endsWith("/all")) {
      assert.equal(u.searchParams.get("limit"), "200");
      const page = Number(u.searchParams.get("next") ?? 0); pages++;
      return Response.json({ listings: Array.from({ length: page < 4 ? 100 : 1 }, (_, i) => rpcListing(page * 100 + i + 1)), next: page < 4 ? String(page + 1) : null });
    }
    posts++; return osResponse(url, init, []);
  }) as typeof fetch;
  try {
    const result = await fetchListings({ key: "test", fullScan: true, book, rpc: "https://full-ranked", horizon: 0, sign: 1, sleep: async ms => { waits.push(ms); }, getScores: async ids => {
      assert.equal(pages, 5); assert.equal(posts, 0); assert.equal(ownerIds.length, 0); chunks.push(ids.length);
      return ids.map(id => id === "401" ? 1000n : 1n);
    } });
    assert.equal(result.complete, true); assert.equal(result.pages, 5); assert.equal(result.fetched, 401); assert.equal(book.rows.size, 401);
    assert.deepEqual(result.orders.map(o => o.id), ["401"]);
    assert.equal(posts, 1); assert.equal(ownerIds.length, 2); assert.equal(ownerIds[0], 401);
    assert.equal(chunks.reduce((a, b) => a + b), 401); assert.ok(chunks.every(n => n <= 64));
    assert.ok(!urls.some(u => u.endsWith("/best"))); assert.ok(waits.length >= 6);
  } finally { globalThis.fetch = realFetch; }
});

// promise: cursor loops, malformed pages and malformed continuation values fail before scoring, and repeated orders do not duplicate work.
test("OpenSea full scan: strict completion, cursor validation, and order deduplication", async () => {
  const realFetch = globalThis.fetch;
  let mode = "dedupe", pages = 0, scores = 0;
  globalThis.fetch = (async (url: string | URL) => {
    if (new URL(url).pathname.includes("/contract/")) return Response.json({ collection: "credits" });
    pages++;
    if (mode === "shape") return Response.json({ next: null });
    if (mode === "cursor") return Response.json({ listings: [], next: 7 });
    if (mode === "loop") return Response.json({ listings: [], next: "again" });
    return Response.json({ listings: pages === 1 ? [rpcListing(1), rpcListing(2)] : [rpcListing(2), rpcListing(3)], next: pages === 1 ? "second" : null });
  }) as typeof fetch;
  const options = { key: "test", fullScan: true, sign: 0, sleep: async () => {}, getScores: async (ids: string[]) => { scores += ids.length; return ids.map(() => 1n); } };
  try {
    const result = await fetchListings(options);
    assert.equal(result.complete, true); assert.equal(result.pages, 2); assert.equal(result.fetched, 4); assert.equal(result.fit, 3); assert.equal(scores, 3);
    for (mode of ["shape", "cursor", "loop"]) { pages = 0; scores = 0; await assert.rejects(fetchListings(options), /malformed|repeated/); assert.equal(scores, 0); }
  } finally { globalThis.fetch = realFetch; }
});

// promise: price-per-point ordering uses exact integers, and valid zero scores exclude only their own listing.
test("OpenSea full scan: exact ratios and zero score isolation", async () => {
  const realFetch = globalThis.fetch;
  const rows = [rpcListing(1), rpcListing(2), rpcListing(3)];
  for (const [i, price] of ["9007199254740993", "9007199254740992", "1"].entries()) rows[i].protocol_data.parameters.consideration[0].startAmount = rows[i].protocol_data.parameters.consideration[0].endAmount = price;
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => new URL(url).pathname.endsWith("/all") ? Response.json({ listings: rows }) : osResponse(url, init, [])) as typeof fetch;
  try {
    const result = await fetchListings({ key: "test", fullScan: true, sign: 1, sleep: async () => {}, getScores: async () => [1n, 1n, 0n] });
    assert.equal(result.fit, 2); assert.deepEqual(result.orders.map(o => o.id), ["2"]);
    for (const invalid of [[1n], [1n, -1n, 2n], [1n, 1 as any, 2n]]) await assert.rejects(fetchListings({ key: "test", fullScan: true, sign: 1, sleep: async () => {}, getScores: async () => invalid }), /invalid score/);
  } finally { globalThis.fetch = realFetch; }
});

// promise: stale owners and failed individual fulfillments do not hide later ranked listings, while live work remains within twice the signature budget.
test("OpenSea full scan: advances past forty unusable orders without unbounded live work", async () => {
  const realFetch = globalThis.fetch;
  let ownerReads = 0, posts = 0;
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    const u = new URL(url);
    if (u.host === "full-contenders") {
      const body = JSON.parse(String(init?.body));
      const result = (r: any) => {
        if (r.method === "eth_call") {
          ownerReads++; const id = Number(BigInt("0x" + r.params[0].data.slice(10)));
          if (id <= 20) return { jsonrpc: "2.0", id: r.id, error: { code: 3, message: "execution reverted" } };
        }
        return rpcResult(r);
      };
      return Response.json(Array.isArray(body) ? body.map(result) : result(body));
    }
    if (u.pathname.endsWith("/all")) return Response.json({ listings: Array.from({ length: 45 }, (_, i) => rpcListing(i + 1)) });
    if (u.pathname.includes("/fulfillment_data")) { posts++; if (BigInt(JSON.parse(String(init?.body)).listing.hash) <= 40n) return Response.json({}, { status: 404 }); }
    return osResponse(url, init, []);
  }) as typeof fetch;
  try {
    const result = await fetchListings({ key: "test", fullScan: true, rpc: "https://full-contenders", horizon: 0, sign: 40, sleep: async () => {}, getScores: async ids => ids.map(() => 1n) });
    assert.deepEqual(result.orders.map(o => o.id), ["41", "42", "43", "44", "45"]);
    assert.equal(ownerReads, 45); assert.equal(posts, 25); assert.ok(ownerReads <= 80 && posts <= 80);
  } finally { globalThis.fetch = realFetch; }
});

// promise: a full scan serializes and paces every actual API request, including candidate fulfillment.
test("OpenSea full scan: one API request per second and one in flight", async () => {
  const realFetch = globalThis.fetch;
  const starts: number[] = []; let active = 0, maximum = 0;
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    starts.push(Date.now()); active++; maximum = Math.max(maximum, active);
    await new Promise(r => setTimeout(r, 10)); active--;
    return new URL(url).pathname.endsWith("/all") ? Response.json({ listings: [rpcListing(1)] }) : osResponse(url, init, []);
  }) as typeof fetch;
  const keepAlive = setInterval(() => {}, 1000);
  try {
    await fetchListings({ key: "test", fullScan: true, sign: 1, getScores: async () => [1n] });
    assert.equal(starts.length, 3); assert.equal(maximum, 1);
    for (let i = 1; i < starts.length; i++) assert.ok(starts[i] - starts[i - 1] >= 990);
  } finally { clearInterval(keepAlive); globalThis.fetch = realFetch; }
});

// promise: a hanging injected score lookup cannot outlive the full refresh deadline or report completion.
test("OpenSea full scan: injected score lookup honors whole-refresh deadline", async () => {
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => new URL(url).pathname.endsWith("/all") ? Response.json({ listings: [rpcListing(1)] }) : osResponse(url, init, [])) as typeof fetch;
  const keepAlive = setInterval(() => {}, 1000);
  try { await assert.rejects(fetchListings({ key: "test", fullScan: true, sign: 1, timeoutMs: 20, sleep: async () => {}, getScores: async () => new Promise(() => {}) }), /timeout|Timeout/i); }
  finally { clearInterval(keepAlive); globalThis.fetch = realFetch; }
});

// promise: full scans honor API retry budgets and propagate authorization or provider failures instead of publishing an empty complete result.
test("OpenSea full scan:429 retry pacing and global failure semantics", async () => {
  const realFetch = globalThis.fetch;
  let mode = "retry", pages = 0, posts = 0;
  const waits: number[] = [];
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    const u = new URL(url);
    if (u.host === "full-unavailable") return Response.json({}, { status: 503 });
    if (u.pathname.endsWith("/all")) {
      pages++;
      if ((mode === "retry" && pages === 1) || mode === "long-retry") return Response.json({}, { status: 429, headers: { "retry-after": mode === "long-retry" ? "120" : "2" } });
      return Response.json({ listings: [rpcListing(1)] });
    }
    if (u.pathname.endsWith("/fulfillment_data")) { posts++; if (mode === "auth") return Response.json({}, { status: 401 }); }
    return osResponse(url, init, []);
  }) as typeof fetch;
  const opts = { key: "test", fullScan: true, sign: 1, sleep: async (ms: number) => { waits.push(ms); }, getScores: async () => [1n] };
  try {
    const result = await fetchListings(opts);
    assert.equal(result.complete, true); assert.equal(result.pages, 1); assert.equal(pages, 2); assert.equal(posts, 1); assert.ok(waits.includes(2000));
    mode = "long-retry"; pages = 0; posts = 0;
    await assert.rejects(fetchListings(opts), /retry-after/); assert.equal(pages, 1); assert.equal(posts, 0);
    mode = "auth"; pages = 0; posts = 0;
    await assert.rejects(fetchListings(opts), (e: any) => e.name === "OpenSeaAuth401"); assert.equal(posts, 1);
    mode = "rpc"; pages = 0; posts = 0;
    await assert.rejects(fetchListings({ ...opts, rpc: "https://full-unavailable" }), /RPC unavailable/); assert.equal(posts, 0);
    await assert.rejects(fetchListings({ ...opts, getScores: async () => { throw new Error("score provider unavailable"); } }), /score provider unavailable/);
  } finally { globalThis.fetch = realFetch; }
});

// promise: alternative orders remain available until one succeeds, then each token occupies only one signed slot and the validation bound remains explicit.
test("OpenSea full scan: same-token alternatives do not consume multiple signed slots", async () => {
  const realFetch = globalThis.fetch;
  const rows = [rpcListing(1), rpcListing(1), rpcListing(1), rpcListing(2), rpcListing(3)];
  rows.forEach((row, i) => { row.order_hash = abiWord(100 + i); });
  const posted: number[] = [];
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    const u = new URL(url);
    if (u.pathname.endsWith("/all")) return Response.json({ listings: rows });
    if (u.pathname.endsWith("/fulfillment_data")) {
      const hash = Number(BigInt(JSON.parse(String(init?.body)).listing.hash)); posted.push(hash);
      if (hash === 100) return Response.json({}, { status: 404 });
    }
    return osResponse(url, init, []);
  }) as typeof fetch;
  try {
    const result = await fetchListings({ key: "test", fullScan: true, sign: 2, sleep: async () => {}, getScores: async ids => ids.map(() => 1n) });
    assert.deepEqual(result.orders.map(o => o.id), ["1", "2"]); assert.deepEqual(posted, [100, 101, 103]);
    assert.equal(result.complete, true); assert.equal(result.validationTruncated, true);
  } finally { globalThis.fetch = realFetch; }
});

// promise: exhausted page limits and fulfillment rate limits propagate a fixed typed retry deadline and stop subsequent orders.
test("OpenSea full scan: rate limits stop orders and retain provider retry deadlines", async () => {
  const realFetch = globalThis.fetch;
  let mode = "fulfill-long", pageAttempts = 0, posts = 0;
  const retryDate = new Date(Date.now() + 3_600_000).toUTCString();
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    const u = new URL(url);
    if (u.pathname.endsWith("/all")) {
      pageAttempts++;
      if (mode === "page-exhausted") return Response.json({}, { status: 429 });
      if (mode === "page-date") return Response.json({}, { status: 429, headers: { "retry-after": retryDate } });
      return Response.json({ listings: [rpcListing(1), rpcListing(2)] });
    }
    if (u.pathname.endsWith("/fulfillment_data")) {
      posts++;
      return Response.json({ private_provider_message: "must-not-escape" }, { status: 429, headers: { "retry-after": mode === "fulfill-long" ? "600" : "1" } });
    }
    return osResponse(url, init, []);
  }) as typeof fetch;
  const opts = { key: "test", fullScan: true, sign: 2, sleep: async () => {}, getScores: async (ids: string[]) => ids.map(() => 1n) };
  try {
    for (mode of ["fulfill-long", "fulfill-short", "page-exhausted", "page-date"]) {
      posts = 0; pageAttempts = 0;
      const before = Date.now();
      await assert.rejects(fetchListings(opts), (error: unknown) => {
        assert.ok(error instanceof OpenSeaRateLimit);
        assert.equal(error.name, "OpenSeaRateLimit"); assert.ok(Number.isFinite(error.retryAt));
        if (mode === "fulfill-long") assert.ok(error.retryAt >= before + 600_000);
        else if (mode === "page-date") assert.equal(error.retryAt, Date.parse(retryDate));
        else assert.ok(error.retryAt > before);
        assert.doesNotMatch(String(error) + JSON.stringify(error), /must-not-escape/);
        return true;
      });
      assert.equal(posts, mode.startsWith("fulfill") ? 1 : 0);
      assert.equal(pageAttempts, mode === "page-exhausted" ? 4 : 1);
    }
  } finally { globalThis.fetch = realFetch; }
});

// promise: API outages reject a full refresh before later orders, while an individual malformed 200 response still permits a sibling order.
test("OpenSea full scan: provider failures cannot publish an empty complete cache", async () => {
  const realFetch = globalThis.fetch;
  let mode = "503", posts = 0, scored = false;
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    const u = new URL(url);
    if (u.pathname.endsWith("/all")) return Response.json({ listings: [rpcListing(1), rpcListing(2)] });
    if (u.pathname.endsWith("/fulfillment_data")) {
      posts++;
      if (mode === "503") return Response.json({}, { status: 503 });
      if (mode === "network") throw new Error("private-provider-fixture must not escape");
      if (mode === "timeout") return new Promise((_resolve, reject) => init!.signal!.addEventListener("abort", () => reject(init!.signal!.reason), { once: true }));
      if (posts === 1) return new Response("malformed", { headers: { "content-type": "application/json" } });
    }
    return osResponse(url, init, []);
  }) as typeof fetch;
  const keepAlive = setInterval(() => {}, 1000);
  const opts = { key: "test", fullScan: true, sign: 2, sleep: async () => { if (mode === "pace-timeout" && scored) await new Promise(r => setTimeout(r, 20)); }, getScores: async (ids: string[]) => { scored = true; return ids.map(() => 1n); }, fulfillmentTimeoutMs: 10 };
  try {
    for (mode of ["503", "network", "timeout", "pace-timeout"]) {
      posts = 0; scored = false;
      await assert.rejects(fetchListings(opts), (error: unknown) => {
        assert.ok(error instanceof OpenSeaUnavailable);
        assert.doesNotMatch(String(error) + JSON.stringify(error), /private-provider-fixture/);
        return true;
      });
      assert.equal(posts, mode === "pace-timeout" ? 0 : 1);
    }
    mode = "malformed"; posts = 0;
    const result = await fetchListings(opts);
    assert.equal(result.complete, true); assert.deepEqual(result.orders.map(o => o.id), ["2"]); assert.equal(posts, 2);
  } finally { clearInterval(keepAlive); globalThis.fetch = realFetch; }
});

// promise: API spacing follows actual dispatch time even when a pacing timer resumes later than its target.
test("OpenSea full scan: delayed pacing waits cannot bunch physical requests", async () => {
  const realFetch = globalThis.fetch, realNow = Date.now;
  let clock = realNow(); const starts: number[] = [];
  Date.now = () => clock;
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    starts.push(clock);
    return new URL(url).pathname.endsWith("/all") ? Response.json({ listings: [rpcListing(1)] }) : osResponse(url, init, []);
  }) as typeof fetch;
  try {
    await fetchListings({ key: "test", fullScan: true, sign: 1, getScores: async () => [1n], sleep: async ms => { clock += ms + 2000; } });
    assert.equal(starts.length, 3);
    for (let i = 1; i < starts.length; i++) assert.ok(starts[i] - starts[i - 1] >= 1000);
  } finally { Date.now = realNow; globalThis.fetch = realFetch; }
});

// promise: a market book retains every eligible listing, uses incremental canonical updates, reuses signed parameters, and expires/removes stale rows without API polling.
test("OpenSea market book: full baseline, warm reuse, new winner, cancellation, and expiry", async () => {
  const realFetch = globalThis.fetch, realNow = Date.now;
  const book = createMarketBook();
  const counts = { pages: 0, orders: 0, posts: 0, contract: 0 };
  let cancelled = false;
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    const u = new URL(url);
    if (u.pathname.includes("/contract/")) { counts.contract++; return Response.json({ collection: "credits" }); }
    if (u.pathname.endsWith("/all")) { counts.pages++; return Response.json({ listings: [rpcListing(1), rpcListing(2)] }); }
    if (u.pathname.includes("/orders/chain/")) {
      counts.orders++;
      return Response.json({ order: cancelled ? { order_hash: abiWord(3), protocol_address: SEAPORT_16, chain: "ethereum", status: "CANCELLED" } : { ...rpcListing(3), chain: "ethereum", status: "ACTIVE" } });
    }
    counts.posts++; return osResponse(url, init, []);
  }) as typeof fetch;
  const opts = { key: "test", fullScan: true, book, sign: 1, sleep: async () => {}, getScores: async (ids: string[]) => ids.map(id => id === "3" ? 100n : 1n) };
  try {
    const first = await fetchListings(opts);
    assert.equal(first.mode, "full"); assert.equal(book.complete, true); assert.equal(book.rows.size, 2); assert.equal(book.signed.size, 1); assert.ok(book.lastFullAt > 0);
    const before = { ...counts };
    const warm = await fetchListings(opts);
    assert.deepEqual(counts, before); assert.equal(warm.mode, "incremental"); assert.equal(warm.pages, 0); assert.equal(warm.bookSize, 2); assert.equal(warm.reusedParams, 1);
    const updated = await fetchListings({ ...opts, updates: [abiWord(3), abiWord(3)] });
    assert.deepEqual(updated.orders.map(o => o.id), ["3"]); assert.equal(book.rows.size, 3); assert.equal(counts.orders, 1); assert.equal(counts.posts, before.posts + 1); assert.equal(counts.pages, 1); assert.equal(counts.contract, 1);
    cancelled = true;
    const removed = await fetchListings({ ...opts, updates: [abiWord(3)] });
    assert.deepEqual(removed.orders.map(o => o.id), ["1"]); assert.equal(book.rows.has(abiWord(3)), false); assert.equal(book.signed.has(abiWord(3)), false);
    const requests = { ...counts };
    await fetchListings({ ...opts, removals: [abiWord(2)] });
    assert.deepEqual(counts, requests); assert.equal(book.rows.has(abiWord(2)), false);
    Date.now = () => 10_000_000_000_000;
    const expired = await fetchListings(opts);
    assert.equal(expired.complete, true); assert.equal(book.rows.size, 0); assert.equal(book.signed.size, 0); assert.deepEqual(expired.orders, []); assert.deepEqual(counts, requests);
  } finally { Date.now = realNow; globalThis.fetch = realFetch; }
});

// promise: failed incremental passes do not publish partial rows or prepared orders, and wrong order/contract/chain identities never enter a book.
test("OpenSea market book: atomic failure and canonical identity validation", async () => {
  const realFetch = globalThis.fetch;
  const book = createMarketBook(); let mode = "baseline";
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    const u = new URL(url);
    if (u.pathname.endsWith("/all")) return Response.json({ listings: [rpcListing(1)] });
    if (u.pathname.includes("/orders/chain/")) {
      const hash = u.pathname.split("/").at(-1)!;
      if (mode === "atomic" && hash === abiWord(4)) return Response.json({}, { status: 503 });
      const order: any = { ...rpcListing(Number(BigInt(hash))), chain: "ethereum", status: "ACTIVE" };
      if (mode === "hash") order.order_hash = abiWord(99);
      if (mode === "protocol") order.protocol_address = zero;
      if (mode === "collection") order.protocol_data.parameters.offer[0].token = zero;
      if (mode === "chain") order.chain = "base";
      if (mode === "empty-chain") order.chain = {};
      if (mode === "status") order.status = "UNRECOGNIZED";
      if (mode === "wrapper") return Response.json(order);
      return Response.json({ order });
    }
    return osResponse(url, init, []);
  }) as typeof fetch;
  const opts = { key: "test", fullScan: true, book, sign: 1, sleep: async () => {}, getScores: async (ids: string[]) => ids.map(() => 1n) };
  try {
    await fetchListings(opts);
    const rows = book.rows, signed = book.signed, fullAt = book.lastFullAt;
    mode = "atomic";
    await assert.rejects(fetchListings({ ...opts, updates: [abiWord(3), abiWord(4)], removals: [abiWord(1)] }), /HTTP 503/);
    assert.equal(book.rows, rows); assert.equal(book.signed, signed); assert.equal(book.rows.size, 1); assert.equal(book.lastFullAt, fullAt);
    for (mode of ["hash", "protocol", "collection", "chain", "empty-chain", "status", "wrapper"]) {
      await assert.rejects(fetchListings({ ...opts, updates: [abiWord(3)] }), /identity|status/);
      assert.equal(book.rows, rows); assert.equal(book.signed, signed);
    }
    await assert.rejects(fetchListings({ ...opts, fulfiller: zero }), /book identity/);
    await assert.rejects(fetchListings({ ...opts, adapter: zero }), /book identity/);
    assert.equal(book.rows, rows);
  } finally { globalThis.fetch = realFetch; }
});

// promise: an unknown stream order's 404 is retryable without acknowledging it, while canonical absence can remove an already known order.
test("OpenSea market book: REST indexing race retains unknown hash and known 404 removes", async () => {
  const realFetch = globalThis.fetch;
  const book = createMarketBook(); let gets = 0;
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    const path = new URL(url).pathname;
    if (path.endsWith("/all")) return Response.json({ listings: [rpcListing(1)] });
    if (path.includes("/orders/chain/")) { gets++; return Response.json({}, { status: 404 }); }
    return osResponse(url, init, []);
  }) as typeof fetch;
  const opts = { key: "test", fullScan: true, book, sign: 1, sleep: async () => {}, getScores: async () => [1n] };
  try {
    await fetchListings(opts); const rows = book.rows;
    const before = Date.now();
    await assert.rejects(fetchListings({ ...opts, updates: [abiWord(2)] }), (error: unknown) => {
      assert.ok(error instanceof OpenSeaPending); assert.equal(error.hash, abiWord(2)); assert.ok(error.retryAt >= before + 5000); return true;
    });
    assert.equal(book.rows, rows); assert.equal(book.rows.size, 1);
    const removed = await fetchListings({ ...opts, updates: [abiWord(1)] });
    assert.equal(removed.complete, true); assert.equal(book.rows.size, 0); assert.equal(book.signed.size, 0); assert.equal(gets, 2);
  } finally { globalThis.fetch = realFetch; }
});

// promise: an explicit reconciliation replaces stale catalog entries and applies queued removals, rather than retaining only a prepared shortlist.
test("OpenSea market book: reconciliation replaces catalog and honors removals", async () => {
  const realFetch = globalThis.fetch;
  const book = createMarketBook(); let second = false, pages = 0;
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    if (new URL(url).pathname.endsWith("/all")) { pages++; return Response.json({ listings: second ? [rpcListing(2), rpcListing(3)] : [rpcListing(1), rpcListing(2)] }); }
    return osResponse(url, init, []);
  }) as typeof fetch;
  const opts = { key: "test", fullScan: true, book, sign: 1, sleep: async () => {}, getScores: async (ids: string[]) => ids.map(() => 1n) };
  try {
    await fetchListings(opts); second = true;
    const result = await fetchListings({ ...opts, reconcile: true, removals: [abiWord(3)] });
    assert.equal(result.mode, "full"); assert.equal(pages, 2); assert.deepEqual([...book.rows.keys()], [abiWord(2)]); assert.equal(book.signed.has(abiWord(1)), false);
  } finally { globalThis.fetch = realFetch; }
});

// promise: API spacing survives failed passes and applies across all calls sharing one book.
test("OpenSea market book: shared pacing survives update failures", async () => {
  const realFetch = globalThis.fetch, realNow = Date.now;
  const book = createMarketBook(); let clock = realNow(), fail = false;
  const starts: number[] = [];
  Date.now = () => clock;
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    starts.push(clock); const u = new URL(url);
    if (u.pathname.endsWith("/all")) return Response.json({ listings: [rpcListing(1)] });
    if (u.pathname.includes("/orders/chain/")) return fail ? Response.json({}, { status: 503 }) : Response.json({ order: { ...rpcListing(2), chain: "ethereum", status: "ACTIVE" } });
    return osResponse(url, init, []);
  }) as typeof fetch;
  const opts = { key: "test", fullScan: true, book, sign: 1, sleep: async (ms: number) => { clock += ms; }, getScores: async (ids: string[]) => ids.map(id => id === "2" ? 100n : 1n) };
  try {
    await fetchListings(opts); fail = true;
    await assert.rejects(fetchListings({ ...opts, updates: [abiWord(2)] }), /HTTP 503/); fail = false;
    await fetchListings({ ...opts, updates: [abiWord(2)] });
    assert.equal(starts.length, 6);
    for (let i = 1; i < starts.length; i++) assert.ok(starts[i] - starts[i - 1] >= 1000);
  } finally { Date.now = realNow; globalThis.fetch = realFetch; }
});

// promise: a bounded negative-event flood removes known hashes without REST work or blocking the next catalog pass.
test("OpenSea market book: twenty-thousand removals use zero REST requests", async () => {
  const realFetch = globalThis.fetch;
  const book = createMarketBook(); let requests = 0;
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    requests++;
    return new URL(url).pathname.endsWith("/all") ? Response.json({ listings: [rpcListing(1)] }) : osResponse(url, init, []);
  }) as typeof fetch;
  const opts = { key: "test", fullScan: true, book, sign: 1, sleep: async () => {}, getScores: async () => [1n] };
  try {
    await fetchListings(opts); const before = requests;
    const removals = Array.from({ length: 20_000 }, (_, i) => abiWord(i + 1));
    const result = await fetchListings({ ...opts, removals });
    assert.equal(result.mode, "incremental"); assert.equal(result.complete, true); assert.equal(book.rows.size, 0); assert.equal(book.signed.size, 0); assert.equal(requests, before);
    await assert.rejects(fetchListings({ ...opts, removals: [...removals, abiWord(20_001)] }), /too many updates/);
    assert.equal(requests, before);
  } finally { globalThis.fetch = realFetch; }
});
