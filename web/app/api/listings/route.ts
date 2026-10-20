// The website's read of the keeper's market view (keeper/src/market-view.ts): the compatible OpenSea asks of the
// Credits collection ranked by exact price per point across the keeper's whole observed catalog, with its discovery
// status, and the prepared fulfillment (`?fulfill=<orderHash>`) of one signed order for Core.buyListing.
// Server only: KEEPER_MARKET_URL and KEEPER_MARKET_TOKEN never reach the browser. One fetch per VIEW_CACHE_MS is
// shared by every visitor of a warm instance, the last good view is kept through upstream failures and marked stale,
// and the view's chain, Core and adapter identity must match this deployment before it is served. Advisory data: the
// browser re-reads the bid, the holder and the order status at a block and simulates buyListing before sending.

import { chain, core, seaportAdapter } from "@/lib/config";
import { DIGITS, HASH, object, parseView, VIEW_LIMIT, type Fulfill, type Out } from "@/lib/listings-api";

export const dynamic = "force-dynamic";

const VIEW_CACHE_MS = 5_000; // one upstream read per window per warm instance
const VIEW_TIMEOUT_MS = 8_000;
const MAX_VIEW_BYTES = 4 * 1024 * 1024;
const ORDER_CACHE_MS = 10_000;
const MAX_ORDER_INFLIGHT = 8; // concurrent fulfillment reads across all clients
const MAX_ORDER_CACHE = 256;

const lc = (a: string) => a.toLowerCase();

let cache: { at: number; out: Out } | undefined;
let inflight: Promise<Out> | undefined;
// Insertion-ordered LRU of fulfillment reads by order hash.
const orders = new Map<string, { at: number; out: Promise<Fulfill> }>();
let orderActive = 0;

function target(): { url: string; headers: Record<string, string> } | undefined {
  const raw = process.env.KEEPER_MARKET_URL;
  if (!raw) return undefined;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return undefined;
  }
  const local = /^(127\.0\.0\.1|localhost|\[::1\])$/.test(url.hostname);
  if (url.protocol !== "https:" && !(url.protocol === "http:" && local)) return undefined;
  const token = process.env.KEEPER_MARKET_TOKEN;
  return { url: url.href.replace(/\/+$/, ""), headers: { accept: "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) } };
}

async function readJson(url: string, headers: Record<string, string>, timeoutMs: number): Promise<{ status: number; body: unknown }> {
  const r = await fetch(url, { headers, cache: "no-store", signal: AbortSignal.timeout(timeoutMs) });
  if (Number(r.headers.get("content-length")) > MAX_VIEW_BYTES) throw new Error("oversized view");
  const text = await r.text();
  if (text.length > MAX_VIEW_BYTES) throw new Error("oversized view");
  return { status: r.status, body: text ? JSON.parse(text) : undefined };
}

async function fetchView(): Promise<Out> {
  const t = target();
  if (!t || !core || !seaportAdapter) return { available: false, reason: "unconfigured", stale: false };
  const last = cache?.out;
  try {
    const { status, body } = await readJson(`${t.url}/market?limit=${VIEW_LIMIT}`, t.headers, VIEW_TIMEOUT_MS);
    if (status !== 200) throw new Error(`keeper view ${status}`);
    const { view, identity } = parseView(body);
    if (identity.chainId !== chain.id || lc(identity.core) !== lc(core) || lc(identity.seaportAdapter) !== lc(seaportAdapter)) return { available: false, reason: "identity", stale: false };
    return { available: true, fetchedAt: Date.now(), stale: false, view };
  } catch (e) {
    const error = (e instanceof Error ? e.message : "keeper view failed").replace(/https?:\/\/\S+/g, "[upstream]").slice(0, 120);
    // the last good view stays on offer, marked stale with the failure; without one the route says so
    if (last?.view) return { ...last, stale: true, error };
    return { available: false, reason: "unreachable", stale: false, error };
  }
}

// The view shared by every request within VIEW_CACHE_MS; concurrent readers wait on one upstream read.
async function snapshot(): Promise<Out> {
  if (cache && Date.now() - cache.at < VIEW_CACHE_MS) return cache.out;
  inflight ??= fetchView().finally(() => (inflight = undefined));
  const out = await inflight;
  cache = { at: Date.now(), out };
  return out;
}

// The prepared fulfillment of one order the keeper signed, encoded for Core.buyListing.
async function fulfill(hash: string): Promise<Fulfill> {
  const t = target();
  if (!t) return { skipped: "unconfigured" };
  try {
    const { status, body } = await readJson(`${t.url}/market/orders/${hash}`, t.headers, VIEW_TIMEOUT_MS);
    if (status === 404) return { skipped: "order not prepared by the keeper" };
    if (status !== 200) return { skipped: `keeper view ${status}` };
    if (!object(body) || typeof body.id !== "string" || !DIGITS.test(body.id) || typeof body.price !== "string" || !DIGITS.test(body.price) || typeof body.params !== "string" || !/^0x[0-9a-fA-F]*$/.test(body.params) || lc(String(body.hash)) !== hash) return { skipped: "malformed fulfillment" };
    return { id: body.id, price: body.price, params: body.params as `0x${string}` };
  } catch {
    return { skipped: "fulfillment read failed" };
  }
}

export async function GET(req: Request) {
  const headers = { "cache-control": "no-store" };
  const hash = new URL(req.url).searchParams.get("fulfill");
  if (hash) {
    if (!HASH.test(hash)) return Response.json({ skipped: "bad order hash" } satisfies Fulfill, { status: 400, headers });
    const key = lc(hash);
    const current = await snapshot();
    const row = current.view?.rows.find((r) => r.hash === key);
    if (!row) return Response.json({ skipped: "order not in the current listings" } satisfies Fulfill, { status: 404, headers });
    if (!row.signed) return Response.json({ skipped: "order not prepared by the keeper" } satisfies Fulfill, { status: 404, headers });
    const hit = orders.get(key);
    if (hit && Date.now() - hit.at < ORDER_CACHE_MS) {
      orders.delete(key);
      orders.set(key, hit);
      return Response.json(await hit.out, { headers });
    }
    if (orderActive >= MAX_ORDER_INFLIGHT) return Response.json({ skipped: "busy" } satisfies Fulfill, { status: 503, headers: { ...headers, "retry-after": "1" } });
    orderActive++;
    const out = fulfill(key).finally(() => orderActive--);
    orders.delete(key);
    orders.set(key, { at: Date.now(), out });
    while (orders.size > MAX_ORDER_CACHE) orders.delete(orders.keys().next().value!);
    return Response.json(await out, { headers });
  }
  return Response.json(await snapshot(), { headers });
}
