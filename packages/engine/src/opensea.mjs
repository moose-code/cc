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
// parameters are the BasicOrderParameters of the order. without `rpc` the ranking is by price.
//
// every number of an order is a decimal string. params carries the fields of BasicOrderParameters, built the way
// test/Seaport.t.sol _basicData builds them. `hash` is the Seaport order hash OpenSea reports.

import { setTimeout as delay } from "node:timers/promises";

export const CREDITS = "0x97630aa70ab14ed9883b41dafccbc11349723043";
export const SEAPORT_16 = "0x0000000000000068f116a894984e2db1123eb395";
export const OPENSEA_FEE = "0x0000a26b00c1f0df003000390027140000faa719";
const ZERO = "0x0000000000000000000000000000000000000000";
const ZERO32 = "0x" + "0".repeat(64);
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
 * @param {string} [o.rpc] node for the allowlist, the holder check and the score ranking
 * @param {string} [o.adapter] SeaportBasicAdapter whose allowedRecipient is the allowlist
 * @param {number} [o.pages] listing pages of 100, default 3
 * @param {number} [o.sign] signatures fetched for the cheapest, default 40
 * @param {string} [o.fulfiller] fulfiller address sent to fulfillment_data
 * @param {string[]} [o.allowedRecipients] allowlist without an rpc, default the OpenSea fee collector
 * @param {number} [o.horizon] seconds past the head block an order may start at and still be kept, default 86400
 * @param {number} [o.timeoutMs] maximum time for the whole refresh, default 30000
 * @param {number} [o.fulfillmentTimeoutMs] maximum time per fulfillment request, default 8000
 * @param {(n: number) => Promise<void>} [o.sleep]
 */
export async function fetchListings(o) {
  const { key, rpc, adapter } = o;
  const maxPages = o.pages ?? 3;
  const sign = o.sign ?? 40;
  const fulfiller = o.fulfiller ?? "0x1111111111111111111111111111111111111111";
  const signal = AbortSignal.timeout(o.timeoutMs ?? 30_000);
  const sleep = (ms, requestSignal = signal) => o.sleep ? o.sleep(ms) : delay(ms, undefined, { signal: requestSignal });
  const envAllowed = (o.allowedRecipients ?? [OPENSEA_FEE]).map((a) => a.toLowerCase());
  const headers = { "x-api-key": key, accept: "application/json" };

  async function rpcCall(body) {
    const r = await fetch(rpc, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal });
    return r.json();
  }
  async function batch(calls) {
    const r = await rpcCall(calls.map((c, i) => ({ jsonrpc: "2.0", id: i, method: "eth_call", params: [c, "latest"] })));
    return r.sort((a, b) => a.id - b.id).map((x) => x.result);
  }

  const allowedCache = new Map();
  async function allowed(addr) {
    const a = addr.toLowerCase();
    if (!rpc || !adapter) return envAllowed.includes(a);
    if (!allowedCache.has(a)) {
      const data = SELECTOR + a.slice(2).padStart(64, "0");
      const r = await rpcCall({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to: adapter, data }, "latest"] });
      allowedCache.set(a, BigInt(r.result ?? "0x0") !== 0n);
    }
    return allowedCache.get(a);
  }

  async function get(url) {
    for (let attempt = 0; attempt < 4; ++attempt) {
      const res = await fetch(url, { headers, signal });
      if (res.status === 429) {
        await sleep(1500 * (attempt + 1));
        continue;
      }
      if (!res.ok) throw new Error(`opensea: HTTP ${res.status} for ${url.pathname}`);
      return res.json();
    }
    throw new Error("opensea: rate limited");
  }

  // the best (cheapest) active listing of every token of the collection, cheapest first
  async function page(slug, cursor) {
    const url = new URL(`https://api.opensea.io/api/v2/listings/collection/${slug}/best`);
    url.searchParams.set("limit", "100");
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
    if (Number(p.endTime) <= Date.now() / 1000) return "expired";
    const extra = p.consideration.slice(1);
    for (const c of extra) {
      if (!same(c.recipient, p.offerer) && !(await allowed(c.recipient))) return "recipient not allowed";
    }
    const price = p.consideration.reduce((s, c) => s + BigInt(c.startAmount), 0n);
    if (price <= 0n) return "nonpositive price";
    return { id: off.identifierOrCriteria, price: price.toString(), offerer: p.offerer, startTime: String(p.startTime), hash: l.order_hash };
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
    let res;
    for (let attempt = 0; attempt < 4; ++attempt) {
      res = await fetch("https://api.opensea.io/api/v2/listings/fulfillment_data", {
        method: "POST",
        headers: { ...headers, "content-type": "application/json" },
        body: JSON.stringify({ listing: { hash, chain: "ethereum", protocol_address: SEAPORT_16 }, fulfiller: { address: fulfiller } }),
        signal: requestSignal,
      });
      if (res.status !== 429) break;
      await sleep(1000 * (attempt + 1), requestSignal);
    }
    if (!res.ok) return null;
    const tx = (await res.json()).fulfillment_data?.transaction;
    if (!tx || !tx.function?.startsWith("fulfillBasicOrder_efficient_6GL6yc")) return null;
    return tx.input_data.parameters;
  }

  const slug = (await get(new URL(`https://api.opensea.io/api/v2/chain/ethereum/contract/${CREDITS}`))).collection;
  let fetched = 0;
  let cands = [];
  const dropped = {};
  let cursor;
  for (let i = 0; i < maxPages; ++i) {
    const body = await page(slug, cursor);
    for (const l of body.listings ?? []) {
      ++fetched;
      let r;
      try {
        r = await convert(l);
      } catch (e) {
        if (signal.aborted) throw e;
        dropped["malformed listing"] = (dropped["malformed listing"] ?? 0) + 1;
        continue;
      }
      if (typeof r === "string") dropped[r] = (dropped[r] ?? 0) + 1;
      else cands.push(r);
    }
    cursor = body.next;
    if (!cursor) break;
  }
  let notHeld = 0;
  if (rpc && cands.length) {
    // keep the listings the node can fill: the offerer owns the credit now and the order has started by the head block
    // time plus `horizon`
    const owners = await batch(cands.map((c) => ({ to: CREDITS, data: "0x6352211e" + word(c.id) })));
    const head = await rpcCall({ jsonrpc: "2.0", id: 1, method: "eth_getBlockByNumber", params: ["latest", false] });
    const horizon = parseInt(head.result.timestamp, 16) + (o.horizon ?? 86400);
    const before = cands.length;
    cands = cands.filter((c, i) => owners[i] && ("0x" + owners[i].slice(26)).toLowerCase() === c.offerer.toLowerCase() && Number(c.startTime) <= horizon);
    notHeld = before - cands.length;
  }
  if (rpc && cands.length) {
    const sc = await scores(cands.map((c) => c.id));
    cands.forEach((c, i) => (c.rank = sc[i] === 0n ? Infinity : Number((BigInt(c.price) * 1_000_000n) / sc[i])));
  } else cands.forEach((c) => (c.rank = Number(BigInt(c.price) / 1_000_000_000n)));
  cands.sort((a, b) => a.rank - b.rank);
  const orders = [];
  const top = cands.slice(0, sign);
  const fetchedParams = [];
  for (let i = 0; i < top.length; i += 8) fetchedParams.push(...(await Promise.all(top.slice(i, i + 8).map(async (c) => {
    try {
      return await fulfillment(c.hash);
    } catch (e) {
      if (signal.aborted) throw e;
      dropped["fulfillment request failed"] = (dropped["fulfillment request failed"] ?? 0) + 1;
      return null;
    }
  }))));
  for (const [i, c] of top.entries()) {
    const p = fetchedParams[i];
    if (!p) {
      dropped["no basic fulfillment data"] = (dropped["no basic fulfillment data"] ?? 0) + 1;
      continue;
    }
    try {
      orders.push({ id: c.id, price: c.price, hash: c.hash, params: basicParams(p) });
    } catch (e) {
      if (signal.aborted) throw e;
      dropped["malformed fulfillment"] = (dropped["malformed fulfillment"] ?? 0) + 1;
    }
  }
  return { fetched, fit: cands.length, notHeld, orders, dropped };
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
