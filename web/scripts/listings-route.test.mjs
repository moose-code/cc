// Exercises app/api/listings/route.ts with a stubbed keeper: the view is read once per window and shared, a foreign
// or malformed view is refused, the last good view is kept and marked stale through failures, and fulfillment is
// served only for signed orders of the current view. "@/" imports resolve through a registered hook.
import assert from "node:assert/strict";
import { register } from "node:module";
import { dirname, join } from "node:path";
import { existsSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";

const web = join(dirname(fileURLToPath(import.meta.url)), "..");
const hook = `
import { existsSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
export async function resolve(spec, ctx, next) {
  if (spec.startsWith("@/")) {
    const base = join(${JSON.stringify(web)}, spec.slice(2));
    for (const f of [base + ".ts", base + ".tsx", join(base, "index.ts")]) if (existsSync(f)) return next(pathToFileURL(f).href, ctx);
  }
  if (spec.startsWith(".") && ctx.parentURL && !/\\.[a-z]+$/.test(spec)) {
    for (const ext of [".ts", ".tsx"]) { try { return await next(spec + ext, ctx); } catch {} }
  }
  return next(spec, ctx);
}`;
register("data:text/javascript," + encodeURIComponent(hook));

process.env.KEEPER_MARKET_URL = "https://keeper.example/";
process.env.KEEPER_MARKET_TOKEN = "secret";
process.env.NEXT_PUBLIC_CORE = "0x" + "1".repeat(40);
process.env.NEXT_PUBLIC_SEAPORT_ADAPTER = "0x" + "2".repeat(40);

const h = (n) => "0x" + n.toString(16).padStart(64, "0");
const status = { source: "api", complete: true, lastFullAt: 1000, publishedAt: 2000, streamJoined: true, gap: false, queuedUpdates: 0, queuedRemovals: 0, retryAt: null, lastFailure: null };
const row = (n, signed = false) => ({ id: String(n), price: String(100 * n), hash: h(n).toUpperCase().replace("0X", "0x"), endTime: 9999999999, score: "10000", signed });
let upstream = () => ({ chainId: 1, core: process.env.NEXT_PUBLIC_CORE, seaportAdapter: process.env.NEXT_PUBLIC_SEAPORT_ADAPTER, builtAt: 3000, status, catalog: { total: 3, scored: 3, signed: 1, limit: 1000 }, rows: [row(1, true), row(2), row(3)] });
const calls = [];
globalThis.fetch = async (url, init) => {
  calls.push({ url: String(url), auth: init?.headers?.authorization });
  if (String(url).includes("/market/orders/")) {
    const hash = String(url).split("/").at(-1);
    return hash === h(1) ? Response.json({ id: "1", price: "100", hash, params: "0xabcd" }) : new Response("", { status: 404 });
  }
  const answer = upstream();
  if (answer instanceof Response) return answer;
  if (answer instanceof Error) throw answer;
  return Response.json(answer);
};

const { GET } = await import(pathToFileURL(join(web, "app/api/listings/route.ts")).href);
const { VIEW_LIMIT } = await import(pathToFileURL(join(web, "lib/listings-api.ts")).href);
const view = () => GET(new Request("http://x/api/listings"));
const fulfill = (hash) => GET(new Request(`http://x/api/listings?fulfill=${hash}`));
const realNow = Date.now;
let now = realNow();
Date.now = () => now;
try {
  // one upstream read serves concurrent readers; the token travels only upstream
  const [a, b] = await Promise.all([view(), view()]);
  assert.equal(a.status, 200);
  assert.equal(a.headers.get("cache-control"), "no-store");
  const first = await a.json();
  assert.deepEqual(await b.json(), first);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, `https://keeper.example/market?limit=${VIEW_LIMIT}`);
  assert.equal(calls[0].auth, "Bearer secret");
  assert.equal(first.available, true);
  assert.equal(first.stale, false);
  assert.equal(first.fetchedAt, now);
  assert.deepEqual(first.view.rows.map((r) => [r.id, r.hash, r.signed]), [["1", h(1), true], ["2", h(2), false], ["3", h(3), false]]);
  assert.deepEqual(first.view.status, status);
  assert.equal(first.view.catalog.total, 3);
  assert.equal(JSON.stringify(first).includes("secret"), false);

  // within the window nothing is re-read; past it one read follows
  await view();
  assert.equal(calls.length, 1);
  now += 5_001;
  await view();
  assert.equal(calls.length, 2);

  // an upstream failure keeps the last good view, marked stale with the failure named
  now += 5_001;
  upstream = () => new Response("", { status: 503 });
  let out = await (await view()).json();
  assert.equal(out.available, true);
  assert.equal(out.stale, true);
  assert.equal(out.error, "keeper view 503");
  assert.equal(out.view.rows.length, 3);
  now += 5_001;
  upstream = () => new Error("fetch failed https://keeper.example/market");
  out = await (await view()).json();
  assert.equal(out.stale, true);
  assert.equal(out.error, "fetch failed [upstream]");

  // a malformed view is refused, not served
  now += 5_001;
  upstream = () => ({ ...upstream0(), rows: [{ ...row(4), price: "1e3" }] });
  function upstream0() { return { chainId: 1, core: process.env.NEXT_PUBLIC_CORE, seaportAdapter: process.env.NEXT_PUBLIC_SEAPORT_ADAPTER, builtAt: 3000, status, catalog: { total: 1, scored: 1, signed: 0, limit: 1000 }, rows: [] }; }
  out = await (await view()).json();
  assert.equal(out.stale, true);
  assert.equal(out.error, "malformed view row");

  // a view of another Core is refused outright, not retained as stale data
  now += 5_001;
  upstream = () => ({ ...upstream0(), core: "0x" + "3".repeat(40) });
  out = await (await view()).json();
  assert.deepEqual(out, { available: false, reason: "identity", stale: false });

  // recovery serves the fresh view
  now += 5_001;
  upstream = upstream0;
  out = await (await view()).json();
  assert.deepEqual([out.available, out.stale, out.view.rows.length, out.fetchedAt], [true, false, 0, now]);

  // fulfillment: only a signed order of the current view reaches the keeper, cached per order
  now += 5_001;
  upstream = () => ({ ...upstream0(), catalog: { total: 3, scored: 3, signed: 1, limit: 1000 }, rows: [row(1, true), row(2), row(3)] });
  await view();
  const reads = calls.length;
  assert.equal((await fulfill("0x12")).status, 400);
  assert.equal((await fulfill(h(9))).status, 404);
  assert.equal((await fulfill(h(2))).status, 404, "unsigned");
  assert.equal(calls.length, reads);
  let f = await fulfill(h(1).toUpperCase().replace("0X", "0x"));
  assert.equal(f.status, 200);
  assert.deepEqual(await f.json(), { id: "1", price: "100", params: "0xabcd" });
  assert.equal(calls.length, reads + 1);
  assert.equal(calls.at(-1).url, `https://keeper.example/market/orders/${h(1)}`);
  await fulfill(h(1));
  assert.equal(calls.length, reads + 1, "cached");
} finally {
  Date.now = realNow;
}

// unconfigured: no upstream read, an honest answer
delete process.env.KEEPER_MARKET_URL;
{
  const reads = calls.length;
  await new Promise((r) => setTimeout(r, 0));
  // the cache window still holds the configured answer; a fresh module sees the unconfigured one
  const fresh = await import(pathToFileURL(join(web, "app/api/listings/route.ts")).href + "?fresh");
  const out = await (await fresh.GET(new Request("http://x/api/listings"))).json();
  assert.deepEqual(out, { available: false, reason: "unconfigured", stale: false });
  assert.deepEqual(await (await fresh.GET(new Request(`http://x/api/listings?fulfill=${h(1)}`))).json(), { skipped: "order not in the current listings" });
  assert.equal(calls.length, reads);
}

console.log("listings-route test ok");
