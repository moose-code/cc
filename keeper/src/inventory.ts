// The CreditStrategy inventory the keeper watches: the Credits it holds and the listed price of each, kept by delta.
//
// State is the held set as of `confirmed` (a block at least REORG behind the head when written) plus the last read
// price per id. A refresh reads the Credits Transfer logs to and from the strategy after `confirmed`, applies the
// ones at or below head - REORG to the confirmed set, applies the newer ones to a working copy and re-reads the price
// of every id they touch. The logs after `confirmed` are read again on the next refresh, so a reorg of the newest
// REORG blocks replaces them. Price changes emit no event, so each refresh also re-reads a rolling slice of SLICE ids,
// which covers the inventory in ceil(held / SLICE) refreshes, and a full read (`held()` plus every price) runs
// once per FULL_EVERY_SEC. The first start seeds from the indexer when one is set, else from a full read.

import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { log, safeError } from "./log.ts";

export interface Move {
  block: bigint;
  index: number;
  id: bigint;
  into: boolean; // true: the strategy received the credit, false: it sent it
}

export interface Seed {
  block: bigint; // indexed head when the ids were read
  ids: bigint[]; // active listings
}

export interface BookChain {
  head(): Promise<bigint>;
  // Transfer logs to or from the strategy in [from, to], any order
  moves(from: bigint, to: bigint): Promise<Move[]>;
  held(): Promise<bigint[]>;
  // nftForSale per id; undefined for a failed read
  prices(ids: bigint[]): Promise<(bigint | undefined)[]>;
  seed?(): Promise<Seed | undefined>;
}

export interface BookOptions {
  file?: string;
  key: string; // chain id and strategy address; a state file under another key is discarded
  reorg?: bigint;
  slice?: number;
  fullEverySec?: number;
  fullRead?: boolean; // every refresh is a full read
  now?: () => number;
}

const cmp = (a: bigint, b: bigint) => (a < b ? -1 : a > b ? 1 : 0);

// last move of an id wins; `moves` ascend by (block, index)
function apply(held: Set<bigint>, moves: Move[]) {
  for (const m of moves) {
    if (m.into) held.add(m.id);
    else held.delete(m.id);
  }
}

export class StrategyBook {
  private held = new Set<bigint>();
  private prices = new Map<bigint, bigint>();
  private confirmed = 0n;
  private fullAt = 0;
  private cursor = 0;
  private ready = false;
  private loaded = false;
  private chain: BookChain;
  private o: Required<Omit<BookOptions, "file">> & { file?: string };

  constructor(chain: BookChain, o: BookOptions) {
    this.chain = chain;
    this.o = { reorg: 12n, slice: 300, fullEverySec: 86_400, fullRead: false, now: Date.now, ...o };
  }

  /** The listed credits (price above zero) after this refresh. */
  async refresh(): Promise<Map<bigint, bigint>> {
    if (!this.loaded) this.load();
    const head = await this.chain.head();
    const due = this.o.now() - this.fullAt >= this.o.fullEverySec * 1000;
    if (this.ready && !this.o.fullRead && !due) {
      try {
        return await this.delta(head);
      } catch (e) {
        log("warn", "strategy delta failed, reading the inventory in full", { error: safeError(e) });
      }
    } else if (!this.ready && !this.o.fullRead && this.chain.seed) {
      try {
        const s = await this.chain.seed();
        if (s) {
          this.held = new Set(s.ids);
          this.prices = new Map();
          this.confirmed = s.block > this.o.reorg ? s.block - this.o.reorg : 0n;
          this.ready = true;
          this.fullAt = this.o.now();
          log("info", "strategy inventory seeded from the indexer", { listed: s.ids.length, block: s.block });
          return await this.delta(head);
        }
      } catch (e) {
        this.ready = false;
        log("warn", "indexer seed failed, reading the inventory in full", { error: safeError(e) });
      }
    }
    return this.full(head);
  }

  private async full(head: bigint) {
    const ids = await this.chain.held();
    const read = await this.chain.prices(ids);
    const old = this.prices;
    this.prices = new Map(ids.map((id, i) => [id, read[i] ?? old.get(id) ?? 0n]));
    this.held = new Set(ids);
    this.confirmed = head > this.o.reorg ? head - this.o.reorg : 0n;
    this.fullAt = this.o.now();
    this.cursor = 0;
    this.ready = true;
    this.save();
    return this.listed(this.held);
  }

  private async delta(head: bigint) {
    const from = this.confirmed + 1n;
    const moves = from <= head ? await this.chain.moves(from, head) : [];
    moves.sort((a, b) => cmp(a.block, b.block) || a.index - b.index);
    const cut = head > this.o.reorg ? head - this.o.reorg : 0n;
    apply(this.held, moves.filter((m) => m.block <= cut));
    if (cut > this.confirmed) this.confirmed = cut;
    const tail = moves.filter((m) => m.block > cut);
    const work = new Set(this.held);
    apply(work, tail);

    // ids to price: new to the book, moved since `confirmed`, and the rolling slice
    const want = new Set<bigint>();
    for (const id of work) if (!this.prices.has(id)) want.add(id);
    for (const m of moves) if (work.has(m.id)) want.add(m.id);
    const ring = [...work].sort(cmp);
    if (ring.length) {
      const start = this.cursor % ring.length;
      for (let i = 0; i < Math.min(this.o.slice, ring.length); i++) want.add(ring[(start + i) % ring.length]);
      this.cursor = (start + this.o.slice) % ring.length;
    }
    const ids = [...want];
    const read = await this.chain.prices(ids);
    ids.forEach((id, i) => {
      const p = read[i];
      if (p !== undefined) this.prices.set(id, p);
      else if (!this.prices.has(id)) this.prices.set(id, 0n);
    });
    for (const id of this.prices.keys()) if (!work.has(id) && !this.held.has(id)) this.prices.delete(id);
    this.save();
    return this.listed(work);
  }

  private listed(ids: Set<bigint>) {
    const out = new Map<bigint, bigint>();
    for (const id of ids) {
      const p = this.prices.get(id);
      if (p && p > 0n) out.set(id, p);
    }
    return out;
  }

  private load() {
    this.loaded = true;
    if (!this.o.file) return;
    try {
      const j = JSON.parse(readFileSync(this.o.file, "utf8"));
      if (j.version !== 1 || j.key !== this.o.key) return;
      this.confirmed = BigInt(j.confirmed);
      this.fullAt = Number(j.fullAt);
      this.cursor = Number(j.cursor);
      this.held = new Set((j.held as string[]).map(BigInt));
      this.prices = new Map((j.prices as [string, string][]).map(([id, p]) => [BigInt(id), BigInt(p)]));
      this.ready = true;
    } catch {
      /* the first start reads in full */
    }
  }

  private save() {
    if (!this.o.file) return;
    try {
      mkdirSync(dirname(this.o.file), { recursive: true });
      const tmp = `${this.o.file}.tmp`;
      writeFileSync(
        tmp,
        JSON.stringify({
          version: 1,
          key: this.o.key,
          confirmed: this.confirmed.toString(),
          fullAt: this.fullAt,
          cursor: this.cursor,
          held: [...this.held].map(String),
          prices: [...this.prices].filter(([id]) => this.held.has(id)).map(([id, p]) => [id.toString(), p.toString()]),
        }),
      );
      renameSync(tmp, this.o.file);
    } catch (e) {
      log("warn", "strategy inventory not saved", { error: safeError(e) });
    }
  }
}

/**
 * Active strategy listings from the indexer's GraphQL endpoint (indexer/ponder.schema.ts `strategy_listing`) and the
 * block the indexer had reached before the first page. Pages are read at 1000 rows. A failure rejects.
 */
export async function indexerSeed(url: string, fetchFn: typeof fetch = fetch): Promise<Seed> {
  const q = `query($after: String) { _meta { status } strategyListings(where: { active: true }, orderBy: "id", orderDirection: "asc", limit: 1000, after: $after) { items { id } pageInfo { hasNextPage endCursor } } }`;
  const ids: bigint[] = [];
  let block = 0n;
  let after: string | null = null;
  for (let page = 0; page < 100; page++) {
    const res = await fetchFn(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: q, variables: { after } }),
      signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) throw new Error(`indexer status ${res.status}`);
    const body = (await res.json()) as {
      data?: {
        _meta: { status: { [chain: string]: { block: { number: number } } } };
        strategyListings: { items: { id: string }[]; pageInfo: { hasNextPage: boolean; endCursor: string | null } };
      };
    };
    if (!body.data) throw new Error("indexer query failed");
    if (page === 0) block = BigInt(Math.max(0, ...Object.values(body.data._meta.status).map((c) => c.block.number)));
    const l = body.data.strategyListings;
    for (const it of l.items) ids.push(BigInt(it.id));
    if (!l.pageInfo.hasNextPage) return { block, ids };
    after = l.pageInfo.endCursor;
  }
  throw new Error("indexer listings exceed the page bound");
}
