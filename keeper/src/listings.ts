// The listings the keeper watches, per venue:
// - CreditStrategy: the credits the strategy holds with `nftForSale(id)` and the score of each id, refreshed every
//   STRATEGY_REFRESH_SEC. The held set and prices are kept by delta (./inventory.ts, from the Credits Transfer logs of
//   the strategy); a fixed id list (STRATEGY_IDS) is read in full. Scores never change and are cached.
// - Seaport 1.6 basic orders from the OpenSea API v2 (packages/engine/src/opensea.mjs), or a file of the same shape,
//   refreshed every OPENSEA_REFRESH_SEC.
// Each tick a bounded window of candidates whose price is under the bid scaled by score is read in full:
// `bidOf(id)`, the adapter's quote (the exact value the Core pays, and the adapter's own order checks), the holder
// and, for Seaport, the order status. The window advances so stale high-ranked listings cannot hide later ones.
// The simulation stays the final check.
// The same catalog feeds a read-only market view (./market-view.ts): the compatible OpenSea asks ranked by exact price
// per point with their cached immutable scores, the prepared fulfillment of a signed order, and the discovery status
// (stream, gap, reconciliation, backoff). The view publishes data only; it never sets purchase terms.

import { mkdirSync, readFileSync } from "node:fs";
import { setTimeout as delay } from "node:timers/promises";
import { join } from "node:path";
import { encodeAbiParameters, getAbiItem, getAddress, type Address, type Hex, type PublicClient } from "viem";
import { basicOrderParameters, coreAbi, creditStrategyAbi, creditsAbi, listingAdapterAbi, seaportAbi } from "@cc/engine/abis";
import { CREDIT_SCORE, CREDIT_STRATEGY, CREDITS, SEAPORT } from "@cc/engine/addresses";
import { creditScores, mc } from "@cc/engine/snapshot";
import { createMarketBook, fetchListings, type BasicParams, type SignedOrder } from "@cc/engine/opensea";
import type { Config } from "./config.ts";
import type { Listing } from "./decide.ts";
import type { Snapshot } from "@cc/engine/snapshot";
import { log, safeError } from "./log.ts";
import { indexerSeed, StrategyBook, type BookChain, type Move } from "./inventory.ts";
import { atomicJson, type PendingStore } from "./ledger.ts";
import { startOpenSeaStream, type MarketChange } from "./opensea-stream.ts";
import { alert } from "./alert.ts";

// the ids read per multicall when indexing the strategy scores
const SCORE_READ = 1500;
// the most candidates per venue read in full each tick
const MAX_CANDIDATES = 40;

// `abi.encode(BasicOrderParameters)`, the `params` of SeaportBasicAdapter
export function encodeBasicOrder(p: BasicParams): Hex {
  return encodeAbiParameters(basicOrderParameters, [
    {
      considerationToken: getAddress(p.considerationToken),
      considerationIdentifier: BigInt(p.considerationIdentifier),
      considerationAmount: BigInt(p.considerationAmount),
      offerer: getAddress(p.offerer),
      zone: getAddress(p.zone),
      offerToken: getAddress(p.offerToken),
      offerIdentifier: BigInt(p.offerIdentifier),
      offerAmount: BigInt(p.offerAmount),
      basicOrderType: Number(p.basicOrderType),
      startTime: BigInt(p.startTime),
      endTime: BigInt(p.endTime),
      zoneHash: p.zoneHash as Hex,
      salt: BigInt(p.salt),
      offererConduitKey: p.offererConduitKey as Hex,
      fulfillerConduitKey: p.fulfillerConduitKey as Hex,
      totalOriginalAdditionalRecipients: BigInt(p.totalOriginalAdditionalRecipients),
      additionalRecipients: p.additionalRecipients.map((r) => ({ amount: BigInt(r.amount), recipient: getAddress(r.recipient) })),
      signature: p.signature as Hex,
    },
  ]);
}

// blocks per getLogs call and ids per nftForSale multicall of the strategy inventory
const LOG_RANGE = 10_000n;
const PRICE_READ = 1500;
const transferEvent = getAbiItem({ abi: creditsAbi, name: "Transfer" });

interface Watched {
  venue: Listing["venue"];
  adapter: Address;
  id: bigint;
  // the listed price: nftForSale for the strategy, the consideration total for Seaport
  price: bigint;
  params: Hex;
  hash?: Hex;
  offerer?: Address;
}

type MarketUpdate = { revision: number; remove: boolean; receivedAt: number; event?: string; id?: bigint; price?: bigint };

// one compatible ask of the market view; numbers are decimal strings, `endTime` unix seconds (0 for a file order)
export interface MarketViewRow { id: string; price: string; hash: string; endTime: number; score: string | null; signed: boolean }
export interface MarketView {
  chainId: number;
  core: Address;
  seaportAdapter: Address;
  credits: Address;
  builtAt: number;
  status: {
    source: "api" | "file" | "off";
    complete: boolean;
    lastFullAt: number;
    publishedAt: number;
    streamJoined: boolean;
    gap: boolean;
    queuedUpdates: number;
    queuedRemovals: number;
    retryAt: number | null;
    lastFailure: { at: number; error: string } | null;
  };
  catalog: { total: number; scored: number; signed: number; limit: number };
  rows: MarketViewRow[];
}
export interface SignedView { id: string; price: string; hash: string; params: Hex }

export class Sources {
  private scores = new Map<bigint, bigint>();
  private strategy: Watched[] = [];
  private strategyAt = 0;
  private book?: StrategyBook;
  private seaport: Watched[] = [];
  private seaportAt = 0;
  private seaportRetryAt = 0;
  private seaportRefresh?: Promise<void>;
  private market = createMarketBook();
  private marketChanges = new Map<string, MarketUpdate>();
  private transferred = new Set<string>();
  private blocked = new Set<string>();
  private pendingUntil = new Map<string, number>();
  private marketRevision = 0;
  private gapGeneration = 0;
  private overflowGeneration = 0;
  private overflowed = false;
  private reconciledGeneration = -1;
  private lastFullAttempt = 0;
  private stream?: ReturnType<typeof startOpenSeaStream>;
  private streamJoined = false;
  private streamReady = false;
  // Decoded simulation faults have a short in-memory wait; receipt reverts also have a durable wait.
  private cooldown = new Map<string, number>();
  private nextCandidate = { strategy: 0, seaport: 0 };
  // the market view: a revision per catalog, quarantine, stream or failure change, the ranked rows cached per revision
  private viewRevision = 0;
  private publishedAt = 0;
  private lastFailure?: { at: number; error: string };
  private ranked?: { revision: number; rows: MarketViewRow[] };

  private client: PublicClient;
  private cfg: Config;
  private now: () => number;
  private pending?: PendingStore;
  constructor(
    client: PublicClient,
    cfg: Config,
    now: () => number = Date.now,
    pending?: PendingStore,
  ) {
    this.client = client;
    this.cfg = cfg;
    this.now = now;
    this.pending = pending;
    this.loadScores();
  }

  startStream() {
    if (this.stream || this.cfg.record.chainId !== 1 || this.cfg.opensea.file || !this.cfg.opensea.key) return;
    this.stream = startOpenSeaStream({
      key: this.cfg.opensea.key,
      onChange: (change) => this.marketChanged(change),
      onGap: () => { this.gapGeneration++; },
      onStatus: (joined) => {
        this.streamJoined = joined;
        this.viewRevision++;
        log("info", "opensea stream status", { joined });
      },
    });
  }

  private marketChanged(change: MarketChange) {
    const hash = change.hash?.toLowerCase();
    const remove = ["item_cancelled", "order_invalidate", "item_sold", "item_transferred"].includes(change.event);
    if (change.event === "item_transferred" && change.id !== undefined) {
      this.transferred.add(String(change.id));
      this.seaport = this.seaport.filter(order => order.id !== change.id);
    }
    if (hash && (!remove || this.market.rows.has(hash) || this.marketChanges.has(hash) || !this.market.complete)) {
      const previous = this.marketChanges.get(hash);
      const known = this.market.rows.get(hash);
      this.marketChanges.set(hash, { revision: ++this.marketRevision, remove, receivedAt: this.now(), event: change.event,
        id: change.id ?? (known ? BigInt(known.id) : previous?.id),
        price: remove ? undefined : change.price ?? (known ? BigInt(known.price) : previous?.price) });
      if (remove) {
        this.blocked.add(hash);
        this.seaport = this.seaport.filter(order => order.hash?.toLowerCase() !== hash);
      }
    }
    // Unknown cancellation floods must not turn into REST requests or an unbounded event buffer.
    if (this.marketChanges.size + this.transferred.size > 20_000) {
      this.marketChanges.clear();
      this.transferred.clear();
      this.pendingUntil.clear();
      this.blocked.clear();
      this.gapGeneration++;
      this.overflowGeneration++;
      this.overflowed = true;
      log("warn", "opensea stream queue overflow, reconciliation required");
    }
    this.viewRevision++;
  }

  private ackMarketChanges(changes: ReadonlyArray<readonly [string, MarketUpdate]>, reconcile = false, observedAt = this.now()) {
    for (const [hash, change] of changes) {
      // Fresh notifications may precede REST visibility; missing new listings always need their canonical read.
      if (reconcile && !change.remove && !this.market.rows.has(hash) && (change.event === "item_listed" || observedAt - change.receivedAt < 30_000)) continue;
      const latest = this.marketChanges.get(hash);
      // Repeated removals are already satisfied once publication leaves the order absent; newer positive updates are not.
      if (!latest || (latest.revision !== change.revision && !(change.remove && latest.remove && !this.market.rows.has(hash)))) continue;
      this.marketChanges.delete(hash);
      this.blocked.delete(hash);
      this.pendingUntil.delete(hash);
    }
  }

  private needsMarketReconcile() {
    const interval = this.streamJoined ? 30 * 60_000 : this.cfg.opensea.refreshSec * 1000;
    return !this.market.complete || this.now() - this.market.lastFullAt >= interval
      || (this.gapGeneration !== this.reconciledGeneration && this.now() - this.lastFullAttempt >= 60_000)
      // A collection page covers 200 orders; bulk revalidations are cheaper to reconcile than fetch individually.
      || ([...this.marketChanges.values()].filter(change => !change.remove).length > 128
        && this.now() - this.lastFullAttempt >= 300_000);
  }

  private async prioritizedUpdates() {
    const updates = [...this.marketChanges].filter(([hash, change]) => !change.remove && (this.pendingUntil.get(hash) ?? 0) <= this.now());
    const missing = [...new Set(updates.filter(([, change]) => change.price && change.id !== undefined && !this.scores.has(change.id)).map(([, change]) => change.id!))].slice(0, 64);
    try { await this.scoresOf(missing, true); }
    catch (error) { log("warn", "opensea priority score hints unavailable", { error: safeError(error) }); }
    // Hints schedule canonical reads only. Signed order terms and on-chain checks still control every purchase.
    const ranked = updates.sort(([, a], [, b]) => {
      const as = a.id === undefined ? 0n : this.scores.get(a.id) ?? 0n;
      const bs = b.id === undefined ? 0n : this.scores.get(b.id) ?? 0n;
      const ap = a.price && as > 0n, bp = b.price && bs > 0n;
      if (ap && bp) {
        const delta = a.price! * bs - b.price! * as;
        if (delta !== 0n) return delta < 0n ? -1 : 1;
      } else if (ap || bp) return ap ? -1 : 1;
      return a.revision - b.revision;
    });
    const unpriced = ranked.filter(([, change]) => !change.price || change.id === undefined || !this.scores.has(change.id)).slice(0, 8);
    const preferred = ranked.filter(entry => !unpriced.includes(entry));
    return [...preferred.slice(0, 32 - unpriced.length), ...unpriced];
  }

  private marketDue() {
    const now = this.now();
    if (now < this.seaportRetryAt) return false;
    if (this.overflowed) return now - this.lastFullAttempt >= 60_000;
    return this.needsMarketReconcile()
      || [...this.market.rows.values()].some(order => Number(order.endTime) * 1000 <= now)
      || (([...this.marketChanges].some(([hash, change]) => change.remove || (this.pendingUntil.get(hash) ?? 0) <= now)
        || this.transferred.size > 0) && now - this.seaportAt >= 5000);
  }

  private scoreKey() {
    return `${this.cfg.record.chainId}:${CREDITS.toLowerCase()}:${CREDIT_SCORE.toLowerCase()}`;
  }

  private loadScores() {
    if (!this.cfg.stateDir) return;
    try {
      const data = JSON.parse(readFileSync(join(this.cfg.stateDir, "credit-scores.json"), "utf8"));
      if (data.key !== this.scoreKey() || !Array.isArray(data.scores)) throw new Error("score cache identity or shape mismatch");
      const scores = new Map<bigint, bigint>();
      for (const row of data.scores) {
        if (!Array.isArray(row) || row.length !== 2 || !row.every(v => typeof v === "string" && /^\d+$/.test(v))) throw new Error("invalid score cache row");
        const [id, score] = row.map(BigInt);
        if (id >= 2n ** 256n || score <= 0n || score >= 2n ** 256n || scores.has(id)) throw new Error("invalid score cache value");
        scores.set(id, score);
      }
      this.scores = scores;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") log("warn", "credit score cache ignored", { error: safeError(error) });
    }
  }

  private saveScores() {
    if (!this.cfg.stateDir) return;
    mkdirSync(this.cfg.stateDir, { recursive: true });
    atomicJson(join(this.cfg.stateDir, "credit-scores.json"), {
      key: this.scoreKey(), scores: [...this.scores].map(([id, score]) => [String(id), String(score)]),
    });
  }

  coolDown(key: string, sec: number) {
    this.cooldown.set(key, this.now() + sec * 1000);
  }

  private async scoresOf(ids: bigint[], paced = false) {
    const missing = [...new Set(ids)].filter((id) => !this.scores.has(id));
    const size = paced ? 64 : SCORE_READ;
    // Full-market discovery reads only missing immutable facts, at most two multicalls per second.
    const client = paced ? { multicall: async (args: Parameters<PublicClient["multicall"]>[0]) => {
      await delay(500);
      return this.client.multicall(args);
    } } as Pick<PublicClient, "multicall"> : this.client;
    for (let i = 0; i < missing.length; i += size) {
      const part = missing.slice(i, i + size);
      const sc = await creditScores(client, part);
      if (sc.length !== part.length || sc.some(score => typeof score !== "bigint" || score < 0n)) throw new Error("invalid Credit scores");
      part.forEach((id, j) => { if (sc[j] > 0n) this.scores.set(id, sc[j]); });
      this.saveScores();
    }
  }

  // nftForSale per id, undefined for a failed read
  private async readPrices(ids: bigint[]): Promise<(bigint | undefined)[]> {
    const out: (bigint | undefined)[] = [];
    for (let i = 0; i < ids.length; i += PRICE_READ) {
      const r = await this.client.multicall({
        ...mc,
        allowFailure: true,
        contracts: ids.slice(i, i + PRICE_READ).map((id) => ({ address: CREDIT_STRATEGY, abi: creditStrategyAbi, functionName: "nftForSale", args: [id] }) as const),
      });
      out.push(...r.map((x) => (x.status === "success" ? (x.result as bigint) : undefined)));
    }
    return out;
  }

  private strategyBook(): StrategyBook {
    const client = this.client;
    const indexer = this.cfg.indexerUrl;
    const chain: BookChain = {
      head: () => client.getBlockNumber(),
      moves: async (from, to) => {
        const out: Move[] = [];
        for (let a = from; a <= to; a += LOG_RANGE) {
          const b = a + LOG_RANGE - 1n < to ? a + LOG_RANGE - 1n : to;
          const range = { address: CREDITS, event: transferEvent, fromBlock: a, toBlock: b } as const;
          const [into, outOf] = await Promise.all([
            client.getLogs({ ...range, args: { to: CREDIT_STRATEGY } }),
            client.getLogs({ ...range, args: { from: CREDIT_STRATEGY } }),
          ]);
          for (const [logs, isIn] of [[into, true], [outOf, false]] as const)
            for (const l of logs) out.push({ block: l.blockNumber!, index: l.logIndex!, id: l.args.id!, into: isIn });
        }
        return out;
      },
      held: async () => [...(await client.readContract({ address: CREDITS, abi: creditsAbi, functionName: "tokensOf", args: [CREDIT_STRATEGY] }))],
      prices: (ids) => this.readPrices(ids),
      seed: indexer ? () => indexerSeed(indexer) : undefined,
    };
    return new StrategyBook(chain, {
      file: join(this.cfg.stateDir, "strategy-inventory.json"),
      key: `${this.cfg.record.chainId}:${CREDIT_STRATEGY.toLowerCase()}`,
      fullRead: this.cfg.strategyFullRead,
      now: this.now,
    });
  }

  private async refreshStrategy() {
    const s = this.cfg.strategy;
    if (s.mode === "off" || this.now() - this.strategyAt < this.cfg.strategyRefreshSec * 1000) return;
    this.strategyAt = this.now();
    let listed: { id: bigint; price: bigint }[];
    if (s.mode === "ids") {
      const prices = await this.readPrices(s.ids);
      listed = s.ids.flatMap((id, i) => ((prices[i] ?? 0n) > 0n ? [{ id, price: prices[i]! }] : []));
    } else {
      this.book ??= this.strategyBook();
      listed = [...(await this.book.refresh())].map(([id, price]) => ({ id, price }));
    }
    await this.scoresOf(listed.map((x) => x.id));
    this.strategy = listed.map(({ id, price }) => ({
      venue: "strategy" as const,
      adapter: this.cfg.record.strategyAdapter,
      id,
      price,
      params: "0x" as Hex,
    }));
    log("info", "strategy listings indexed", { listed: this.strategy.length });
  }

  private async refreshSeaport() {
    const o = this.cfg.opensea;
    if (!o.file && !o.key) return;
    if (o.file ? this.now() - this.seaportAt < o.refreshSec * 1000 : !this.marketDue()) return;
    this.seaportAt = this.now();
    let orders: SignedOrder[];
    try {
      if (o.file) orders = JSON.parse(readFileSync(o.file, "utf8")).orders;
      else {
        if (this.stream && !this.streamReady) {
          await this.stream.ready;
          this.streamReady = true;
        }
        if (this.market.complete) for (const id of this.transferred) {
          for (const [hash, order] of this.market.rows) if (order.id === id) {
            this.marketChanges.set(hash, { revision: ++this.marketRevision, remove: true, receivedAt: this.now() });
            this.blocked.add(hash);
          }
        }
        if (this.market.complete) this.transferred.clear();
        const reconcile = this.needsMarketReconcile();
        const generation = this.gapGeneration;
        const overflow = this.overflowGeneration;
        if (reconcile) this.lastFullAttempt = this.now();
        const reconciliationStarted = this.now();
        const snapshot = [...this.marketChanges];
        const changes = snapshot.filter(([, change]) => change.remove);
        if (!reconcile) changes.push(...await this.prioritizedUpdates());
        const r = await fetchListings({
          key: o.key!,
          rpcUrls: this.cfg.rpcUrls,
          adapter: this.cfg.record.seaportAdapter,
          fullScan: true,
          book: this.market,
          reconcile,
          updates: changes.filter(([, change]) => !change.remove).map(([hash]) => hash),
          removals: changes.filter(([, change]) => change.remove).map(([hash]) => hash),
          getScores: async (ids) => {
            const tokens = ids.map(BigInt);
            await this.scoresOf(tokens, true);
            return tokens.map(id => this.scores.get(id) ?? 0n);
          },
          sign: o.sign,
          horizon: 0,
        });
        if (!r.complete) throw new Error("OpenSea full scan is incomplete");
        if (overflow !== this.overflowGeneration) throw Object.assign(new Error("opensea: stream buffer overflow during pass"), { retryAt: this.now() + 1000 });
        if (reconcile) this.overflowed = false;
        if (reconcile) this.reconciledGeneration = generation;
        // A completed collection scan supersedes older revalidations. Missing new listings may still be propagating.
        this.ackMarketChanges(reconcile ? snapshot : changes, reconcile, reconciliationStarted);
        // Notifications received during the pass must not resurrect a quarantined order.
        orders = r.orders.filter(order => !this.blocked.has(order.hash.toLowerCase()) && !this.transferred.has(order.id));
        const queuedRemovals = [...this.marketChanges.values()].filter(change => change.remove).length;
        log("info", "opensea listings fetched", { mode: reconcile ? "full" : "incremental", streamJoined: this.streamJoined,
          complete: r.complete, pages: r.pages, fetched: r.fetched, fit: r.fit, signed: orders.length,
          validationTruncated: r.validationTruncated, bookSize: r.bookSize, reusedParams: r.reusedParams, cachedScores: this.scores.size, queued: this.marketChanges.size,
          queuedUpdates: this.marketChanges.size - queuedRemovals, queuedRemovals,
          listedUpdates: changes.filter(([, change]) => !change.remove && change.event === "item_listed").length,
          gap: this.gapGeneration !== this.reconciledGeneration, dropped: r.dropped });
      }
      if (!Array.isArray(orders)) throw new Error("orders is not an array");
    } catch (e) {
      const retryAt = (e as { retryAt?: number }).retryAt;
      const pendingHash = (e as { name?: string; hash?: string }).name === "OpenSeaPending" ? (e as { hash?: string }).hash : undefined;
      if (pendingHash) this.pendingUntil.set(pendingHash, this.now() + 30_000);
      this.seaportRetryAt = Math.max(this.seaportRetryAt, pendingHash ? this.now() + 1000 : typeof retryAt === "number" && Number.isFinite(retryAt) ? retryAt : this.now() + o.refreshSec * 1000);
      if (!pendingHash) this.lastFailure = { at: this.now(), error: safeError(e) };
      this.viewRevision++;
      log("warn", "opensea fetch failed, keeping the cached orders", { complete: false, retryAt: this.seaportRetryAt || undefined, error: safeError(e) });
      if (!pendingHash) void alert(this.cfg.alertWebhook, "opensea", "OpenSea discovery failed; keeping cached orders and backing off", { error: safeError(e), retryAt: this.seaportRetryAt });
      return;
    } finally {
      this.seaportAt = this.now();
    }
    // A malformed cached or API order must not block the other signed orders or the rest of the tick.
    const watched: Watched[] = [];
    for (const x of orders) {
      try {
        if (!x.hash) {
          log("warn", "seaport order has no hash, skipped", { id: String(x.id), offerer: x.params.offerer });
          continue;
        }
        if (!/^0x[0-9a-fA-F]{64}$/.test(x.hash)) throw new Error("invalid order hash");
        if (BigInt(x.price) <= 0n) {
          log("warn", "seaport order has no positive price, skipped", { id: String(x.id) });
          continue;
        }
        watched.push({
          venue: "seaport",
          adapter: this.cfg.record.seaportAdapter,
          id: BigInt(x.id),
          price: BigInt(x.price),
          params: encodeBasicOrder(x.params),
          hash: x.hash as Hex,
          offerer: getAddress(x.params.offerer),
        });
      } catch {
        log("warn", "malformed seaport order skipped", { id: String(x?.id ?? "unknown") });
      }
    }
    this.seaport = watched.filter(order => !this.blocked.has(order.hash!.toLowerCase()) && !this.transferred.has(String(order.id)));
    this.publishedAt = this.now();
    this.viewRevision++;
    await this.scoresOf(this.seaport.map((w) => w.id));
    this.viewRevision++;
  }

  // The compatible asks the website ranks: the whole observed catalog (or the file's orders) less quarantined and
  // expired rows, by exact price per point with cached scores, unscored rows last by price. Cached per revision.
  private rankedRows(): MarketViewRow[] {
    if (this.ranked?.revision === this.viewRevision) return this.ranked.rows;
    const rows: MarketViewRow[] = [];
    if (this.cfg.opensea.file) {
      for (const w of this.seaport) if (w.hash) rows.push({ id: String(w.id), price: String(w.price), hash: w.hash.toLowerCase(), endTime: 0, score: this.scores.get(w.id)?.toString() ?? null, signed: true });
    } else {
      for (const [hash, row] of this.market.rows) {
        if (this.blocked.has(hash) || this.transferred.has(row.id)) continue;
        rows.push({ id: row.id, price: row.price, hash, endTime: Number(row.endTime), score: this.scores.get(BigInt(row.id))?.toString() ?? null, signed: this.market.signed.has(hash) });
      }
    }
    const price = (r: MarketViewRow) => BigInt(r.price);
    rows.sort((a, b) => {
      if ((a.score === null) !== (b.score === null)) return a.score === null ? 1 : -1;
      if (a.score !== null && b.score !== null) {
        const left = price(a) * BigInt(b.score);
        const right = price(b) * BigInt(a.score);
        if (left !== right) return left < right ? -1 : 1;
      }
      const pa = price(a), pb = price(b);
      if (pa !== pb) return pa < pb ? -1 : 1;
      return a.id.length === b.id.length ? (a.id < b.id ? -1 : a.id > b.id ? 1 : 0) : a.id.length - b.id.length;
    });
    this.ranked = { revision: this.viewRevision, rows };
    return rows;
  }

  // The read-only market view of ./market-view.ts. `limit` bounds the rows; the counts cover the whole catalog.
  marketView(limit: number, now = this.now()): MarketView {
    const live = this.rankedRows().filter(r => r.endTime === 0 || r.endTime * 1000 > now);
    const o = this.cfg.opensea;
    let queuedRemovals = 0;
    for (const change of this.marketChanges.values()) if (change.remove) queuedRemovals++;
    return {
      chainId: this.cfg.record.chainId,
      core: this.cfg.record.core,
      seaportAdapter: this.cfg.record.seaportAdapter,
      credits: CREDITS,
      builtAt: now,
      status: {
        source: o.file ? "file" : o.key ? "api" : "off",
        complete: o.file ? this.publishedAt > 0 : this.market.complete,
        lastFullAt: o.file ? this.publishedAt : this.market.lastFullAt,
        publishedAt: this.publishedAt,
        streamJoined: this.streamJoined,
        gap: !o.file && (this.gapGeneration !== this.reconciledGeneration || this.overflowed),
        queuedUpdates: this.marketChanges.size - queuedRemovals,
        queuedRemovals,
        retryAt: this.seaportRetryAt > now ? this.seaportRetryAt : null,
        lastFailure: this.lastFailure ?? null,
      },
      catalog: { total: live.length, scored: live.filter(r => r.score !== null).length, signed: live.filter(r => r.signed).length, limit },
      rows: live.slice(0, limit),
    };
  }

  // The prepared fulfillment of one order in the view, encoded for Core.buyListing; undefined for an unknown,
  // quarantined, expired or unsigned order. Advisory: the Core, the adapter and Seaport still judge the order.
  signedOrder(hash: string, now = this.now()): SignedView | undefined {
    const key = hash.toLowerCase();
    if (this.cfg.opensea.file) {
      const w = this.seaport.find(order => order.hash?.toLowerCase() === key);
      return w ? { id: String(w.id), price: String(w.price), hash: key, params: w.params } : undefined;
    }
    const row = this.market.rows.get(key);
    const order = this.market.signed.get(key);
    if (!row || !order || this.blocked.has(key) || this.transferred.has(row.id) || Number(row.endTime) * 1000 <= now) return undefined;
    try {
      return { id: order.id, price: order.price, hash: key, params: encodeBasicOrder(order.params) };
    } catch {
      return undefined;
    }
  }

  // Read one rotating window per venue at the block. The cap bounds RPC work per tick and every ranked listing gets a turn.
  async candidates(snap: Snapshot, blockNumber: bigint): Promise<Listing[]> {
    await this.refreshStrategy();
    if (this.cfg.opensea.file) await this.refreshSeaport();
    else if (!this.seaportRefresh && this.cfg.opensea.key && this.marketDue()) {
      // A complete market scan can take minutes; independent Core doors keep running during discovery.
      this.seaportRefresh = this.refreshSeaport().catch(error => {
        log("warn", "opensea background refresh failed", { complete: false, error: safeError(error) });
      }).finally(() => { this.seaportRefresh = undefined; });
    }
    const ref = 1_000_000n;
    const t = this.now();
    const pick = (venue: "strategy" | "seaport", ws: Watched[]) => {
      const ranked = ws
        .filter((w) => {
          const key = `${w.venue}:${w.id}`;
          return w.price > 0n && Math.max(this.cooldown.get(key) ?? 0, this.pending?.cooldownUntil(key) ?? 0) <= t;
        })
        .map((w) => ({ w, bid: ((this.scores.get(w.id) ?? 0n) * snap.ethRate) / ref }))
        .filter((x) => x.bid >= x.w.price)
        .sort((a, b) => {
          const ar = (a.bid * 10_000n) / a.w.price;
          const br = (b.bid * 10_000n) / b.w.price;
          return ar === br ? (a.w.id < b.w.id ? -1 : a.w.id > b.w.id ? 1 : 0) : ar > br ? -1 : 1;
        });
      if (!ranked.length) return [];
      const start = this.nextCandidate[venue] % ranked.length;
      const count = Math.min(MAX_CANDIDATES, ranked.length);
      this.nextCandidate[venue] = (start + count) % ranked.length;
      return Array.from({ length: count }, (_, i) => ranked[(start + i) % ranked.length].w);
    };
    const ws = [...pick("strategy", this.strategy), ...pick("seaport", this.seaport)];
    if (ws.length === 0) return [];
    const core = this.cfg.record.core;
    // three reads per listing plus the order status of a hashed one, typed loosely: the mixed abis exceed the
    // compiler's instantiation depth
    const contracts: any[] = ws.flatMap((w) => [
      { address: core, abi: coreAbi, functionName: "bidOf", args: [w.id] },
      { address: w.adapter, abi: listingAdapterAbi, functionName: "price", args: [w.id, w.params] },
      { address: CREDITS, abi: creditsAbi, functionName: "ownerOf", args: [w.id] },
      ...(w.hash ? [{ address: SEAPORT, abi: seaportAbi, functionName: "getOrderStatus", args: [w.hash] }] : []),
    ]);
    const r = (await this.client.multicall({ ...mc, blockNumber, allowFailure: true, contracts })) as { status: string; result?: unknown }[];
    let at = 0;
    return ws.map((w) => {
      const [bidR, quoteR, ownerR] = r.slice(at, at + 3);
      const statusR = w.hash ? r[at + 3] : undefined;
      at += w.hash ? 4 : 3;
      const l: Listing = { venue: w.venue, adapter: w.adapter, id: w.id, price: w.price, bid: 0n, params: w.params, valid: true };
      if (bidR.status !== "success") return { ...l, valid: false, why: "bidOf failed" };
      l.bid = bidR.result as bigint;
      if (quoteR.status !== "success") return { ...l, valid: false, why: "the adapter refused the listing" };
      // the adapter's value is what the Core pays the venue
      l.price = (quoteR.result as readonly [Address, bigint, Hex])[1];
      const owner = ownerR.status === "success" ? (ownerR.result as Address) : undefined;
      if (owner?.toLowerCase() === core.toLowerCase()) return { ...l, valid: false, why: "AlreadyOwned" };
      if (w.venue === "strategy" && owner?.toLowerCase() !== CREDIT_STRATEGY.toLowerCase()) return { ...l, valid: false, why: "the strategy no longer holds it" };
      if (w.venue === "seaport") {
        if (owner?.toLowerCase() !== w.offerer?.toLowerCase()) return { ...l, valid: false, why: "the offerer no longer holds it" };
        if (statusR?.status === "success") {
          const [, cancelled, filled, size] = statusR.result as readonly [boolean, boolean, bigint, bigint];
          if (cancelled) return { ...l, valid: false, why: "order cancelled" };
          if (size > 0n && filled >= size) return { ...l, valid: false, why: "order filled" };
        }
      }
      return l;
    });
  }
}
