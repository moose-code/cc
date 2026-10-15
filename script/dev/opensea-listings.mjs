#!/usr/bin/env node
// fetches the active Credits listings from the OpenSea API v2 (listings/collection/<slug>/best, the slug resolved from
// chain/ethereum/contract/<address>) and writes the ones a Seaport 1.6 basic order can
// fulfil as the input of script/dev/Activity.s.sol (stage bots).
//
//   OPENSEA_API_KEY=<key> node script/dev/opensea-listings.mjs --out <file> [--rpc <url> --adapter <SeaportBasicAdapter>]
//
// the key is read from the environment only. a listing is kept when it has one ERC721 offer item of Credits, native
// consideration items with equal start and end amounts, the first paid to the offerer, an open order type, every other
// recipient the offerer or an address the adapter allows, and an end time in the future. the allowlist comes from
// allowedRecipient(address) of the adapter at --rpc, or from ALLOWED_RECIPIENTS (comma separated) without an rpc; the
// default is the launch entry, the OpenSea fee collector.
//
// the listing pages carry no signature. the listings are ranked by price over fork score (the order in which a bid
// scaled by score reaches them), and the signature of the cheapest SIGN of them (default 40) comes from the
// fulfillment_data endpoint, whose parameters are the BasicOrderParameters of the order. without --rpc the ranking is
// by price.
//
// output: {"count": N, "orders": [{"id": "<credit id>", "price": "<wei>", "params": BasicOrderParameters}]}. every
// number is a decimal string. params carries the fields of BasicOrderParameters, built the way test/Seaport.t.sol
// _basicData builds them.

import { writeFileSync } from "node:fs";

const CREDITS = "0x97630aa70ab14ed9883b41dafccbc11349723043";
const SEAPORT_16 = "0x0000000000000068f116a894984e2db1123eb395";
const OPENSEA_FEE = "0x0000a26b00c1f0df003000390027140000faa719";
const ZERO = "0x0000000000000000000000000000000000000000";
const ZERO32 = "0x" + "0".repeat(64);
// selector of allowedRecipient(address), the public mapping getter of SeaportBasicAdapter
const SELECTOR = "0xdb846026";

const arg = (name, dflt) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : dflt;
};
const out = arg("out");
const rpc = arg("rpc", process.env.RPC_URL);
const adapter = arg("adapter", process.env.SEAPORT_ADAPTER);
const maxPages = Number(arg("pages", process.env.OPENSEA_PAGES ?? 3));
const sign = Number(arg("sign", process.env.OPENSEA_SIGN ?? 40));
const fulfiller = arg("fulfiller", "0x1111111111111111111111111111111111111111");
const key = process.env.OPENSEA_API_KEY;
if (!out) throw new Error("--out <file> is required");
if (!key) {
  console.error("opensea: OPENSEA_API_KEY is not set, nothing fetched");
  writeFileSync(out, JSON.stringify({ count: 0, orders: [] }));
  process.exit(0);
}

const allowedCache = new Map();
const envAllowed = (process.env.ALLOWED_RECIPIENTS ?? OPENSEA_FEE).toLowerCase().split(",");
async function allowed(addr) {
  const a = addr.toLowerCase();
  if (!rpc || !adapter) return envAllowed.includes(a);
  if (!allowedCache.has(a)) {
    const data = SELECTOR + a.slice(2).padStart(64, "0");
    const r = await fetch(rpc, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to: adapter, data }, "latest"] }),
    }).then((x) => x.json());
    allowedCache.set(a, BigInt(r.result ?? "0x0") !== 0n);
  }
  return allowedCache.get(a);
}

const headers = { "x-api-key": key, accept: "application/json" };

async function get(url) {
  for (let attempt = 0; attempt < 4; ++attempt) {
    const res = await fetch(url, { headers });
    if (res.status === 429) {
      await new Promise((r) => setTimeout(r, 1500 * (attempt + 1)));
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

const same = (a, b) => a.toLowerCase() === b.toLowerCase();
const native = (it) => it.itemType === 0 && same(it.token, ZERO) && it.startAmount === it.endAmount;

// returns the entry, or the reason the listing does not fit a basic order
async function convert(o) {
  if (!o.protocol_data) return "no protocol data";
  if (!same(o.protocol_address ?? "", SEAPORT_16)) return "not seaport 1.6";
  const p = o.protocol_data.parameters;
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
  return {
    id: off.identifierOrCriteria,
    price: price.toString(),
    params: {
      considerationToken: ZERO,
      considerationIdentifier: "0",
      considerationAmount: p.consideration[0].startAmount,
      offerer: p.offerer,
      zone: p.zone,
      offerToken: CREDITS,
      offerIdentifier: off.identifierOrCriteria,
      offerAmount: "1",
      basicOrderType: String(p.orderType),
      startTime: String(p.startTime),
      endTime: String(p.endTime),
      zoneHash: p.zoneHash,
      salt: String(p.salt),
      offererConduitKey: p.conduitKey,
      fulfillerConduitKey: ZERO32,
      totalOriginalAdditionalRecipients: String(extra.length),
      additionalRecipients: extra.map((c) => ({ amount: c.startAmount, recipient: c.recipient })),
      signature: null,
    },
    hash: o.order_hash,
  };
}

// score of every id on the fork through batched eth_calls; ids that do not exist map to 0
const SC = "0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7";
async function batch(calls) {
  const body = calls.map((c, i) => ({ jsonrpc: "2.0", id: i, method: "eth_call", params: [c, "latest"] }));
  const r = await fetch(rpc, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }).then((x) => x.json());
  return r.sort((a, b) => a.id - b.id).map((x) => x.result);
}
async function scores(ids) {
  const word = (id) => BigInt(id).toString(16).padStart(64, "0");
  const seeds = await batch(ids.map((id) => ({ to: CREDITS, data: "0x" + SEED_SEL + word(id) })));
  const times = await batch(ids.map((id) => ({ to: CREDITS, data: "0x" + TIME_SEL + word(id) })));
  const sc = await batch(
    ids.map((_, i) => ({ to: SC, data: "0x" + SCORE_SEL + (seeds[i] ?? "0x").slice(2, 66).padEnd(64, "0") + (times[i] ?? "0x").slice(2).padStart(64, "0") })),
  );
  return sc.map((x) => (x && x !== "0x" ? BigInt(x) : 0n));
}
// selectors of seedOf(uint256), timestampOf(uint256), scoreOf(bytes21,uint64)
const SEED_SEL = "82829f74";
const TIME_SEL = "2d9c77e1";
const SCORE_SEL = "8c08f632";

async function fulfillment(hash) {
  let res;
  for (let attempt = 0; attempt < 4; ++attempt) {
    res = await fetch("https://api.opensea.io/api/v2/listings/fulfillment_data", {
      method: "POST",
      headers: { ...headers, "content-type": "application/json" },
      body: JSON.stringify({ listing: { hash, chain: "ethereum", protocol_address: SEAPORT_16 }, fulfiller: { address: fulfiller } }),
    });
    if (res.status !== 429) break;
    await new Promise((r) => setTimeout(r, 1000 * (attempt + 1)));
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
  for (const o of body.listings ?? []) {
    ++fetched;
    const r = await convert(o);
    if (typeof r === "string") dropped[r] = (dropped[r] ?? 0) + 1;
    else cands.push(r);
  }
  cursor = body.next;
  if (!cursor) break;
}
let forkOnly = 0;
if (rpc && cands.length) {
  // keep the listings the fork can fill: the offerer owns the credit at the fork block and the order has started by
  // the time the run reaches (the fork block time plus the warps of a run)
  const word = (id) => BigInt(id).toString(16).padStart(64, "0");
  const owners = await batch(cands.map((c) => ({ to: CREDITS, data: "0x6352211e" + word(c.id) })));
  const head = await fetch(rpc, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getBlockByNumber", params: ["latest", false] }) }).then((x) => x.json());
  const horizon = parseInt(head.result.timestamp, 16) + Number(process.env.FORK_HORIZON ?? 86400);
  const before = cands.length;
  cands = cands.filter((c, i) => owners[i] && ("0x" + owners[i].slice(26)).toLowerCase() === c.params.offerer.toLowerCase() && Number(c.params.startTime) <= horizon);
  forkOnly = before - cands.length;
}
if (rpc && cands.length) {
  const sc = await scores(cands.map((c) => c.id));
  cands.forEach((c, i) => (c.rank = sc[i] === 0n ? Infinity : Number(BigInt(c.price) * 1_000_000n / sc[i])));
} else cands.forEach((c) => (c.rank = Number(BigInt(c.price) / 1_000_000_000n)));
cands.sort((a, b) => a.rank - b.rank);
const kept = [];
const top = cands.slice(0, sign);
const fetchedParams = [];
for (let i = 0; i < top.length; i += 8) fetchedParams.push(...(await Promise.all(top.slice(i, i + 8).map((c) => fulfillment(c.hash)))));
for (const [i, c] of top.entries()) {
  const p = fetchedParams[i];
  if (!p) {
    dropped["no basic fulfillment data"] = (dropped["no basic fulfillment data"] ?? 0) + 1;
    continue;
  }
  const params = {
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
    fulfillerConduitKey: p.fulfillerConduitKey,
    totalOriginalAdditionalRecipients: String(p.totalOriginalAdditionalRecipients),
    additionalRecipients: p.additionalRecipients.map((r) => ({ amount: String(r.amount), recipient: r.recipient })),
    signature: p.signature,
  };
  kept.push({ id: c.id, price: c.price, params });
}
writeFileSync(out, JSON.stringify({ count: kept.length, orders: kept }, null, 1));
console.error(`opensea: fetched ${fetched} listings, ${cands.length} fit a basic order and the fork (${forkOnly} not held by the offerer at the fork block or not started), ${kept.length} signed (cheapest by price over fork score)`);
for (const [why, n] of Object.entries(dropped)) console.error(`opensea: dropped ${n}: ${why}`);
