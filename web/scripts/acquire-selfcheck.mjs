// promise: both venues use the keeper cache without visitor history scans; unsigned asks stay visible but cannot acquire.
import assert from "node:assert/strict";
import { register } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join } from "node:path";

const web = join(dirname(fileURLToPath(import.meta.url)), "..");
const consumer = pathToFileURL(join(web, "lib/useAcquire.ts")).href;
const rules = pathToFileURL(join(web, "lib/acquire.ts")).href;
const stubs = {
  react: "export const useEffect=()=>{}; export const useState=x=>[x,()=>{}];",
  wagmi: "export const useAccount=()=>({}); export const usePublicClient=()=>({});",
  "@rainbow-me/rainbowkit": "export const useConnectModal=()=>({});",
  "./config": "export const core='0x1',strategy='0x2',strategyAdapter='0x3',seaportAdapter='0x4',strategyStartBlock=1n;",
  "./abis": "export const coreAbi=[],strategyAbi=[{},{}];",
  "./live": "export const useSnapshot=()=>({data:{paused:false}}); export const creditScores=async()=>[];",
  "./indexer": "export const getIxMode=()=> 'chain'; export const fetchStrategyListings=async()=>[]; export const fetchScoresIx=async()=>new Map();",
  "./market-view": "export const readMarketView=async()=>{globalThis.__acquireFixture.reads++;return globalThis.__acquireFixture.market;};",
  "./tx": "export const useTx=()=>({run:()=>{throw Error('unexpected transaction')},pending:false});",
};
register("data:text/javascript," + encodeURIComponent(`
const stubs=${JSON.stringify(stubs)};
export async function resolve(spec,ctx,next){
 if(ctx.parentURL===${JSON.stringify(consumer)}){
  if(spec==='./acquire') return {url:${JSON.stringify(rules)},shortCircuit:true};
  if(spec in stubs) return {url:'acquire-fixture:'+encodeURIComponent(spec),shortCircuit:true};
 }
 return next(spec,ctx);
}
export async function load(url,ctx,next){
 if(url.startsWith('acquire-fixture:')) return {format:'module',source:stubs[decodeURIComponent(url.slice(16))],shortCircuit:true};
 return next(url,ctx);
}`));
const { parseView } = await import(pathToFileURL(join(web, "lib/listings-api.ts")).href);
const { gatherListings, useAcquireTx } = await import(consumer);
const { preparedForAcquire } = await import(rules);
const body = {
  chainId: 1, core: "0x" + "1".repeat(40), seaportAdapter: "0x" + "2".repeat(40), builtAt: 3000,
  status: { source: "api", complete: true, lastFullAt: 1000, publishedAt: 2000, streamJoined: true, gap: false, queuedUpdates: 0, queuedRemovals: 0, retryAt: null, lastFailure: null },
  catalog: { total: 2, scored: 2, signed: 1, limit: 1000 },
  rows: [
    { id: "1", price: "20", hash: "0x" + "1".repeat(64), endTime: 9999999999, score: "100", signed: true },
    { id: "2", price: "10", hash: "0x" + "2".repeat(64), endTime: 9999999999, score: "200", signed: false },
  ],
  strategy: { publishedAt: 2000, lastFailure: null, total: 1, rows: [{ id: "7", price: "8", score: "300" }] },
};
const market = { available: true, stale: false, view: parseView(body).view };
globalThis.__acquireFixture = { market, reads: 0 };
const originalFetch = globalThis.fetch;
globalThis.fetch = () => { throw Error("unexpected visitor RPC or OpenSea request"); };
let chainReads = 0;
const visitor = () => ({ getLogs() { chainReads++; throw Error("unexpected history scan"); } });
try {
  for (let i = 0; i < 3; i++) {
    const view = await gatherListings(visitor());
    assert.deepEqual(view.listings.map(l => [l.id, l.prepared]), [[7n, undefined], [1n, true], [2n, false]]);
    assert.equal(view.known.get(7n), 300n);
    assert.equal(view.strategyStatus.pending, false);
    assert.equal(view.strategyStatus.publishedAt, 2000);
    assert.deepEqual(useAcquireTx(1n).available(view.listings).map(l => l.id), [7n, 1n]);
  }
  assert.equal(globalThis.__acquireFixture.reads, 3, "one shared view read per consumer, both venues together");
  assert.equal(chainReads, 0, "new visitors never scan Strategy history");
  body.strategy.lastFailure = { at: 3000, error: "synthetic private details" };
  market.view = parseView(body).view;
  const failed = await gatherListings(visitor());
  assert.deepEqual(failed.listings.map(l => l.id), [7n, 1n, 2n], "failed Strategy refresh retains the keeper's cached rows");
  assert.match(failed.strategyStatus.error, /refresh failed/);
  assert.ok(!failed.strategyStatus.error.includes("private"));
  body.strategy.publishedAt = 4000;
  market.view = parseView(body).view;
  assert.equal((await gatherListings(visitor())).strategyStatus.error, undefined, "later success supersedes historical failure");
  const { strategy, ...legacy } = body;
  market.view = parseView(legacy).view;
  const warming = await gatherListings(visitor());
  assert.equal(warming.strategyStatus.pending, true);
  assert.deepEqual(warming.listings.map(l => l.id), [1n, 2n], "legacy or warming Strategy never hides OpenSea");
  assert.throws(() => parseView({ ...body, strategy: { ...strategy, rows: [{ id: "bad", price: "1", score: null }] } }), /strategy/);
  assert.throws(() => parseView({ ...body, strategy: { ...strategy, total: 0 } }), /strategy/);
  assert.throws(() => parseView({ ...body, strategy: { ...strategy, rows: Array(1001).fill(strategy.rows[0]), total: 1001 } }), /strategy/);
  assert.equal(preparedForAcquire({ id: 3n, price: 1n, source: "opensea", params: "0x" }), false);
  assert.equal(preparedForAcquire({ id: 3n, price: 1n, source: "strategy", params: "0x" }), true);
} finally { globalThis.fetch = originalFetch; }
console.log("acquire selfcheck passed: shared keeper catalogs, zero visitor chain scans, safe failure status, bounded schema and prepared eligibility");
