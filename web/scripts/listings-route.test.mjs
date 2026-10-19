// Exercises app/api/listings/route.ts with a stubbed fetch: fulfill only for hashes in the listings snapshot, a global
// in-flight limit, a per-client token bucket, a bounded fulfill cache and a maximum upstream GET scan.
// "@/" imports resolve through a registered hook.
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

process.env.OPENSEA_API_KEY = "test";
process.env.TRUSTED_PROXY_HOPS = "1";
process.env.NEXT_PUBLIC_CORE = "0x" + "1".repeat(40);
process.env.NEXT_PUBLIC_SEAPORT_ADAPTER = "0x" + "2".repeat(40);

const h = (n) => "0x" + n.toString(16).padStart(64, "0");
const KNOWN = [h(1), h(2), h(3)];
const MANY = 250; // more listings than the cap; the route keeps the cheapest 200
const ALL = Array.from({ length: MANY }, (_, i) => h(5000 + i));
let posts = 0;
let listingGets = 0;
globalThis.fetch = async (url, init) => {
  if (init?.method === "POST") {
    posts++;
    return Response.json({}); // not a fulfillBasicOrder call: the route answers "skipped"
  }
  listingGets++;
  if (globalThis.INVALID_PAGE_MODE) return Response.json({ next: "more", listings: [] });
  return Response.json({
    next: "",
    listings: (globalThis.MANY_MODE ? ALL : KNOWN).map((order_hash, i) => ({
      status: "ACTIVE", type: "basic", order_hash,
      protocol_address: "0x0000000000000068f116a894984e2db1123eb395",
      price: { current: { currency: "ETH", value: String(100 + i) } },
      protocol_data: { parameters: { offer: [{ identifierOrCriteria: String(i) }], endTime: "9999999999" } },
    })),
  });
};

const { GET } = await import(pathToFileURL(join(web, "app/api/listings/route.ts")).href);
const call = (hash, ip = "1.1.1.1", supplied = "9.9.9.9") =>
  GET(new Request(`http://x/api/listings?fulfill=${hash}`, { headers: { "x-forwarded-for": `${supplied}, ${ip}` } }));

// unknown hash: rejected, no upstream POST
let r = await call(h(999));
assert.equal(r.status, 404);
assert.equal(posts, 0);

// 205 unknown hashes from distinct clients: no upstream POST
for (let i = 0; i < 205; i++) assert.equal((await call(h(1000 + i), `10.0.${i >> 8}.${i & 255}`)).status, 404);
assert.equal(posts, 0);

// known hash: one POST, then served from the cache
assert.equal((await call(KNOWN[0], "2.2.2.2")).status, 200);
assert.equal(posts, 1);
assert.equal((await call(KNOWN[0], "2.2.2.2")).status, 200);
assert.equal(posts, 1);

// burst over the per-client limit is rejected
const codes = [];
for (let i = 0; i < 15; i++) codes.push((await call(KNOWN[1], "3.3.3.3", `198.51.100.${i}`)).status);
assert.ok(codes.includes(429), "burst must hit the client limit");
assert.equal(codes.indexOf(429), 10);
assert.equal(posts, 2); // KNOWN[1] fetched once, cached for the rest

// the other client is unaffected
assert.equal((await call(KNOWN[2], "4.4.4.4")).status, 200);

// cache bound and global upstream budget (burst 8, refill 4 per second). The clock is frozen so the arithmetic is exact.
let clock = Date.now() + 60_000; // new snapshot window; the bucket has refilled to the burst
Date.now = () => clock;
globalThis.MANY_MODE = true;
posts = 0;
let ok = 0, busy = 0;
for (let i = 0; i < 200; i++) {
  const res = await call(ALL[i], `20.0.${i >> 8}.${i & 255}`);
  if (res.status === 200) ok++;
  else {
    assert.equal(res.status, 503);
    assert.ok(res.headers.get("retry-after"));
    busy++;
  }
}
assert.equal(ok, 8);
assert.equal(busy, 192);
assert.equal(posts, 8);

// one second later 4 more POSTs are allowed; a refused hash is not cached, so it succeeds once the budget allows
clock += 1000;
for (let i = 8; i < 28; i++) await call(ALL[i], `21.0.${i >> 8}.${i & 255}`);
assert.equal(posts, 12);

// the cache serves repeats without a POST or a token
for (let i = 0; i < 12; i++) assert.equal((await call(ALL[i], `30.0.${i >> 8}.${i & 255}`)).status, 200);
assert.equal(posts, 12);

// promise: absent a verified proxy chain, arbitrary forwarding headers cannot select a client bucket;
// the global upstream budget still bounds uncached requests.
process.env.TRUSTED_PROXY_HOPS = "0";
for (let i = 0; i < 15; i++) assert.equal((await call(ALL[0], "3.3.3.3", `203.0.113.${i}`)).status, 200);
assert.equal(posts, 12);
process.env.TRUSTED_PROXY_HOPS = "1";

// promise: ineligible upstream pages cannot keep one website request fetching without a bound.
clock += 60_000;
globalThis.INVALID_PAGE_MODE = true;
listingGets = 0;
const capped = await GET(new Request("http://x/api/listings"));
assert.equal(capped.status, 200);
assert.deepEqual((await capped.json()).listings, []);
assert.equal(listingGets, 5);

console.log("listings-route test ok");
