// Forecast of the eth bid for one credit as the price state climbs, and the time a listing price is reached.
// Pure: no chain or react imports, so scripts/selfcheck.ts runs it. Floating point mirror of CoreLib._climb
// (src/lib/CoreLib.sol:334-356), _recover (:371-386) and _climbTo (:392-396), Halving.halve, and Core.ethRate / bidOf
// (src/Core.sol:458-470). It reproduces the contract to within fixed-point rounding (about 1e-12 relative); the
// forecast is an estimate and is shown with "~".

export interface ClimbState {
  r: bigint; // Core.rateAtCheckpoint(): the stored price state
  t: number; // Core.checkpointTime()
  anchorTime: number; // Core.lastFillTime(): the idle loosening counts from here
  lastFillRate: bigint; // State.anchor.lastFillRate (storage slot 27)
  peakRate: bigint; // State.anchor.peakRate (slot 30)
  peakTime: number; // State.anchor.peakTime (slot 29, bits 64..127)
  ceilBps: number;
  idleLoosenBps: number;
  rateCap: bigint;
  peakHalfLife: number; // seconds
  climbPerMinBps: number;
  recoveryClimbPerMinBps: number;
  recoveryGapBps: number;
  ethPot: bigint; // booked pot: the climb target clamp
  pending: bigint; // unbooked income share the next book adds: widens only the final read clamp
}

const N = (x: bigint) => Number(x);
const halve = (start: number, elapsed: number, halfLife: number) => start * Math.pow(0.5, Math.max(0, elapsed) / halfLife);
const climbTo = (base: number, lnRate: number, sec: number, target: number) => Math.min(target, base * Math.exp((lnRate * sec) / 60));

/** The price state (before the pot read clamp) at chain time `now`, CoreLib._climb. */
export function priceAt(c: ClimbState, now: number): number {
  const peakNow = halve(N(c.peakRate), now - c.peakTime, c.peakHalfLife);
  const anchor = Math.max(N(c.lastFillRate), peakNow);
  const loosened = 10_000 + c.idleLoosenBps * Math.floor(Math.max(0, now - c.anchorTime) / 600);
  const cap = Math.min((anchor * loosened * c.ceilBps) / 1e8, N(c.rateCap));
  const r = N(c.r);
  if (r >= cap) return cap;
  if (now <= c.t || r === 0) return r;
  const target = Math.min(cap, N(c.ethPot));
  if (r >= target) return r;
  return recover(c, r, target, now);
}

// CoreLib._recover: fast climb below the recovery level (a fixed fraction under the decaying peak), slow at or above.
function recover(c: ClimbState, r: number, target: number, now: number): number {
  const lnFast = Math.log(1 + c.recoveryClimbPerMinBps / 10_000);
  const lnSlow = Math.log(1 + c.climbPerMinBps / 10_000);
  const levelT = (halve(N(c.peakRate), c.t - c.peakTime, c.peakHalfLife) * (10_000 - c.recoveryGapBps)) / 10_000;
  const full = now - c.t;
  if (levelT <= r) return climbTo(r, lnSlow, full, target);
  const cross = Math.log(levelT / r) / (lnFast / 60 + Math.LN2 / c.peakHalfLife);
  if (full <= cross) return climbTo(r, lnFast, full, target);
  const atCross = climbTo(r, lnFast, cross, target);
  if (atCross >= target) return target;
  return climbTo(atCross, lnSlow, full - cross, target);
}

/** Core.ethRate() at `now`: the price state read at the pot with the unbooked share. */
export const rateAt = (c: ClimbState, now: number): number => Math.min(priceAt(c, now), N(c.ethPot + c.pending));

/** Core.bidOf(id) at `now` for a credit of `score`, wei. */
export const bidAt = (c: ClimbState, now: number, score: bigint, refScore: bigint): number => Math.floor((rateAt(c, now) * N(score)) / N(refScore));

export type ClearsIn =
  | { kind: "now" } // the bid is at or above the price already
  | { kind: "in"; seconds: number }
  | { kind: "pot" } // the price needs a rate above the pot, which caps the bid
  | { kind: "cap" } // the price needs a rate above rateCap
  | { kind: "far" }; // not reached within HORIZON

export const HORIZON = 30 * 86_400;

/**
 * Seconds until the bid for a credit of `score` reaches `price`, assuming no fills (a fill lowers the rate) and a
 * constant pot. The rate is sampled on a geometric grid (step 5 percent of the elapsed time, at least a minute) and
 * the first crossing is bisected.
 */
export function clearsIn(c: ClimbState, price: bigint, score: bigint, refScore: bigint, now: number): ClearsIn {
  if (score === 0n || price <= 0n) return { kind: "far" };
  const p = N(price);
  const hit = (t: number) => bidAt(c, t, score, refScore) >= p;
  if (hit(now)) return { kind: "now" };
  const need = (p * N(refScore)) / N(score); // the rate that pays `price`
  if (need > N(c.ethPot + c.pending)) return { kind: "pot" };
  if (need > N(c.rateCap)) return { kind: "cap" };
  let lo = 0;
  let hi = 0;
  for (let s = 60; s <= HORIZON; s += Math.max(60, s * 0.05)) {
    if (hit(now + s)) {
      hi = s;
      break;
    }
    lo = s;
  }
  if (!hi) return N(c.ethPot) < need ? { kind: "pot" } : { kind: "far" };
  for (let i = 0; i < 24; i++) {
    const mid = (lo + hi) / 2;
    if (hit(now + mid)) hi = mid;
    else lo = mid;
  }
  return { kind: "in", seconds: hi };
}
