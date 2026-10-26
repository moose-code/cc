// The OpenSea API v2 fetch of the Credits listings a Seaport 1.6 basic order can fill. Imported by
// script/dev/opensea-listings.mjs (the file input of script/dev/Activity.s.sol) and by keeper/ (the Seaport sweep).
// Plain JavaScript with no dependencies so the dev script runs with a bare node.
//
// a listing is kept when it has one ERC721 offer item of Credits, native consideration items with equal start and end
// amounts, the first paid to the offerer, an open order type, every other recipient the offerer or an address the
// adapter allows, and an end time in the future. the allowlist comes from allowedRecipient(address) of the adapter at
// `rpc`, or from `allowedRecipients` without an rpc; the default is the launch entry, the OpenSea fee collector.
//
// the listing pages carry no signature. the listings are ranked by price over score (the order in which a bid scaled by
// score reaches them), and the signature of the cheapest `sign` of them comes from the fulfillment_data endpoint, whose
// parameters are the BasicOrderParameters of the order. without a score lookup the ranking is by price.
//
// every number of an order is a decimal string. params carries the fields of BasicOrderParameters, built the way
// test/Seaport.t.sol _basicData builds them. `hash` is the Seaport order hash OpenSea reports.

import { setTimeout as delay } from "node:timers/promises";

export const CREDITS = "0x97630aa70ab14ed9883b41dafccbc11349723043";
export const SEAPORT_16 = "0x0000000000000068f116a894984e2db1123eb395";
export const OPENSEA_FEE = "0x0000a26b00c1f0df003000390027140000faa719";
const ZERO = "0x0000000000000000000000000000000000000000";
const ZERO32 = "0x" + "0".repeat(64);
const RPC_BATCH_SIZE = 20;
const rpcNextStart = new Map();
const bookQueues = new WeakMap();
export function createMarketBook() { return { rows: new Map(), signed: new Map(), complete: false, lastFullAt: 0, apiNext: 0 }; }
export class OpenSeaPending extends Error {
  constructor(retryAt, hash) { super("opensea: order not indexed yet"); this.name = "OpenSeaPending"; this.retryAt = retryAt; this.hash = hash; }
}
class RpcUnavailable extends Error { name = "RpcUnavailable"; }
class OpenSeaHttpFailure extends Error {
  constructor(status) { super(`opensea: HTTP ${status}`); this.name = `OpenSeaHTTP${status}`; }
}
class OpenSeaAuthFailure extends Error {
  constructor(status) { super("opensea: fulfillment authorization failed"); this.name = `OpenSeaAuth${status}`; }
}
export class OpenSeaUnavailable extends Error {
  constructor() { super("opensea: API unavailable"); this.name = "OpenSeaUnavailable"; }
}
export class OpenSeaRateLimit extends Error {
  constructor(retryAt) { super("opensea: rate limited; honor retry-after"); this.name = "OpenSeaRateLimit"; this.retryAt = retryAt; }
}
const reverted = (error) => error?.code === 3 || /execution reverted/i.test(error?.message ?? "");
// selector of allowedRecipient(address), the public mapping getter of SeaportBasicAdapter
const SELECTOR = "0xdb846026";
// CreditScore and the selectors of seedOf(uint256), timestampOf(uint256), scoreOf(bytes21,uint64)
const SC = "0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7";
const SEED_SEL = "82829f74";
const TIME_SEL = "2d9c77e1";
const SCORE_SEL = "8c08f632";

const same = (a, b) => a.toLowerCase() === b.toLowerCase();
const native = (it) => it.itemType === 0 && same(it.token, ZERO) && it.startAmount === it.endAmount;
const word = (id) => BigInt(id).toString(16).padStart(64, "0");

/**
 * @param {object} o
 * @param {string} o.key OpenSea API key, from the caller's environment only
 * @param {string} [o.rpc] node for single-URL dev callers
 * @param {string[]} [o.rpcUrls] ordered nodes for the allowlist, holder check and score ranking
 * @param {string} [o.adapter] SeaportBasicAdapter whose allowedRecipient is the allowlist
 * @param {number} [o.pages] listing pages of 100 for bounded dev calls, default 3
 * @param {boolean} [o.fullScan] scan every listing page before ranking, paced to one API request per second
 * @param {(ids: string[]) => Promise<bigint[]>} [o.getScores] immutable score lookup, called with at most 64 unique ids
 * @param {object} [o.book] caller-owned catalog and prepared order cache, from createMarketBook
 * @param {string[]} [o.updates] hashes to refresh from canonical order details
 * @param {string[]} [o.removals] hashes to remove before applying updates
 * @param {boolean} [o.reconcile] replace the catalog from a complete collection scan
 * @param {number} [o.sign] successful signed orders kept, default 40; full scans inspect at most twice this many contenders
 * @param {string} [o.fulfiller] fulfiller address sent to fulfillment_data
 * @param {string[]} [o.allowedRecipients] allowlist without an rpc, default the OpenSea fee collector
 * @param {number} [o.horizon] seconds past the head block an order may start at and still be kept, default 86400
 * @param {number} [o.timeoutMs] maximum time for the whole refresh, default 30000, or 1800000 for a full scan
 * @param {number} [o.fulfillmentTimeoutMs] maximum time per fulfillment request, default 8000
 * @param {(n: number) => Promise<void>} [o.sleep]
 */
export async function fetchListings(o) {
  const { key, adapter } = o;
  const rpcUrls = [...new Set(o.rpcUrls ?? (o.rpc ? [o.rpc] : []))];
  const hasRpc = rpcUrls.length > 0;
  const fullScan = o.fullScan === true;
  const book = o.book;
  if (book && !fullScan) throw new Error("opensea: market book requires full scan mode");
  const mode = book?.complete && !o.reconcile ? "incremental" : "full";
  const hashesOf = values => [...new Set((values ?? []).map(hash => {
    if (typeof hash !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(hash)) throw new Error("opensea: invalid update hash");
    return hash.toLowerCase();
  }))];
  const updates = hashesOf(o.updates);
  const removals = hashesOf(o.removals);
  if (updates.length > 1000 || removals.length > 20_000) throw new Error("opensea: too many updates");
  const maxPages = fullScan ? Infinity : (o.pages ?? 3);
  const sign = o.sign ?? 40;
  const fulfiller = o.fulfiller ?? "0x1111111111111111111111111111111111111111";
  const signal = AbortSignal.timeout(o.timeoutMs ?? (fullScan ? 30 * 60_000 : 30_000));
  if (fullScan && !hasRpc && !o.getScores) throw new Error("opensea: full discovery requires scores");
  const sleep = (ms, requestSignal = signal) => o.sleep ? o.sleep(ms) : delay(ms, undefined, { signal: requestSignal });
  const envAllowed = (o.allowedRecipients ?? [OPENSEA_FEE]).map((a) => a.toLowerCase());
  const headers = { "x-api-key": key, accept: "application/json" };
  const identity = JSON.stringify(["ethereum", CREDITS, SEAPORT_16, adapter?.toLowerCase() ?? null, fulfiller.toLowerCase(), [...envAllowed].sort(), o.horizon ?? 86400]);
  if (book && ((book.identity && book.identity !== identity) || (!book.identity && (book.complete || book.rows.size || book.signed.size)))) throw new Error("opensea: market book identity mismatch");
  let stagedRows = book ? new Map([...book.rows].map(([hash, row]) => [hash, { ...row }])) : undefined;
  const stagedSigned = new Map(book?.signed ?? []);

  async function rpcCall(body) {
    const requests = Array.isArray(body) ? body : [body];
    for (const url of rpcUrls) {
      try {
        signal.throwIfAborted();
        const start = Math.max(Date.now(), rpcNextStart.get(url) ?? 0);
        rpcNextStart.set(url, start + 250);
        if (start > Date.now()) await delay(start - Date.now(), undefined, { signal });
        signal.throwIfAborted();
        const requestSignal = AbortSignal.any([signal, AbortSignal.timeout(8_000)]);
        const response = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal: requestSignal });
        if (!response.ok) throw new RpcUnavailable("opensea: RPC HTTP failure");
        const value = await response.json();
        if (Array.isArray(body) !== Array.isArray(value)) throw new RpcUnavailable("opensea: RPC response shape");
        const rows = Array.isArray(value) ? value : [value];
        const byId = new Map(rows.map((row) => [row?.id, row]));
        if (rows.length !== requests.length || byId.size !== requests.length) throw new RpcUnavailable("opensea: RPC response IDs");
        for (const request of requests) {
          const row = byId.get(request.id);
          if (!row || row.jsonrpc !== "2.0" || ("error" in row) === ("result" in row)) throw new RpcUnavailable("opensea: RPC response ID");
          if (row.error) {
            if (request.method !== "eth_call" || !reverted(row.error)) throw new RpcUnavailable("opensea: RPC provider failure");
          } else if (request.method === "eth_call" ? !/^0x[0-9a-fA-F]{64}$/.test(row.result ?? "")
            : !/^0x[0-9a-fA-F]+$/.test(row.result?.timestamp ?? "")) throw new RpcUnavailable("opensea: RPC result shape");
        }
        return value;
      } catch (error) {
        if (signal.aborted) throw error;
      }
    }
    throw new RpcUnavailable("opensea: RPC unavailable");
  }
  async function batch(calls) {
    const out = [];
    for (let offset = 0; offset < calls.length; offset += RPC_BATCH_SIZE) {
      const part = calls.slice(offset, offset + RPC_BATCH_SIZE);
      const rows = await rpcCall(part.map((c, id) => ({ jsonrpc: "2.0", id, method: "eth_call", params: [c, "latest"] })));
      out.push(...rows.sort((a, b) => a.id - b.id).map((row) => row.error ? undefined : row.result));
    }
    return out;
  }

  const allowedCache = new Map();
  async function allowed(addr) {
    const a = addr.toLowerCase();
    if (!hasRpc || !adapter) return envAllowed.includes(a);
    if (!allowedCache.has(a)) {
      const data = SELECTOR + a.slice(2).padStart(64, "0");
      const r = await rpcCall({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to: adapter, data }, "latest"] });
      if (r.error) throw new RpcUnavailable("opensea: allowlist read failed");
      allowedCache.set(a, BigInt(r.result) !== 0n);
    }
    return allowedCache.get(a);
  }

  let apiNext = 0;
  let apiQueue = Promise.resolve();
  async function api(url, options = {}, requestSignal = signal) {
    const run = async () => {
      requestSignal.throwIfAborted();
      if (fullScan) {
        const start = Math.max(Date.now(), book?.apiNext ?? apiNext);
        if (start > Date.now()) await sleep(start - Date.now(), requestSignal);
        requestSignal.throwIfAborted();
        apiNext = Date.now() + 1000;
        if (book) book.apiNext = apiNext;
      }
      const physicalSignal = fullScan ? AbortSignal.any([requestSignal, AbortSignal.timeout(10_000)]) : requestSignal;
      try {
        const res = await fetch(url, { headers, ...options, signal: physicalSignal });
        let body;
        if (res.ok) {
          try { body = await res.json(); }
          catch (error) { if (!(fullScan && options.method === "POST" && error instanceof SyntaxError)) throw error; }
        } else await res.body?.cancel();
        return { res, body };
      } catch (error) { if (fullScan && !signal.aborted) throw new OpenSeaUnavailable(); throw error; }
    };
    if (!fullScan) return run();
    const pending = (book ? bookQueues.get(book) ?? Promise.resolve() : apiQueue).then(run).catch(error => { if (signal.aborted) throw error; throw new OpenSeaUnavailable(); });
    apiQueue = pending.catch(() => {});
    if (book) bookQueues.set(book, apiQueue);
    return pending;
  }
  function retryMs(res, fallback) {
    const value = res.headers.get("retry-after");
    const ms = value == null ? fallback : /^\d+(?:\.\d+)?$/.test(value) ? Number(value) * 1000 : Date.parse(value) - Date.now();
    const wait = Math.max(fallback, Number.isFinite(ms) ? ms : fallback);
    if (wait > 30_000) throw new OpenSeaRateLimit(Date.now() + wait);
    return wait;
  }

  async function withinDeadline(promise) {
    let abort;
    try {
      return await Promise.race([promise, new Promise((_, reject) => {
        abort = () => reject(signal.reason);
        signal.addEventListener("abort", abort, { once: true });
        if (signal.aborted) abort();
      })]);
    } finally { signal.removeEventListener("abort", abort); }
  }

  async function get(url, allowMissing = false) {
    for (let attempt = 0; attempt < 4; ++attempt) {
      const { res, body } = await api(url);
      if (res.status === 429) {
        const wait = retryMs(res, 1500 * (attempt + 1));
        if (attempt === 3) throw new OpenSeaRateLimit(Date.now() + wait);
        await sleep(wait);
        continue;
      }
      if (allowMissing && res.status === 404) return undefined;
      if (!res.ok) throw new OpenSeaHttpFailure(res.status);
      return body;
    }
    throw new OpenSeaRateLimit(Date.now() + 300_000);
  }

  // the best (cheapest) active listing of every token of the collection, cheapest first
  async function page(slug, cursor) {
    const url = new URL(`https://api.opensea.io/api/v2/listings/collection/${slug}/${fullScan ? "all" : "best"}`);
    url.searchParams.set("limit", fullScan ? "200" : "100");
    if (cursor) url.searchParams.set("next", cursor);
    return get(url);
  }

  // returns the entry, or the reason the listing does not fit a basic order
  async function convert(l) {
    if (!l.protocol_data) return "no protocol data";
    if (!same(l.protocol_address ?? "", SEAPORT_16)) return "not seaport 1.6";
    const p = l.protocol_data.parameters;
    if (p.offer.length !== 1) return "offer is not one item";
    const off = p.offer[0];
    if (off.itemType !== 2 || !same(off.token, CREDITS) || off.startAmount !== "1" || off.endAmount !== "1")
      return "offer is not one Credits token";
    if (p.orderType > 1) return "restricted order type";
    if (p.consideration.length === 0 || !p.consideration.every(native)) return "consideration is not native eth";
    if (!same(p.consideration[0].recipient, p.offerer)) return "first payout is not the offerer";
    if (!/^\d+$/.test(String(p.startTime ?? "")) || !/^\d+$/.test(String(p.endTime ?? ""))) return "malformed order time";
    if (Number(p.endTime) <= Date.now() / 1000) return "expired";
    const extra = p.consideration.slice(1);
    for (const c of extra) {
      if (!same(c.recipient, p.offerer) && !(await allowed(c.recipient))) return "recipient not allowed";
    }
    const price = p.consideration.reduce((s, c) => s + BigInt(c.startAmount), 0n);
    if (price <= 0n) return "nonpositive price";
    return { id: off.identifierOrCriteria, price: price.toString(), offerer: p.offerer, startTime: String(p.startTime), endTime: String(p.endTime), hash: l.order_hash };
  }

  // score of every id through batched eth_calls; ids that do not exist map to 0
  async function scores(ids) {
    const seeds = await batch(ids.map((id) => ({ to: CREDITS, data: "0x" + SEED_SEL + word(id) })));
    const times = await batch(ids.map((id) => ({ to: CREDITS, data: "0x" + TIME_SEL + word(id) })));
    const sc = await batch(
      ids.map((_, i) => ({ to: SC, data: "0x" + SCORE_SEL + (seeds[i] ?? "0x").slice(2, 66).padEnd(64, "0") + (times[i] ?? "0x").slice(2).padStart(64, "0") })),
    );
    return sc.map((x) => (x && x !== "0x" ? BigInt(x) : 0n));
  }

  async function fulfillment(hash) {
    const requestSignal = AbortSignal.any([signal, AbortSignal.timeout(o.fulfillmentTimeoutMs ?? 8_000)]);
    let res, body;
    for (let attempt = 0; attempt < 4; ++attempt) {
      ({ res, body } = await api("https://api.opensea.io/api/v2/listings/fulfillment_data", {
        method: "POST",
        headers: { ...headers, "content-type": "application/json" },
        body: JSON.stringify({ listing: { hash, chain: "ethereum", protocol_address: SEAPORT_16 }, fulfiller: { address: fulfiller } }),
      }, requestSignal));
      if (res.status !== 429) break;
      const wait = retryMs(res, 1000 * (attempt + 1));
      if (fullScan || attempt === 3) throw new OpenSeaRateLimit(Date.now() + wait);
      await sleep(wait, requestSignal);
    }
    if (res.status === 401 || res.status === 403) throw new OpenSeaAuthFailure(res.status);
    if (!res.ok) {
      if (fullScan && res.status !== 400 && res.status !== 404) throw new OpenSeaUnavailable();
      return null;
    }
    const tx = body?.fulfillment_data?.transaction;
    if (!tx || !tx.function?.startsWith("fulfillBasicOrder_efficient_6GL6yc")) return null;
    return tx.input_data.parameters;
  }

  function inactive(order) {
    for (const flag of ["cancelled", "canceled", "finalized", "marked_invalid"]) if (order[flag] !== undefined && typeof order[flag] !== "boolean") throw new Error("opensea: malformed order status");
    if (order.status !== undefined && !["ACTIVE", "INACTIVE", "FULFILLED", "EXPIRED", "CANCELLED", "CANCELED"].includes(order.status)) throw new Error("opensea: malformed order status");
    return ["INACTIVE", "FULFILLED", "EXPIRED", "CANCELLED", "CANCELED"].includes(order.status) || order.cancelled || order.canceled || order.finalized || order.marked_invalid;
  }
  const slug = book?.slug ?? (await get(new URL(`https://api.opensea.io/api/v2/chain/ethereum/contract/${CREDITS}`))).collection;
  if (typeof slug !== "string" || !slug.length) throw new Error("opensea: malformed collection identity");
  let fetched = 0;
  let cands = [];
  const dropped = {};
  let cursor;
  let pages = 0;
  let complete = mode === "incremental";
  const cursors = new Set();
  const hashes = new Set();
  for (let i = 0; mode === "full" && i < maxPages; ++i) {
    const body = await page(slug, cursor);
    pages++;
    if (fullScan && !Array.isArray(body.listings)) throw new Error("opensea: malformed listing page");
    for (const l of body.listings ?? []) {
      ++fetched;
      let r;
      try {
        r = fullScan && inactive(l) ? "inactive" : await convert(l);
      } catch (e) {
        if (signal.aborted || e instanceof RpcUnavailable) throw e;
        dropped["malformed listing"] = (dropped["malformed listing"] ?? 0) + 1;
        continue;
      }
      if (typeof r === "string") dropped[r] = (dropped[r] ?? 0) + 1;
      else {
        if (fullScan) {
          if (!/^0x[0-9a-fA-F]{64}$/.test(r.hash ?? "")) { dropped["malformed listing"] = (dropped["malformed listing"] ?? 0) + 1; continue; }
          const hash = r.hash.toLowerCase();
          if (hashes.has(hash)) continue;
          hashes.add(hash);
        }
        cands.push(r);
      }
    }
    cursor = body.next;
    if (fullScan && cursor != null && (typeof cursor !== "string" || !cursor.trim() || cursor !== cursor.trim())) throw new Error("opensea: malformed listing cursor");
    if (!cursor) { complete = true; break; }
    if (fullScan && cursors.has(cursor)) throw new Error("opensea: repeated listing cursor");
    cursors.add(cursor);
  }
  if (book) {
    if (mode === "full") stagedRows = new Map(cands.map(row => [row.hash.toLowerCase(), { ...row, hash: row.hash.toLowerCase() }]));
    for (const hash of removals) { stagedRows.delete(hash); stagedSigned.delete(hash); }
    for (const hash of updates) {
      const body = await get(new URL(`https://api.opensea.io/api/v2/orders/chain/ethereum/protocol/${SEAPORT_16}/${hash}`), true);
      if (body === undefined) {
        if (!stagedRows.has(hash)) throw new OpenSeaPending(Date.now() + 5000, hash);
        stagedRows.delete(hash); stagedSigned.delete(hash); continue;
      }
      fetched++;
      const order = body?.order;
      const chain = typeof order?.chain === "string" ? order.chain : order?.chain?.name;
      const offer = order?.protocol_data?.parameters?.offer;
      if (!order || typeof order.order_hash !== "string" || order.order_hash.toLowerCase() !== hash || typeof order.protocol_address !== "string" || !same(order.protocol_address, SEAPORT_16) || (order.chain !== undefined && chain !== "ethereum")) throw new Error("opensea: order identity mismatch");
      if (inactive(order)) { stagedRows.delete(hash); stagedSigned.delete(hash); continue; }
      const consideration = order?.protocol_data?.parameters?.consideration;
      if (!Array.isArray(offer) || !Array.isArray(consideration)) throw new Error("opensea: malformed order details");
      // Revalidation includes bids and bundles; collection identity is separate from basic listing eligibility.
      if (![...offer, ...consideration].some(item => [2, 3, 4, 5].includes(item?.itemType) && typeof item.token === "string" && same(item.token, CREDITS))) throw new Error("opensea: order identity mismatch");
      const row = await convert(order);
      if (typeof row === "string") { stagedRows.delete(hash); stagedSigned.delete(hash); continue; }
      if (stagedRows.has(hash) && stagedRows.get(hash).id !== row.id) throw new Error("opensea: order identity mismatch");
      stagedRows.set(hash, { ...row, hash });
    }
    for (const [hash, row] of stagedRows) if (Number(row.endTime) <= Date.now() / 1000) { stagedRows.delete(hash); stagedSigned.delete(hash); }
    for (const hash of stagedSigned.keys()) if (!stagedRows.has(hash)) stagedSigned.delete(hash);
    cands = [...stagedRows.values()].map(row => ({ ...row }));
  }
  let notHeld = 0;
  async function held(rows) {
    if (!hasRpc || !rows.length) return rows;
    const owners = await batch(rows.map((c) => ({ to: CREDITS, data: "0x6352211e" + word(c.id) })));
    const head = await rpcCall({ jsonrpc: "2.0", id: 1, method: "eth_getBlockByNumber", params: ["latest", false] });
    const horizon = parseInt(head.result.timestamp, 16) + (o.horizon ?? 86400);
    const valid = rows.filter((c, i) => owners[i] && ("0x" + owners[i].slice(26)).toLowerCase() === c.offerer.toLowerCase() && Number(c.startTime) <= horizon);
    notHeld += rows.length - valid.length;
    return valid;
  }
  if (!fullScan) cands = await held(cands);
  if ((hasRpc || o.getScores) && cands.length) {
    const ids = [...new Set(cands.map(c => c.id))];
    let sc;
    if (o.getScores) {
      sc = [];
      for (let i = 0; i < ids.length; i += 64) {
        signal.throwIfAborted();
        const part = ids.slice(i, i + 64);
        const values = await withinDeadline(o.getScores(part));
        signal.throwIfAborted();
        if (!Array.isArray(values) || values.length !== part.length || values.some(v => typeof v !== "bigint" || v < 0n)) throw new RpcUnavailable("opensea: invalid score lookup");
        sc.push(...values);
      }
    } else sc = await scores(ids);
    const byId = new Map(ids.map((id, i) => [id, sc[i]]));
    cands = cands.filter(c => byId.get(c.id) > 0n);
    cands.forEach(c => { c.score = byId.get(c.id); });
  }
  cands.sort((a, b) => {
    const left = BigInt(a.price) * (b.score ?? 1n);
    const right = BigInt(b.price) * (a.score ?? 1n);
    return left < right ? -1 : left > right ? 1 : 0;
  });
  const orders = [];
  const signedIds = new Set();
  const contenders = cands.slice(0, fullScan ? 2 * sign : sign);
  const checked = fullScan ? await held(contenders.filter(row => !stagedSigned.has(row.hash))) : contenders;
  const valid = new Set(checked.map(row => row.hash));
  const top = fullScan ? contenders.filter(row => stagedSigned.has(row.hash) || valid.has(row.hash)) : contenders;
  let reusedParams = 0;
  const fetchedParams = [];
  const fulfillmentOf = async (c) => {
    try {
      return await fulfillment(c.hash);
    } catch (e) {
      if (e instanceof OpenSeaAuthFailure || e instanceof OpenSeaRateLimit || e instanceof OpenSeaUnavailable || (fullScan && signal.aborted)) throw e;
      dropped["fulfillment request failed"] = (dropped["fulfillment request failed"] ?? 0) + 1;
      return null;
    }
  };
  if (!fullScan) for (let i = 0; i < top.length; i += 8) fetchedParams.push(...(await Promise.all(top.slice(i, i + 8).map(fulfillmentOf))));
  for (const [i, c] of top.entries()) {
    if (orders.length >= sign) break;
    if (fullScan && signedIds.has(c.id)) continue;
    const prepared = book ? stagedSigned.get(c.hash) : undefined;
    if (prepared) reusedParams++;
    const p = prepared?.params ?? (fullScan ? await fulfillmentOf(c) : fetchedParams[i]);
    if (!p) {
      dropped["no basic fulfillment data"] = (dropped["no basic fulfillment data"] ?? 0) + 1;
      continue;
    }
    try {
      const order = { id: c.id, price: c.price, hash: c.hash, params: basicParams(p) };
      orders.push(order);
      if (book) stagedSigned.set(c.hash, order);
      signedIds.add(c.id);
    } catch (e) {
      dropped["malformed fulfillment"] = (dropped["malformed fulfillment"] ?? 0) + 1;
    }
  }
  if (fullScan) signal.throwIfAborted();
  if (book) {
    book.rows = stagedRows; book.signed = stagedSigned; book.complete = complete; book.slug = slug; book.identity = identity;
    if (mode === "full") book.lastFullAt = Date.now();
  }
  return { fetched, fit: cands.length, notHeld, orders, dropped, complete, pages, validationTruncated: fullScan && cands.length > 2 * sign, mode, bookSize: stagedRows?.size ?? cands.length, reusedParams };
}

// BasicOrderParameters of a fulfillment_data answer, every number a decimal string
export function basicParams(p) {
  return {
    considerationToken: p.considerationToken,
    considerationIdentifier: String(p.considerationIdentifier),
    considerationAmount: String(p.considerationAmount),
    offerer: p.offerer,
    zone: p.zone,
    offerToken: p.offerToken,
    offerIdentifier: String(p.offerIdentifier),
    offerAmount: String(p.offerAmount),
    basicOrderType: String(p.basicOrderType),
    startTime: String(p.startTime),
    endTime: String(p.endTime),
    zoneHash: p.zoneHash,
    salt: String(p.salt),
    offererConduitKey: p.offererConduitKey,
    fulfillerConduitKey: p.fulfillerConduitKey ?? ZERO32,
    totalOriginalAdditionalRecipients: String(p.totalOriginalAdditionalRecipients),
    additionalRecipients: p.additionalRecipients.map((r) => ({ amount: String(r.amount), recipient: r.recipient })),
    signature: p.signature,
  };
}

// the collection's best flat bid: the highest unexpired collection offer (no trait criteria) in ETH or WETH, per item
// (the offer's value over its readable item count), from OpenSea's offers endpoint. `slug` is read from the contract when not given. returns undefined when OpenSea does
// not answer, so a caller keeps its last observation and never posts a floor it did not see. no listing book is
// touched; the call is one GET, retried once on 429
export async function fetchCollectionBid({ key, slug, signal } = {}) {
  if (!key) return undefined;
  const headers = { accept: "application/json", "x-api-key": key };
  const get = async (url) => {
    for (let attempt = 0; attempt < 2; ++attempt) {
      const res = await fetch(url, { headers, signal: signal ?? AbortSignal.timeout(10_000) });
      if (res.status === 429 && attempt === 0) {
        await res.body?.cancel();
        await new Promise(r => setTimeout(r, 1500));
        continue;
      }
      if (!res.ok) { await res.body?.cancel(); return undefined; }
      return res.json();
    }
    return undefined;
  };
  const s = slug ?? (await get(new URL(`https://api.opensea.io/api/v2/chain/ethereum/contract/${CREDITS}`)))?.collection;
  if (!s) return undefined;
  const url = new URL(`https://api.opensea.io/api/v2/offers/collection/${s}`);
  const body = await get(url);
  const offers = Array.isArray(body?.offers) ? body.offers : undefined;
  if (!offers) return undefined;
  let best;
  for (const o of offers) {
    if (o?.criteria?.trait) continue;
    const currency = String(o?.price?.currency ?? "").toUpperCase();
    if (currency !== "ETH" && currency !== "WETH") continue;
    if (Number(o?.price?.decimals ?? 18) !== 18) continue;
    const value = o?.price?.value;
    if (typeof value !== "string" || !/^\d+$/.test(value)) continue;
    // the offer's item count is the criteria consideration's amount; an offer whose count cannot be read is dropped,
    // never taken as one item (a ten item offer read as one would post ten times the bid)
    const params = o?.protocol_data?.parameters;
    const qtyRaw = params?.consideration?.[0]?.startAmount;
    if (typeof qtyRaw !== "string" || !/^\d+$/.test(qtyRaw) || BigInt(qtyRaw) === 0n) continue;
    const qty = BigInt(qtyRaw);
    // an offer past its end time, or with an end time that cannot be read, is not a bid anyone can fill
    const endRaw = params?.endTime;
    const end = typeof endRaw === "string" && /^\d+$/.test(endRaw) ? Number(endRaw) : typeof endRaw === "number" ? endRaw : NaN;
    if (!Number.isFinite(end) || end <= Math.floor(Date.now() / 1000)) continue;
    const perItem = BigInt(value) / qty;
    if (perItem === 0n) continue;
    if (!best || perItem > best.bidWei) best = { bidWei: perItem, hash: typeof o.order_hash === "string" ? o.order_hash : undefined, slug: s };
  }
  return best;
}
