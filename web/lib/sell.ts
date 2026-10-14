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
}

// Total eth sellForEth pays for n credits sold in one call. Each credit pays
// min(price state, pot left). The fill then (CoreLib.drop) sets the minute
// anchor, lowers the state by dropPerCreditBps held at or above dropFloorBps of
// the minute's first-fill state, and raises the remembered peak to the fill
// price. The next state is bounded by the ceiling, ceilBps of max(fill price,
// peak) with no idle loosening in the same block, and by rateCap (CoreLib.climb).
export function replayEth(n: number, a: EthReplay): bigint {
  let r = a.price;
  let peak = a.peak;
  let left = a.pot;
  let start = a.start;
  let bucket = a.bucket;
  let total = 0n;
  for (let i = 0; i < n; i++) {
    const x = r < left ? r : left;
    total += x;
    left -= x;
    if (bucket !== a.nowBucket || r < (start * a.dropFloorBps) / 10000n) {
      bucket = a.nowBucket;
      start = r;
    }
    if (r > peak) peak = r;
    const dropped = (r * (10000n - a.dropPerCreditBps)) / 10000n;
    const floor = (start * a.dropFloorBps) / 10000n;
    const next = dropped > floor ? dropped : floor;
    let cap = (peak * 10000n * a.ceilBps) / 100000000n;
    if (cap > a.rateCap) cap = a.rateCap;
    r = next >= cap ? cap : next;
  }
  return total;
}

// Total balance token sellForBalance pays: each credit pays
// score * unit * (10000 - balanceBidMarginBps) / 10000.
export function replayBalance(scores: bigint[], unit: bigint, marginBps: bigint): bigint {
  return scores.reduce((t, s) => t + (s * unit * (10000n - marginBps)) / 10000n, 0n);
}
