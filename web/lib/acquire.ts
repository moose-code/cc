// Listing affordability rules of Core.buyListing for the listings surfaces (owner decision 134). Pure: no chain or
// react imports, so scripts/selfcheck.ts runs it.

export type AcquireSource = "strategy" | "opensea";

export interface Listing {
  id: bigint;
  price: bigint; // wei the Core pays the venue (Core.buyListing `value`)
  source: AcquireSource;
  params: `0x${string}`; // adapter params; "0x" for the strategy adapter, and for an OpenSea listing until its fulfillment is fetched
  orderHash?: string; // OpenSea order whose fulfillment data gives `params`
  prepared?: boolean; // OpenSea fulfillment is already prepared in the keeper; absent or false cannot be acquired
}

export const preparedForAcquire = (l: Listing): boolean => l.source === "strategy" || l.prepared === true;

/** Eligible OpenSea asks in absolute ETH order, independent of the table's bid-gap order. */
export function cheapestOpenSeaEligible<T extends Listing & { clears: boolean }>(rows: T[]): T[] {
  return rows.filter((r) => r.source === "opensea" && r.clears && preparedForAcquire(r)).sort((a, b) =>
    a.price < b.price ? -1 : a.price > b.price ? 1 : a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}

export interface StrategyReadStatus { pending: boolean; publishedAt?: number; error?: string }

export interface Priced extends Listing {
  bid: bigint; // Core.bidOf(id)
}

// Empty-pot bids tie at zero. Rank those rows by exact price per point across both venues.
export function compareListingPricePerPoint(a: { price: bigint; score: bigint; id: bigint }, b: { price: bigint; score: bigint; id: bigint }): number {
  if ((a.score > 0n) !== (b.score > 0n)) return a.score > 0n ? -1 : 1;
  const left = a.price * b.score, right = b.price * a.score;
  if (left !== right) return left < right ? -1 : 1;
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
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
