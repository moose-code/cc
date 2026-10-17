// Replays of what Core.sellForEth and Core.sellForBalance pay for a batch in one
// call. Pure integer math over values read from the Core (live.ts reads them).

// Five Settings words put State.anchor at slot 28 (test/CoreLayout.t.sol).
export const ETH_ANCHOR_SLOT = 28n;

// The bucket shares its word with peakTime. Keep uint64 values as bigint.
export function ethAnchorWords(start: bigint, bucketWord: bigint, now: bigint, bucketSeconds: bigint) {
  return { start, bucket: bucketWord & ((1n << 64n) - 1n), nowBucket: now / bucketSeconds };
}

export interface EthReplay {
  price: bigint; // ethPrice(): the price state at the first fill
  peak: bigint; // floorRate(): max(price state, remembered peak now)
  pot: bigint; // ethPot plus the unbooked share the first book adds, less the reserve (Core.room)
  start: bigint; // anchor.minuteStartRate
  bucket: bigint; // anchor.minuteBucket
  nowBucket: bigint; // chain time / bucketSeconds
  dropPer100PointsBps: bigint;
  dropFloorBps: bigint;
  ceilBps: bigint;
  rateCap: bigint;
  scorePer100Points: bigint; // score units in 100 points (SCORE_PER_100_POINTS; the selfchecks pass smaller values)
  buyToArtistBps: bigint; // the artist royalty on every purchase, bps of the payout, paid on top (decision 163)
}

// Total eth sellForEth pays for the credits `scores` (their scores, in order)
// sold in one call. Each credit pays min(price state, pot left) * score /
// scorePer100Points (Core.bidOf). The fill then (CoreLib.drop) sets the minute anchor,
// lowers the price state by dropPer100PointsBps * score / scorePer100Points (bounded at
// 10000) held at or above dropFloorBps of the minute's first-fill state, and
// raises the remembered peak to the fill price. The next state is bounded by the
// ceiling, ceilBps of max(fill price, peak) with no idle loosening in the same
// block, and by rateCap (CoreLib.climb).
export function replayEth(scores: bigint[], a: EthReplay): bigint {
  return replayEthFills(scores, a).reduce((t, x) => t + x, 0n);
}

// What each credit of the batch pays, in sell order; replayEth is their sum.
export function replayEthFills(scores: bigint[], a: EthReplay): bigint[] {
  let r = a.price;
  let peak = a.peak;
  let left = a.pot;
  let start = a.start;
  let bucket = a.bucket;
  const fills: bigint[] = [];
  for (const score of scores) {
    // the bid read clamps to the pot left over 1 + buyToArtistBps / 10000 (Core._bidRoom), and the pot pays the payout
    // plus its royalty, so a pot-bound quote equals what the seller receives (decision 163)
    const bidRoom = (left * 10000n) / (10000n + a.buyToArtistBps);
    const read = r < bidRoom ? r : bidRoom;
    const x = (read * score) / a.scorePer100Points;
    fills.push(x);
    left -= x + (x * a.buyToArtistBps) / 10000n;
    if (bucket !== a.nowBucket || r < (start * a.dropFloorBps) / 10000n) {
      bucket = a.nowBucket;
      start = r;
    }
    if (r > peak) peak = r;
    // one rounding, fall rounded up (CoreLib.drop): r * (10000*scorePer100Points - dropPer100PointsBps*score) / (10000*scorePer100Points)
    const denom = 10000n * a.scorePer100Points;
    const fallNum = a.dropPer100PointsBps * score;
    const dropped = fallNum >= denom ? 0n : (r * (denom - fallNum)) / denom;
    const floor = (start * a.dropFloorBps) / 10000n;
    const next = dropped > floor ? dropped : floor;
    let cap = (peak * 10000n * a.ceilBps) / 100000000n;
    if (cap > a.rateCap) cap = a.rateCap;
    r = next >= cap ? cap : next;
  }
  return fills;
}

export interface BalanceReplay {
  rate: bigint; // balanceRate(): the posted balance bid rate, 10000 - balanceDiscountBps, bps of par (decision 164)
  unit: bigint; // the module's unitPerPoint()
  scorePer100Points: bigint;
  dropPer100PointsBps: bigint; // kept for the callers' shape; the posted bid does not drop
  dropFloorBps: bigint;
  floorBps: bigint;
  // value mode clamp: the posted payout is lowered to the value rate for the score valued in tokens at the
  // protected sale price. set these three only in value mode with a usable quote; left unset the payout is par
  valueModeOn?: boolean;
  ethPrice?: bigint; // Core.ethPrice() in value mode: the value rate, wei per 100 points, before the eth pot clamp
  valueSell?: bigint; // controller.valuePerPoint(true): wei per point at the protected sale price
}

// score units in one point: the balance payout cap divides the eth bid by the sale price per token, vSell / POINT_UNIT
const POINT_UNIT = 10000n;

// Total balance token sellForBalance pays for the credits `scores` in one call: score * unit * rate / 10000 each, flat.
// The posted bid does not drop on a fill and does not climb (decision 164), so the order does not matter. The
// available() bound is not replayed: a batch whose payouts plus their artist royalties pass available() reverts
// PotTooSmall, which no minOut can clear. The artist royalty rides on top from the module and never changes the seller's
// payout (decision 163).
export function replayBalance(scores: bigint[], a: BalanceReplay): bigint {
  return replayBalanceFills(scores, a).reduce((t, x) => t + x, 0n);
}

// What each credit of the batch pays in the balance token, in sell order; replayBalance is their sum. In value mode the
// posted payout is lowered to the value rate for the score valued in tokens at the protected sale price per token
// (ControllerV1.balanceClampFor). The value rate is ethPrice, before the eth pot clamp, so the pot balance does not
// change the cap: cap = valueForScore * POINT_UNIT * unit / valueSell, valueForScore = ethPrice * score / scorePer100Points.
export function replayBalanceFills(scores: bigint[], a: BalanceReplay): bigint[] {
  return scores.map((score) => {
    const posted = (score * a.unit * a.rate) / 10000n;
    if (!a.valueModeOn || a.ethPrice === undefined || a.valueSell === undefined || a.valueSell === 0n) return posted;
    const valueForScore = (a.ethPrice * score) / a.scorePer100Points;
    const cap = (valueForScore * POINT_UNIT * a.unit) / a.valueSell;
    return posted < cap ? posted : cap;
  });
}

export interface ValueReplay {
  rate: bigint; // sharedRate(): the shared instance now, bps of par (value mode's eth price state; the balance bid is posted, decision 164)
  value: bigint; // controller.valuePerPoint(false): wei per point at the protected buy price
  pot: bigint; // ethPot plus the unbooked share the first book adds, less the reserve (Core.room)
  rateCap: bigint;
  scorePer100Points: bigint;
  dropPer100PointsBps: bigint;
  dropFloorBps: bigint;
  floorBps: bigint; // 10000 - balanceBidMarginBps
  buyToArtistBps: bigint; // the artist royalty on every purchase, bps of the payout, paid on top (decision 163)
}

// Total eth sellForEth pays in value mode (decision 148) for the credits `scores` (in order) in one call. Each credit
// pays min(rate * value * 100 / 10000, rateCap, pot left) * score / scorePer100Points (CoreLib._valueRate, Core.bidOf),
// and the fill drops the shared instance as a balance fill does (replayBalance): one rounding, held at or above the
// minute floor and the bid floor. The quote is the first fills of the minute, so the minute start is the starting rate.
export function replayValue(scores: bigint[], a: ValueReplay): bigint {
  return replayValueFills(scores, a).reduce((t, x) => t + x, 0n);
}

// What each credit of the batch pays in value mode, in sell order; replayValue is their sum.
export function replayValueFills(scores: bigint[], a: ValueReplay): bigint[] {
  let r = a.rate;
  const start = a.rate;
  let left = a.pot;
  const fills: bigint[] = [];
  for (const score of scores) {
    let rate = (r * a.value * 100n) / 10000n;
    if (rate > a.rateCap) rate = a.rateCap;
    // the bid read clamps to the pot left over 1 + buyToArtistBps / 10000 (Core._bidRoom), and the pot pays the payout
    // plus its royalty, so a pot-bound quote equals what the seller receives (decision 163)
    const bidRoom = (left * 10000n) / (10000n + a.buyToArtistBps);
    const read = rate < bidRoom ? rate : bidRoom;
    const x = (read * score) / a.scorePer100Points;
    fills.push(x);
    left -= x + (x * a.buyToArtistBps) / 10000n;
    const denom = 10000n * a.scorePer100Points;
    const fallNum = a.dropPer100PointsBps * score;
    let dropped = fallNum >= denom ? 0n : (r * (denom - fallNum)) / denom;
    const mfloor = (start * a.dropFloorBps) / 10000n;
    if (dropped < mfloor) dropped = mfloor;
    if (dropped < a.floorBps) dropped = a.floorBps;
    r = dropped;
  }
  return fills;
}
