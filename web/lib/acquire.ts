// Selection of the listing the header acquire button buys (owner decision 134). Pure: no chain or react imports, so
// scripts/selfcheck.ts runs it.

export type AcquireSource = "strategy" | "opensea";

export interface Listing {
  id: bigint;
  price: bigint; // wei the Core pays the venue (Core.buyListing `value`)
  source: AcquireSource;
  params: `0x${string}`; // adapter params; "0x" for the strategy adapter, and for an OpenSea listing until its fulfillment is fetched
  orderHash?: string; // OpenSea order whose fulfillment data gives `params`
}

export interface Priced extends Listing {
  bid: bigint; // Core.bidOf(id)
}

/**
 * Listings the Core would accept: price at or below the credit's bid and at or below the pot (Core.buyListing
 * reverts AboveBid and PotTooSmall otherwise). Best first: the largest bid minus price, then the lowest price.
 * Nothing clears while the Core is retired.
 */
export function clearing(list: Priced[], pot: bigint, retired: boolean): Priced[] {
  if (retired) return [];
  return list
    .filter((l) => l.price > 0n && l.price <= l.bid && l.price <= pot)
    .sort((a, b) => {
      const ma = a.bid - a.price;
      const mb = b.bid - b.price;
      return ma === mb ? (a.price < b.price ? -1 : a.price > b.price ? 1 : 0) : ma > mb ? -1 : 1;
    });
}

/** Cheapest listing per credit id, so a credit listed on two venues is checked once at its best price. */
export function cheapestPerId(list: Listing[]): Listing[] {
  const best = new Map<bigint, Listing>();
  for (const l of list) {
    const cur = best.get(l.id);
    if (!cur || l.price < cur.price) best.set(l.id, l);
  }
  return [...best.values()];
}

/**
 * Candidates worth a live read, from all listings and a bid estimate per id. The estimate is Core.bidOf
 * (src/Core.sol:465-470): ethRate() * score / scorePer100Points with floor division, where ethRate() is
 * `price.min(ethPot + pending)` (Core.sol:458-461), held by the snapshot as `ethRate`. Ranked by estimated margin
 * (estimated bid minus price), the first `n` kept.
 */
export function shortlist(list: Listing[], ethRate: bigint, scorePer100Points: bigint, scores: Map<bigint, bigint>, n: number): Listing[] {
  if (scorePer100Points === 0n) return [];
  return cheapestPerId(list)
    .flatMap((l) => {
      const s = scores.get(l.id);
      return s == null ? [] : [{ l, margin: (ethRate * s) / scorePer100Points - l.price }];
    })
    .sort((a, b) => (a.margin === b.margin ? 0 : a.margin > b.margin ? -1 : 1))
    .slice(0, n)
    .map((x) => x.l);
}

/** `Core.spendState()` of the current bucket; `capped` is false when `spendCapBps` is 10_000 (the Core skips the check). */
export interface SpendRoom {
  capped: boolean;
  budget: bigint;
  spent: bigint;
  /** seconds until the bucket ends and `spent` resets */
  nextIn: number;
}

/**
 * Whether a purchase of `cost` (ask plus the keeper payment) passes CoreLib.spend in the current bucket: the first
 * purchase of a bucket always passes, a later one needs spent + cost <= budget.
 */
export function fitsBucket(room: SpendRoom, cost: bigint): boolean {
  return !room.capped || room.spent === 0n || room.spent + cost <= room.budget;
}

/** Purchases of `costs` (one per listing) that fit the current bucket in sequence, cheapest first. */
export function bucketCount(room: SpendRoom, costs: bigint[]): number {
  if (!room.capped) return costs.length;
  let spent = room.spent;
  let n = 0;
  for (const c of [...costs].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))) {
    if (spent !== 0n && spent + c > room.budget) break;
    spent += c;
    n++;
  }
  return n;
}
