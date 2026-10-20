// The credits market report: what the engine paid for Credits, by rating band, over the last 7 days against the 7
// before, so a listing can be read against what its band trades for. Pure functions over values the app reads.

// Rating bands in points (score / 10,000). Sized to where Credits trade: most rate 600 to 650, with tails both ways.
export interface Band {
  key: number;
  label: string; // "600–649"
  lo: number; // points, inclusive
  hi: number; // points, exclusive (Infinity for the top band)
}
export const BANDS: Band[] = [
  { key: 0, label: "under 500", lo: 0, hi: 500 },
  { key: 1, label: "500–599", lo: 500, hi: 600 },
  { key: 2, label: "600–649", lo: 600, hi: 650 },
  { key: 3, label: "650–699", lo: 650, hi: 700 },
  { key: 4, label: "700+", lo: 700, hi: Infinity },
];

export const POINT = 10_000n; // score units per rating point
export const WEEK_S = 7 * 24 * 3600;
export const BUCKET_WEI = 10n ** 14n; // 0.0001 ETH: the indexer groups prices in these, the display's last decimal
export const MIN_PRIOR = 5; // fewest prior-week sales for a change figure

export function bandOf(score: bigint): Band {
  const pts = Number(score / POINT);
  return BANDS.find((b) => pts >= b.lo && pts < b.hi) ?? BANDS[0];
}

// The median of a price histogram: count per bucket of BUCKET_WEI. The value is the bucket's midpoint; undefined
// without sales.
export function medianOfBuckets(buckets: Map<bigint, number>): bigint | undefined {
  const keys = [...buckets.keys()].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const n = keys.reduce((a, k) => a + (buckets.get(k) ?? 0), 0);
  if (n === 0) return undefined;
  const mid = (n + 1) / 2; // 1-based rank of the median
  let seen = 0;
  for (const k of keys) {
    seen += buckets.get(k) ?? 0;
    if (seen >= mid) return k * BUCKET_WEI + BUCKET_WEI / 2n;
  }
  return undefined;
}

// The exact median of prices; undefined without any.
export function medianOf(values: bigint[]): bigint | undefined {
  if (values.length === 0) return undefined;
  const v = [...values].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const m = Math.floor(v.length / 2);
  return v.length % 2 ? v[m] : (v[m - 1] + v[m]) / 2n;
}

export interface BandReport {
  band: Band;
  median?: bigint; // wei, last 7 days
  sales: number; // last 7 days
  change?: number; // percent against the 7 days before, when that week had MIN_PRIOR sales
}

// One band's figures from this week's and last week's histograms.
export function bandReport(band: Band, week: Map<bigint, number>, prior: Map<bigint, number>): BandReport {
  const sales = [...week.values()].reduce((a, n) => a + n, 0);
  const priorSales = [...prior.values()].reduce((a, n) => a + n, 0);
  const median = medianOfBuckets(week);
  const before = priorSales >= MIN_PRIOR ? medianOfBuckets(prior) : undefined;
  const change = median != null && before != null && before > 0n ? (Number(median) / Number(before) - 1) * 100 : undefined;
  return { band, median, sales, change };
}

// A price against a median, in percent ("+3%" means 3% above it).
export const vsMedian = (price: bigint, median: bigint): number => (Number(price) / Number(median) - 1) * 100;
