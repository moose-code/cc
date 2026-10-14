// Replays of what Core.sellForEth and Core.sellForBalance pay for a batch in one
// call. Pure integer math over values read from the Core (live.ts reads them).

export interface EthReplay {
  price: bigint; // ethPrice(): the price state at the first fill
  peak: bigint; // floorRate(): max(price state, remembered peak now)
  pot: bigint; // ethPot plus the unbooked share the first book adds
  start: bigint; // anchor.minuteStartRate
  bucket: bigint; // anchor.minuteBucket
  nowBucket: bigint; // chain time / 60
  dropPerCreditBps: bigint;
  dropFloorBps: bigint;
  ceilBps: bigint;
  rateCap: bigint;
  refScore: bigint; // the Core setting the bid divides by
}

// Total eth sellForEth pays for the credits `scores` (their scores, in order)
// sold in one call. Each credit pays min(price state, pot left) * score /
// refScore (Core.bidOf). The fill then (CoreLib.drop) sets the minute anchor,
// lowers the price state by dropPerCreditBps * score / refScore (bounded at
// 10000) held at or above dropFloorBps of the minute's first-fill state, and
// raises the remembered peak to the fill price. The next state is bounded by the
// ceiling, ceilBps of max(fill price, peak) with no idle loosening in the same
// block, and by rateCap (CoreLib.climb).
export function replayEth(scores: bigint[], a: EthReplay): bigint {
  let r = a.price;
  let peak = a.peak;
  let left = a.pot;
  let start = a.start;
  let bucket = a.bucket;
  let total = 0n;
  for (const score of scores) {
    const read = r < left ? r : left;
    const x = (read * score) / a.refScore;
    total += x;
    left -= x;
    if (bucket !== a.nowBucket || r < (start * a.dropFloorBps) / 10000n) {
      bucket = a.nowBucket;
      start = r;
    }
    if (r > peak) peak = r;
    let fall = (a.dropPerCreditBps * score) / a.refScore;
    if (fall > 10000n) fall = 10000n;
    const dropped = (r * (10000n - fall)) / 10000n;
    const floor = (start * a.dropFloorBps) / 10000n;
    const next = dropped > floor ? dropped : floor;
    let cap = (peak * 10000n * a.ceilBps) / 100000000n;
    if (cap > a.rateCap) cap = a.rateCap;
    r = next >= cap ? cap : next;
  }
  return total;
}

// Total balance token sellForBalance pays: each credit pays
// the balance bid floor (opening) payout per credit: score * unit * (10000 - balanceBidMarginBps) / 10000. the
// live bid climbs above this (Core.balanceBidOf); the web reads that from the chain.
export function replayBalance(scores: bigint[], unit: bigint, marginBps: bigint): bigint {
  return scores.reduce((t, s) => t + (s * unit * (10000n - marginBps)) / 10000n, 0n);
}
