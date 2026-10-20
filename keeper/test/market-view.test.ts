// promise: the website reads the keeper's whole compatible OpenSea catalog ranked by exact price per point, with its
// quarantine, expiry, stream and failure state stated honestly, through a GET-only view that signs and sends nothing.
import { test } from "node:test";
import assert from "node:assert/strict";
import { decodeAbiParameters } from "viem";
import { basicOrderParameters } from "@cc/engine/abis";
import { Sources } from "../src/listings.ts";
import { DEFAULT_LIMIT, handleMarketRequest, MAX_LIMIT, startMarketServer } from "../src/market-view.ts";
import { setSink } from "../src/log.ts";

const record = { chainId: 1, core: "0x00000000000000000000000000000000000000c0", seaportAdapter: "0x00000000000000000000000000000000000000a1" };
const hash = (n: number) => "0x" + n.toString(16).padStart(64, "0");
const params = {
  considerationToken: "0x0000000000000000000000000000000000000000",
  considerationIdentifier: "0",
  considerationAmount: "900",
  offerer: "0x00000000000000000000000000000000000000f1",
  zone: "0x0000000000000000000000000000000000000000",
  offerToken: "0x97630aA70AB14ed9883B41dAfccBc11349723043",
  offerIdentifier: "42",
  offerAmount: "1",
  basicOrderType: "0",
  startTime: "1",
  endTime: "9999999999",
  zoneHash: "0x" + "00".repeat(32),
  salt: "5",
  offererConduitKey: "0x" + "00".repeat(32),
  fulfillerConduitKey: "0x" + "00".repeat(32),
  totalOriginalAdditionalRecipients: "1",
  additionalRecipients: [{ amount: "100", recipient: "0x0000a26b00c1F0DF003000390027140000fAa719" }],
  signature: "0xabcd",
};

function apiSource(now: () => number) {
  const source: any = new Sources({} as any, { record, strategy: { mode: "off" }, opensea: { key: "fixture", refreshSec: 300 } } as any, now);
  const row = (n: number, id: string, price: string, endTime = "9999999999") => source.market.rows.set(hash(n), { id, price, hash: hash(n), offerer: params.offerer, startTime: "1", endTime });
  // price per point: 1 at 1000/1000, 0.5 at 500/1000, 2 at 4000/2000, 3 at 3000/1000 (the nominal price ranks it before 3)
  row(1, "1", "1000");
  row(2, "2", "500");
  row(3, "3", "4000");
  row(4, "4", "3000");
  row(5, "5", "1"); // no score: last, however cheap
  row(6, "6", "700"); // quarantined by a stream removal
  row(7, "7", "100"); // transferred away
  row(8, "8", "10", "1"); // expired
  source.scores = new Map([[1n, 1000n], [2n, 1000n], [3n, 2000n], [4n, 1000n], [6n, 1000n], [7n, 1000n], [8n, 1000n]]);
  source.market.signed.set(hash(2), { id: "2", price: "500", hash: hash(2), params });
  source.market.signed.set(hash(6), { id: "6", price: "700", hash: hash(6), params });
  source.market.complete = true;
  source.market.lastFullAt = now() - 60_000;
  source.publishedAt = now() - 1000;
  source.blocked.add(hash(6));
  source.transferred.add("7");
  source.streamJoined = true;
  source.reconciledGeneration = source.gapGeneration;
  return source;
}

test("view: ranks the whole catalog by exact price per point and excludes quarantined, transferred and expired rows", () => {
  const now = 1_700_000_000_000;
  const source = apiSource(() => now);
  const view = source.marketView(3);
  assert.deepEqual([view.chainId, view.core, view.seaportAdapter], [1, record.core, record.seaportAdapter]);
  assert.deepEqual(view.rows.map((r: any) => r.id), ["2", "1", "3"]);
  assert.deepEqual(view.catalog, { total: 5, scored: 4, signed: 1, limit: 3 });
  const all = source.marketView(100).rows;
  assert.deepEqual(all.map((r: any) => [r.id, r.score, r.signed]), [["2", "1000", true], ["1", "1000", false], ["3", "2000", false], ["4", "1000", false], ["5", null, false]]);
  assert.equal(all[0].endTime, 9999999999);
  assert.deepEqual(view.status, { source: "api", complete: true, lastFullAt: now - 60_000, publishedAt: now - 1000, streamJoined: true, gap: false, queuedUpdates: 0, queuedRemovals: 0, retryAt: null, lastFailure: null });
  // a cached ranking is rebuilt once the catalog, the quarantine, the stream or a failure changes
  source.marketChanged({ event: "item_cancelled", hash: hash(2) });
  const after = source.marketView(100);
  assert.deepEqual(after.rows.map((r: any) => r.id), ["1", "3", "4", "5"]);
  assert.equal(after.status.queuedRemovals, 1);
  source.streamJoined = false;
  source.gapGeneration++;
  source.seaportRetryAt = now + 5000;
  source.lastFailure = { at: now - 10, error: "OpenSeaRateLimit" };
  const degraded = source.marketView(1).status;
  assert.deepEqual([degraded.streamJoined, degraded.gap, degraded.retryAt, degraded.lastFailure], [false, true, now + 5000, { at: now - 10, error: "OpenSeaRateLimit" }]);
  // an expired row leaves the view at request time without a new pass
  assert.equal(source.marketView(100, 9999999999 * 1000 + 1).rows.length, 0);
});

test("view: a prepared order is served encoded only while it is in the current catalog", () => {
  const source = apiSource(() => 1_700_000_000_000);
  const signed = source.signedOrder(hash(2).toUpperCase().replace("0X", "0x"));
  assert.equal(signed.id, "2");
  assert.equal(signed.price, "500");
  const [decoded] = decodeAbiParameters(basicOrderParameters, signed.params);
  assert.equal(decoded.offerIdentifier, 42n);
  assert.equal(decoded.additionalRecipients[0].amount, 100n);
  assert.equal(source.signedOrder(hash(1)), undefined, "unsigned");
  assert.equal(source.signedOrder(hash(6)), undefined, "quarantined");
  assert.equal(source.signedOrder(hash(9)), undefined, "unknown");
});

test("view: file orders are served as signed rows for local runs", () => {
  const source: any = new Sources({} as any, { record, strategy: { mode: "off" }, opensea: { file: "orders.json", refreshSec: 60 } } as any, () => 5);
  source.seaport = [
    { venue: "seaport", id: 42n, price: 1000n, params: "0x1234", hash: hash(1) },
    { venue: "seaport", id: 43n, price: 300n, params: "0x5678", hash: hash(2) },
  ];
  source.scores = new Map([[42n, 1000n], [43n, 1000n]]);
  const view = source.marketView(10);
  assert.equal(view.status.source, "file");
  assert.equal(view.status.complete, false, "nothing published yet");
  assert.deepEqual(view.rows.map((r: any) => [r.id, r.signed, r.endTime]), [["43", true, 0], ["42", true, 0]]);
  assert.deepEqual(source.signedOrder(hash(1)), { id: "42", price: "1000", hash: hash(1), params: "0x1234" });
});

const fake = {
  marketView: (limit: number) => ({ rows: [], catalog: { limit } }),
  signedOrder: (h: string) => (h === hash(2) ? { id: "2", price: "500", hash: h, params: "0x" } : undefined),
} as any;

test("handler: GET and HEAD only, bounded limit, order lookup, open health, bearer token", () => {
  assert.equal(handleMarketRequest(fake, { method: "POST", url: "/market" }).status, 405);
  assert.equal(handleMarketRequest(fake, { method: "GET", url: "/market" }).status, 200);
  assert.equal((handleMarketRequest(fake, { method: "GET", url: "/market" }).body as any).catalog.limit, DEFAULT_LIMIT);
  assert.equal((handleMarketRequest(fake, { method: "HEAD", url: "/market?limit=7" }).body as any).catalog.limit, 7);
  assert.equal(handleMarketRequest(fake, { url: `/market?limit=${MAX_LIMIT + 1}` }).status, 400);
  assert.equal(handleMarketRequest(fake, { url: "/market?limit=0" }).status, 400);
  assert.equal(handleMarketRequest(fake, { url: "/market?limit=1e3" }).status, 400);
  assert.equal(handleMarketRequest(fake, { url: `/market/orders/${hash(2)}` }).status, 200);
  assert.equal(handleMarketRequest(fake, { url: `/market/orders/${hash(3)}` }).status, 404);
  assert.equal(handleMarketRequest(fake, { url: "/market/orders/0x12" }).status, 400);
  assert.equal(handleMarketRequest(fake, { url: "/config" }).status, 404);
  assert.equal(handleMarketRequest(fake, { url: "/" }).status, 404);
  assert.deepEqual(handleMarketRequest(fake, { url: "/health" }, "secret").body, { ok: true });
  assert.equal(handleMarketRequest(fake, { url: "/market" }, "secret").status, 401);
  assert.equal(handleMarketRequest(fake, { url: "/market", authorization: "Bearer wrong" }, "secret").status, 401);
  assert.equal(handleMarketRequest(fake, { url: "/market", authorization: "Bearer secret" }, "secret").status, 200);
});

test("server: serves the view over HTTP without a body on HEAD and never caches", async (t) => {
  const lines: any[] = [];
  setSink((l) => lines.push(JSON.parse(l)));
  const server = startMarketServer({ port: 0, host: "127.0.0.1", token: "secret", source: fake });
  t.after(() => { server.close(); setSink((l) => process.stdout.write(l + "\n")); });
  await new Promise<void>((resolve) => server.once("listening", () => resolve()));
  const { port } = server.address() as { port: number };
  const base = `http://127.0.0.1:${port}`;
  const res = await fetch(`${base}/market?limit=2`, { headers: { authorization: "Bearer secret" } });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("cache-control"), "no-store");
  assert.deepEqual(await res.json(), { rows: [], catalog: { limit: 2 } });
  const head = await fetch(`${base}/market`, { method: "HEAD", headers: { authorization: "Bearer secret" } });
  assert.equal(head.status, 200);
  assert.equal(await head.text(), "");
  assert.equal((await fetch(`${base}/market`)).status, 401);
  assert.equal((await fetch(`${base}/market`, { method: "POST", headers: { authorization: "Bearer secret" } })).status, 405);
  assert.ok(lines.some((l) => l.msg === "market view listening" && l.token === true && l.port === port));
});
