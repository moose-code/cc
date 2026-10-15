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
    // one rounding, fall rounded up (CoreLib.drop): r * (10000*refScore - dropPerCreditBps*score) / (10000*refScore)
    const denom = 10000n * a.refScore;
    const fallNum = a.dropPerCreditBps * score;
    const dropped = fallNum >= denom ? 0n : (r * (denom - fallNum)) / denom;
    const floor = (start * a.dropFloorBps) / 10000n;
    const next = dropped > floor ? dropped : floor;
    let cap = (peak * 10000n * a.ceilBps) / 100000000n;
    if (cap > a.rateCap) cap = a.rateCap;
    r = next >= cap ? cap : next;
  }
  return total;
}

export interface BalanceReplay {
  rate: bigint; // balanceRate(): the balance bid rate now, bps of par
  unit: bigint; // the module's unitPerPoint()
  refScore: bigint;
  dropPerCreditBps: bigint;
  dropFloorBps: bigint;
  floorBps: bigint; // 10000 - balanceBidMarginBps
}

// Total balance token sellForBalance pays for the credits `scores` (in order) in one call. Each credit pays
// score * unit * rate / 10000 and the fill drops the rate per credit by dropPerCreditBps * score / refScore (one
// rounding), held at or above the minute floor and the bid floor, mirroring CoreLib._drop. The quote is the first
// fills of the minute, so the minute start is the starting rate. The available() clamp is not replayed: with ample
// available it does not bind, and a module too short to pay the floor reverts PotTooSmall, which no minOut can clear.
export function replayBalance(scores: bigint[], a: BalanceReplay): bigint {
  let r = a.rate;
  const start = a.rate;
  let total = 0n;
  for (const score of scores) {
    total += (score * a.unit * r) / 10000n;
    const denom = 10000n * a.refScore;
    const fallNum = a.dropPerCreditBps * score;
    let dropped = fallNum >= denom ? 0n : (r * (denom - fallNum)) / denom;
    const mfloor = (start * a.dropFloorBps) / 10000n;
    if (dropped < mfloor) dropped = mfloor;
    if (dropped < a.floorBps) dropped = a.floorBps;
    r = dropped;
  }
  return total;
}
