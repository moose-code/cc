import type { View } from "./listings-api";

type Ask = { id: string; price: bigint; score: bigint };
const MAX_DISTANCE = 20n * 10_000n; // 20 rating points, in stored score units

// The keeper serves bounded observed catalogs. Deduplicate a Credit listed at both venues and exclude expired asks.
export function marketAsks(view: View, now: number, venues = { openSea: true, strategy: true }): Ask[] {
  const byId = new Map<string, Ask>();
  const add = (r: { id: string; price: string; score: string | null }) => {
    if (!r.score) return;
    const price = BigInt(r.price), score = BigInt(r.score);
    if (price <= 0n || score <= 0n) return;
    const old = byId.get(r.id);
    if (!old || price < old.price) byId.set(r.id, { id: r.id, price, score });
  };
  if (venues.openSea && view.status.source !== "off") for (const r of view.rows) if (!r.endTime || r.endTime > now) add(r);
  if (venues.strategy && view.strategy.publishedAt) for (const r of view.strategy.rows) add(r);
  return [...byId.values()];
}

// Lowest ask per rating point among displayed Credits within 20 points, scaled to this Credit's rating.
// This is an observed comparable floor, not an independently verified executable market order.
export function marketFloor(id: string, score: bigint, asks: Ask[]): bigint | undefined {
  if (score <= 0n) return undefined;
  let floor: bigint | undefined;
  for (const ask of asks) {
    if (ask.id === id) continue;
    const distance = ask.score > score ? ask.score - score : score - ask.score;
    if (distance > MAX_DISTANCE) continue;
    const adjusted = ask.price * score / ask.score;
    if (floor === undefined || adjusted < floor) floor = adjusted;
  }
  return floor;
}

export function compareMarketValue(a: { price: bigint; floor?: bigint }, b: { price: bigint; floor?: bigint }): number {
  const aMissing = !a.floor || a.price <= 0n, bMissing = !b.floor || b.price <= 0n;
  if (aMissing || bMissing) return Number(aMissing) - Number(bMissing);
  const difference = a.price * b.floor! - b.price * a.floor!;
  return difference < 0n ? -1 : difference > 0n ? 1 : 0;
}
