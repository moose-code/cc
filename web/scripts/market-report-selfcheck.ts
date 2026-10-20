// Runnable check for the credits market report (web/lib/market-report.ts). No chain needed.
//   npm run check
import assert from "node:assert/strict";
import { BANDS, BUCKET_WEI, bandOf, bandReport, cheapestByBand, medianOf, medianOfBuckets, vsMedian } from "../lib/market-report.ts";

const pts = (p: number) => BigInt(p) * 10_000n;

// promise: every rating falls in exactly one band, edges belong to the band above
{
  assert.equal(bandOf(pts(0)).key, 0);
  assert.equal(bandOf(pts(499)).key, 0);
  assert.equal(bandOf(pts(500)).key, 1);
  assert.equal(bandOf(pts(649)).key, 2);
  assert.equal(bandOf(pts(650)).key, 3);
  assert.equal(bandOf(pts(700)).key, 4);
  assert.equal(bandOf(pts(5000)).key, 4);
  assert.equal(BANDS.length, 5);
}

// promise: the histogram median is the midpoint of the bucket holding the middle sale, and agrees with the exact median to one bucket
{
  const b = (k: number) => BigInt(k);
  // sales at buckets 600, 600, 610, 620, 900: middle (3rd) is 610
  const h = new Map([[b(600), 2], [b(610), 1], [b(620), 1], [b(900), 1]]);
  assert.equal(medianOfBuckets(h), 610n * BUCKET_WEI + BUCKET_WEI / 2n);
  assert.equal(medianOfBuckets(new Map()), undefined);
  const exact = medianOf([600n, 600n, 610n, 620n, 900n].map((k) => k * BUCKET_WEI + 3n));
  assert.ok(exact != null && exact / BUCKET_WEI === 610n);
  assert.equal(medianOf([1n, 3n]), 2n);
}

// promise: a change figure needs enough sales in the prior week; without them the band shows none
{
  const week = new Map([[600n, 10]]);
  assert.equal(bandReport(BANDS[2], week, new Map([[500n, 4]])).change, undefined);
  const r = bandReport(BANDS[2], week, new Map([[500n, 5]]));
  assert.equal(r.sales, 10);
  assert.ok(r.change != null && Math.abs(r.change - ((600.5 / 500.5 - 1) * 100)) < 1e-9);
  assert.equal(Math.round(vsMedian(103n, 100n)), 3);
}

// promise: the cheapest ask per band skips unscored and unpriced asks, so a band reads only real asks
{
  const m = cheapestByBand([
    { price: 50n, score: pts(610) },
    { price: 40n, score: pts(620) },
    { price: 10n, score: null },
    { price: 0n, score: pts(605) },
    { price: 70n, score: pts(720) },
  ]);
  assert.equal(m.get(2), 40n);
  assert.equal(m.get(4), 70n);
  assert.equal(m.has(0), false);
}

console.log("market report selfcheck ok");
