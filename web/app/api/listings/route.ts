// OpenSea listings of the Credits collection that the Core can fill through SeaportBasicAdapter (owner decision 134).
// Server only: OPENSEA_API_KEY never reaches the browser. The response is the cheapest listings that pass the
// adapter's checks. The list (no fulfillment data) is cached for CACHE_MS so every browser shares one OpenSea round of
// requests; `?fulfill=<orderHash>` returns the encoded `params` for Core.buyListing of one order, cached per order.

import { createPublicClient, encodeAbiParameters, getAddress, http, zeroAddress, type Address, type Hex } from "viem";
import { core, credits, rpcUrl, seaportAdapter } from "@/lib/config";
import { basicOrderParameters, seaportAdapterAbi } from "@/lib/abis";

export const dynamic = "force-dynamic";

const OS = "https://api.opensea.io/api/v2";
const SLUG = "credits";
const SEAPORT_1_6 = "0x0000000000000068f116a894984e2db1123eb395";
const PAGE = 100; // OpenSea's maximum page size
const MAX_LISTINGS = 200; // the cheapest listings kept per cache window (two pages); sent as `max` for the listings page caption
const CACHE_MS = 20_000;
const FULFILL_CACHE_MS = 10_000;
const MAX_FULFILL_INFLIGHT = 4; // concurrent OpenSea fulfillment POSTs across all clients
const BUCKET_BURST = 10; // fulfill requests a client can send back to back
const BUCKET_REFILL_MS = 2_000; // one request regained per interval
const MAX_BUCKETS = 1_000; // tracked clients; the oldest is dropped past this

interface Out {
  /** open ETH listings of the collection, cheapest first; `price` is the wei the buyer pays in total */
  listings: { id: string; price: string; orderHash: string; expiry: number }[];
  /** the bound on `listings` */
  max: number;
}
interface Fulfill {
  id?: string;
  price?: string;
  params?: Hex;
  /** why the order cannot be filled through the adapter */
  skipped?: string;
  /** fee recipient the adapter refuses */
  blocked?: string;
}

let cache: { at: number; out: Out } | undefined;
let inflight: Promise<Out> | undefined;
// Insertion-ordered LRU: a hit is re-inserted last, the first key is evicted past MAX_LISTINGS.
const fulfilled = new Map<string, { at: number; out: Promise<Fulfill> }>();
let fulfillActive = 0;
const buckets = new Map<string, { tokens: number; at: number }>();

// Token bucket per client key. Returns false when the client is over its rate.
function allow(key: string): boolean {
  const now = Date.now();
  const b = buckets.get(key) ?? { tokens: BUCKET_BURST, at: now };
  b.tokens = Math.min(BUCKET_BURST, b.tokens + (now - b.at) / BUCKET_REFILL_MS);
  b.at = now;
  buckets.delete(key);
  buckets.set(key, b);
  while (buckets.size > MAX_BUCKETS) buckets.delete(buckets.keys().next().value!);
  if (b.tokens < 1) return false;
  b.tokens -= 1;
  return true;
}

const lc = (a: string) => a.toLowerCase();

async function os(path: string, init?: RequestInit) {
  const r = await fetch(`${OS}${path}`, {
    ...init,
    headers: { "x-api-key": process.env.OPENSEA_API_KEY!, accept: "application/json", "content-type": "application/json" },
    cache: "no-store",
  });
  if (!r.ok) throw new Error(`opensea ${r.status}`);
  return r.json();
}

// The collection's best listings, paged: id, total price, order hash and expiry only. No fulfillment data.
async function build(): Promise<Out> {
  const rows: Out["listings"] = [];
  let next = "";
  while (rows.length < MAX_LISTINGS) {
    const page = await os(`/listings/collection/${SLUG}/best?limit=${PAGE}${next ? `&next=${encodeURIComponent(next)}` : ""}`);
    for (const l of page.listings as any[]) {
      const p = l.protocol_data?.parameters;
      const id = p?.offer?.[0]?.identifierOrCriteria;
      if (l.status !== "ACTIVE" || l.type !== "basic" || l.price?.current?.currency !== "ETH" || lc(l.protocol_address) !== SEAPORT_1_6 || id == null) continue;
      rows.push({ id: String(id), price: String(l.price.current.value), orderHash: l.order_hash, expiry: Number(p.endTime) });
    }
    next = page.next;
    if (!next) break;
  }
  rows.sort((a, b) => (BigInt(a.price) < BigInt(b.price) ? -1 : 1));
  return { listings: rows.slice(0, MAX_LISTINGS), max: MAX_LISTINGS };
}

// BasicOrderParameters of one order, from OpenSea's fulfillment data, if the adapter accepts the order.
async function fulfill(orderHash: string): Promise<Fulfill> {
  try {
    const body = { listing: { hash: orderHash, chain: "ethereum", protocol_address: SEAPORT_1_6 }, fulfiller: { address: core } };
    const f = (await os("/listings/fulfillment_data", { method: "POST", body: JSON.stringify(body) })).fulfillment_data?.transaction;
    const p = f?.input_data?.parameters;
    if (!p || !String(f.function).startsWith("fulfillBasicOrder_efficient_6GL6yc") || lc(f.to) !== SEAPORT_1_6) return { skipped: "not a fulfillBasicOrder call" };
    if (lc(p.offerToken) !== lc(credits) || p.offerAmount !== "1") return { skipped: "not one credit" };
    if (lc(p.considerationToken) !== zeroAddress) return { skipped: "not native currency" };
    if (Number(p.basicOrderType) > 1) return { skipped: "restricted order type" };
    const client = createPublicClient({ transport: http(rpcUrl) });
    let price = BigInt(p.considerationAmount);
    for (const r of p.additionalRecipients as { amount: string; recipient: string }[]) {
      price += BigInt(r.amount);
      if (lc(r.recipient) === lc(p.offerer)) continue;
      const ok = await client.readContract({ address: seaportAdapter!, abi: seaportAdapterAbi, functionName: "allowedRecipient", args: [getAddress(r.recipient)] });
      if (!ok) return { skipped: "fee recipient not allowed by the adapter", blocked: lc(r.recipient) };
    }
    if (price !== BigInt(f.value)) return { skipped: "value mismatch" };
    const params = encodeAbiParameters(basicOrderParameters, [
      {
        considerationToken: p.considerationToken,
        considerationIdentifier: BigInt(p.considerationIdentifier),
        considerationAmount: BigInt(p.considerationAmount),
        offerer: p.offerer,
        zone: p.zone,
        offerToken: p.offerToken,
        offerIdentifier: BigInt(p.offerIdentifier),
        offerAmount: BigInt(p.offerAmount),
        basicOrderType: Number(p.basicOrderType),
        startTime: BigInt(p.startTime),
        endTime: BigInt(p.endTime),
        zoneHash: p.zoneHash,
        salt: BigInt(p.salt),
        offererConduitKey: p.offererConduitKey,
        fulfillerConduitKey: p.fulfillerConduitKey,
        totalOriginalAdditionalRecipients: BigInt(p.totalOriginalAdditionalRecipients),
        additionalRecipients: p.additionalRecipients.map((r: { amount: string; recipient: Address }) => ({ amount: BigInt(r.amount), recipient: r.recipient })),
        signature: p.signature,
      },
    ]);
    return { id: p.offerIdentifier, price: price.toString(), params };
  } catch {
    return { skipped: "fulfillment data failed" };
  }
}

// The bounded listings snapshot, shared by every request within CACHE_MS.
async function snapshot(): Promise<Out> {
  if (cache && Date.now() - cache.at < CACHE_MS) return cache.out;
  try {
    inflight ??= build().finally(() => (inflight = undefined));
    const out = await inflight;
    cache = { at: Date.now(), out };
  } catch {
    // OpenSea failed: keep the last good answer for one more window, else nothing
    cache = { at: Date.now(), out: cache?.out ?? { listings: [], max: MAX_LISTINGS } };
  }
  return cache.out;
}

export async function GET(req: Request) {
  const empty: Out = { listings: [], max: MAX_LISTINGS };
  if (!process.env.OPENSEA_API_KEY || !seaportAdapter || !core) return Response.json(empty);

  const hash = new URL(req.url).searchParams.get("fulfill");
  if (hash) {
    if (!/^0x[0-9a-fA-F]{64}$/.test(hash)) return Response.json({ skipped: "bad order hash" } satisfies Fulfill, { status: 400 });
    const client = req.headers.get("x-forwarded-for")?.split(",")[0].trim() || "unknown";
    if (!allow(client)) return Response.json({ skipped: "rate limited" } satisfies Fulfill, { status: 429 });
    const key = hash.toLowerCase();
    if (!(await snapshot()).listings.some((l) => lc(l.orderHash) === key)) return Response.json({ skipped: "order not in the current listings" } satisfies Fulfill, { status: 404 });
    const hit = fulfilled.get(key);
    if (hit && Date.now() - hit.at < FULFILL_CACHE_MS) {
      fulfilled.delete(key);
      fulfilled.set(key, hit);
      return Response.json(await hit.out);
    }
    if (fulfillActive >= MAX_FULFILL_INFLIGHT) return Response.json({ skipped: "busy" } satisfies Fulfill, { status: 503 });
    fulfillActive++;
    const out = fulfill(key).finally(() => fulfillActive--);
    fulfilled.delete(key);
    fulfilled.set(key, { at: Date.now(), out });
    while (fulfilled.size > MAX_LISTINGS) fulfilled.delete(fulfilled.keys().next().value!);
    return Response.json(await out);
  }

  return Response.json(await snapshot());
}
