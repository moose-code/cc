// The listings the keeper watches, per venue:
// - CreditStrategy: the credits the strategy holds (`Credits.tokensOf(strategy)`, or a fixed id list) with
//   `nftForSale(id)` and the score of each id, refreshed every STRATEGY_REFRESH_SEC. scores never change and are cached.
// - Seaport 1.6 basic orders from the OpenSea API v2 (packages/engine/src/opensea.mjs), or a file of the same shape,
//   refreshed every OPENSEA_REFRESH_SEC.
// Each block the candidates whose price is under the bid scaled by score are read in full at that block: `bidOf(id)`,
// the adapter's quote (the exact value the Core pays, and the adapter's own order checks), the holder of the credit
// and, for Seaport, the order status. The simulation stays the final check.

import { readFileSync } from "node:fs";
import { encodeAbiParameters, getAddress, type Address, type Hex, type PublicClient } from "viem";
import { basicOrderParameters, coreAbi, creditStrategyAbi, creditsAbi, listingAdapterAbi, seaportAbi } from "@cc/engine/abis";
import { CREDIT_STRATEGY, CREDITS, SEAPORT } from "@cc/engine/addresses";
import { creditScores, mc } from "@cc/engine/snapshot";
import { fetchListings, type BasicParams, type SignedOrder } from "@cc/engine/opensea";
import type { Config } from "./config.ts";
import type { Listing } from "./decide.ts";
import type { Snapshot } from "@cc/engine/snapshot";
import { log, safeError } from "./log.ts";

// the ids read per multicall when indexing the strategy scores
const SCORE_BATCH = 1500;
// the ids read per multicall when reading the strategy nftForSale prices
const PRICE_BATCH = 1500;
// the most candidates per venue read in full each block, best ratio of bid to price first
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

export class Sources {
  private scores = new Map<bigint, bigint>();
  private strategy: Watched[] = [];
  private strategyAt = 0;
  private seaport: Watched[] = [];
  private seaportAt = 0;
  // listings whose simulation reverted, skipped until the time stored
  private cooldown = new Map<string, number>();

  private client: PublicClient;
  private cfg: Config;
  private now: () => number;
  constructor(
    client: PublicClient,
    cfg: Config,
    now: () => number = Date.now,
  ) {
    this.client = client;
    this.cfg = cfg;
    this.now = now;
  }

  coolDown(key: string, sec: number) {
    this.cooldown.set(key, this.now() + sec * 1000);
  }

  private async scoresOf(ids: bigint[]) {
    const missing = ids.filter((id) => !this.scores.has(id));
    for (let i = 0; i < missing.length; i += SCORE_BATCH) {
      const part = missing.slice(i, i + SCORE_BATCH);
      const sc = await creditScores(this.client, part);
      part.forEach((id, j) => this.scores.set(id, sc[j]));
    }
  }

  private async refreshStrategy() {
    const s = this.cfg.strategy;
    if (s.mode === "off" || this.now() - this.strategyAt < this.cfg.strategyRefreshSec * 1000) return;
    this.strategyAt = this.now();
    const ids =
      s.mode === "ids"
        ? s.ids
        : [...(await this.client.readContract({ address: CREDITS, abi: creditsAbi, functionName: "tokensOf", args: [CREDIT_STRATEGY] }))];
    const prices: bigint[] = [];
    for (let i = 0; i < ids.length; i += PRICE_BATCH) {
      const r = await this.client.multicall({
        ...mc,
        allowFailure: true,
        contracts: ids.slice(i, i + PRICE_BATCH).map((id) => ({ address: CREDIT_STRATEGY, abi: creditStrategyAbi, functionName: "nftForSale", args: [id] }) as const),
      });
      prices.push(...r.map((x) => (x.status === "success" ? (x.result as bigint) : 0n)));
    }
    const listed = ids.flatMap((id, i) => (prices[i] > 0n ? [{ id, price: prices[i] }] : []));
    await this.scoresOf(listed.map((x) => x.id));
    this.strategy = listed.map(({ id, price }) => ({
      venue: "strategy" as const,
      adapter: this.cfg.record.strategyAdapter,
      id,
      price,
      params: "0x" as Hex,
    }));
    log("info", "strategy listings indexed", { held: ids.length, listed: this.strategy.length });
  }

  private async refreshSeaport() {
    const o = this.cfg.opensea;
    if (!o.file && !o.key) return;
    if (this.now() - this.seaportAt < o.refreshSec * 1000) return;
    this.seaportAt = this.now();
    let orders: SignedOrder[];
    try {
      if (o.file) orders = JSON.parse(readFileSync(o.file, "utf8")).orders;
      else {
        const r = await fetchListings({
          key: o.key!,
          rpc: this.cfg.rpcUrls[0],
          adapter: this.cfg.record.seaportAdapter,
          pages: o.pages,
          sign: o.sign,
          horizon: 0,
        });
        orders = r.orders;
        log("info", "opensea listings fetched", { fetched: r.fetched, fit: r.fit, signed: r.orders.length, dropped: r.dropped });
      }
    } catch (e) {
      log("warn", "opensea fetch failed, keeping the cached orders", { error: safeError(e) });
      return;
    }
    this.seaport = orders.map((x) => ({
      venue: "seaport" as const,
      adapter: this.cfg.record.seaportAdapter,
      id: BigInt(x.id),
      price: BigInt(x.price),
      params: encodeBasicOrder(x.params),
      hash: x.hash as Hex | undefined,
      offerer: getAddress(x.params.offerer),
    }));
    await this.scoresOf(this.seaport.map((w) => w.id));
  }

  // the candidates of this block: every watched listing under the bid scaled by its score, read in full
  async candidates(snap: Snapshot, blockNumber: bigint): Promise<Listing[]> {
    await Promise.all([this.refreshStrategy(), this.refreshSeaport()]);
    const ref = BigInt(snap.settings.refScore);
    const t = this.now();
    const pick = (ws: Watched[]) =>
      ws
        .filter((w) => (this.cooldown.get(`${w.venue}:${w.id}`) ?? 0) <= t)
        .map((w) => ({ w, bid: ((this.scores.get(w.id) ?? 0n) * snap.ethRate) / ref }))
        .filter((x) => x.bid >= x.w.price)
        .sort((a, b) => Number((b.bid * 10_000n) / b.w.price - (a.bid * 10_000n) / a.w.price))
        .slice(0, MAX_CANDIDATES)
        .map((x) => x.w);
    const ws = [...pick(this.strategy), ...pick(this.seaport)];
    if (ws.length === 0) return [];
    const core = this.cfg.record.core;
    // four reads per listing, typed loosely: the mixed abis exceed the compiler's instantiation depth
    const contracts: any[] = ws.flatMap((w) => [
      { address: core, abi: coreAbi, functionName: "bidOf", args: [w.id] },
      { address: w.adapter, abi: listingAdapterAbi, functionName: "price", args: [w.id, w.params] },
      { address: CREDITS, abi: creditsAbi, functionName: "ownerOf", args: [w.id] },
      w.hash
        ? { address: SEAPORT, abi: seaportAbi, functionName: "getOrderStatus", args: [w.hash] }
        : { address: core, abi: coreAbi, functionName: "allowedAdapter", args: [w.adapter] },
    ]);
    const r = (await this.client.multicall({ ...mc, blockNumber, allowFailure: true, contracts })) as { status: string; result?: unknown }[];
    return ws.map((w, i) => {
      const [bidR, quoteR, ownerR, statusR] = r.slice(i * 4, i * 4 + 4);
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
        if (statusR.status === "success") {
          const [, cancelled, filled, size] = statusR.result as readonly [boolean, boolean, bigint, bigint];
          if (cancelled) return { ...l, valid: false, why: "order cancelled" };
          if (size > 0n && filled >= size) return { ...l, valid: false, why: "order filled" };
        }
      }
      return l;
    });
  }
}
