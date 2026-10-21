// The keeper's decisions: pure functions of the chain state read at one block, the candidate listings and the gas
// state. Every gate restates a Core rule (src/Core.sol) so a call that would revert or pay less than its own cost is
// never simulated, and the simulation stays the final check. Payments are evaluated at the worst base fee the
// transaction can land at, `min(baseFee * 9 / 8, door maxBaseFee)`: the gas refund of a paid door tracks the base fee
// up to its setting's ceiling, so the worst case is the highest base fee.

import { zeroAddress, type Address, type Hex } from "viem";
import type { Door, DoorPolicy, SplitConfig } from "./config.ts";

// the private gas constants of the Core (src/Core.sol 224 to 236), restated
export const COMPOSE_GAS = 13_700_000n;
// the most gas the Core's refreshReference door counts for the caller payment (Core.REFRESH_GAS)
export const REFRESH_GAS = 200_000n;
export const REDEEM_GAS = 1_500_000n;
export const BUYBACK_GAS = 600_000n;
export const BUYLISTING_GAS = 1_500_000n;

// gas guesses used before a simulation measures the call (docs/INTEGRATION.md section 12, rounded up)
export const GAS_GUESS: { [d in Door]: bigint } = {
  buyListing: 520_000n,
  buyback: 300_000n,
  compose: 9_000_000n,
  collectEscrow: 120_000n,
  book: 100_000n,
  redeemStatement: 1_500_000n,
  refreshReference: 60_000n,
  // a Splits v2 push distribute to two recipients: the hash check, the incentive and two transfers (ETH or ERC20),
  // each with a warehouse deposit fallback. a guess until the simulation measures it
  distributeSplit: 150_000n,
  // StandingBidPolicy.refreshReference: two pool manager reads and the sample, block and reference writes. a guess until
  // the simulation measures it
  refreshBidReference: 120_000n,
};

// the VERSION() answer of the standing bid policy the refreshBidReference door refreshes (src/adapters/StandingBidPolicy.sol)
export const STANDING_BID_VERSION = "standing-bid-v1";

export interface Settings {
  buybackSlice: bigint;
  buybackDelay: number;
  keeperFee: bigint;
  keeperMaxBaseFee: bigint;
  callerFee: bigint;
  callerMaxBaseFee: bigint;
  redeemOn: boolean;
  // the ETH purchase budget: spendCapBps 10,000 disables it; a bucket lasts bucketSeconds
  spendCapBps: number;
  bucketSeconds: number;
  // the artist royalty on every purchase, bps of the price, paid on top from the pot (decision 163)
  buyToArtistBps: number;
}

// the state the decisions read, all from one block
export interface State {
  core: Address;
  blockNumber: bigint;
  timestamp: bigint;
  baseFee: bigint;
  settings: Settings;
  // Core.spendState() at the block: the bucket id, its budget and the wei spent in it
  spend: { bucket: bigint; budget: bigint; spent: bigint };
  ethPot: bigint;
  // ethPot plus the pot share of the unbooked income that the door's own `_book` adds first
  potWithPending: bigint;
  // Core.reserve(): the eth the pot keeps for processing. the caller payments still pay from the whole pot
  reserve: bigint;
  // potWithPending less the reserve: the most a buyListing may spend (the clamp of Core.ethRate after the book)
  potRoom: bigint;
  pendingIncome: bigint;
  // timestamp of the last book the keeper sent, 0 until it sends one
  lastBookAt: bigint;
  ethToBuyback: bigint;
  payeeOn: boolean;
  paused: boolean;
  retired: boolean;
  lastBuybackBlock: bigint;
  sniperSeconds: bigint;
  // DeploymentInfoV2.launchedAt of the coin, 0 while the launch is not recorded
  launchedAt: bigint;
  escrowBalance: bigint;
  pageReady: boolean;
  balanceModule: Address;
  // the phase 2 treasury's conversionReady() (IPhase2BalanceTreasury.sol): the conversion switch, the selection,
  // the finalized upstream retirement and the registered renderer, all of which Core.redeemStatement needs before the
  // module's redeem can succeed. undefined when the module has no such view (StatementBalanceModule), which reads
  // as ready so that path is unchanged
  conversionReady?: boolean;
  // ControllerV2.statementRedeemDelaySeconds(): the age a statement needs before atFloor(sid) is true. logged only;
  // atFloor stays the decision. undefined on a controller without the view (V1)
  statementRedeemDelaySeconds?: number;
  // the held statements with controller.atFloor(sid) true
  atFloor: bigint[];
  // the value switch: the controller, the Core's valueModeOn, whether the protected value quote is unusable now,
  // the controller reference, quote controls, and the spot read at the pinned block. An unusable quote makes the Core
  // ETH bid zero. A refresh pays only when the controller
  // sees a nonzero spot and a nonzero integer move at inclusion
  controller: Address;
  valueModeOn: boolean;
  noQuote: boolean;
  referencePrice: bigint;
  referenceTime: bigint;
  referenceMaxStale: bigint;
  referenceMinSeconds: bigint;
  referenceRateBpsPerHour: bigint;
  referenceStepBps: bigint;
  spot: bigint;
  // Core.balanceToken() at the block: the token of the split's BALANCE leg, zero while no module is bound
  balanceToken: Address;
  // the split's ETH and balance token holdings at the block, read only while the distributeSplit door is configured;
  // undefined when not read or when the read failed, which skips the leg with a reason
  splitEth?: bigint;
  splitBalance?: bigint;
  // the phase 2 treasury's standing bid (decision 258), read tolerant: the treasury's redemptionPolicy() (undefined
  // while no module is bound, the treasury has no such view or names no policy), that policy's VERSION() (undefined
  // when it has none), its refreshDue() (undefined when it does not answer), the treasury's ccRedemptionEnabled() and
  // bidBudgetAvailable() (undefined on a treasury built before the budget)
  bidPolicy?: Address;
  bidPolicyVersion?: string;
  bidRefreshDue?: boolean;
  ccRedemptionEnabled?: boolean;
  bidBudgetAvailable?: bigint;
}

export interface Listing {
  venue: "seaport" | "strategy";
  adapter: Address;
  id: bigint;
  // the `value` the adapter quotes, what the Core pays the venue
  price: bigint;
  // core.bidOf(id) at the state's block
  bid: bigint;
  params: Hex;
  // false when the order is cancelled, filled, or its offerer no longer holds the credit
  valid: boolean;
  why?: string;
}

export interface Gas {
  baseFee: bigint;
}

export interface Intended {
  door: Door;
  functionName: "buyListing" | "buyback" | "compose" | "collectEscrow" | "book" | "redeemStatement" | "refreshReference" | "distribute";
  // the contract the call goes to: the Core by default (every Core door, including the refreshReference door that
  // forwards to the controller); "split" is the artist and operator split of the distributeSplit door; "bidPolicy" is
  // the treasury's standing bid policy of the refreshBidReference door
  target?: "controller" | "split" | "bidPolicy";
  args: readonly unknown[];
  // the gas the decision assumed; the executor replaces it with the simulation's measure and calls `recheck`
  gas: bigint;
  // the payment the Core sends at `gas`, at the worst base fee
  payment: bigint;
  cost: bigint;
  key: string;
  note?: { [k: string]: unknown };
}

export interface Skip {
  door: Door;
  reason: string;
  key?: string;
}

export interface Policy {
  doors: { [d in Door]: DoorPolicy };
  doorsOn: Set<Door>;
  margin: bigint;
  listingDelaySec: number;
  // a latched Core is booked when the pending income exceeds bookMinWei and the keeper's last book is older than bookMinSec
  bookMinWei: bigint;
  bookMinSec: number;
  // the distributeSplit door's split and the distributor the call names (the keeper address); undefined leaves the door off
  split?: SplitPolicy;
  // BID_REFRESH_ALWAYS: the refreshBidReference door runs while the treasury's CC redemption is off
  bidRefreshAlways?: boolean;
}

export interface SplitPolicy extends SplitConfig {
  distributor: Address;
}

const min = (...v: bigint[]) => v.reduce((a, b) => (b < a ? b : a));

// the base fee the transaction is priced at: the next block's base fee rises at most 1/8, and the transaction is never
// included above the door's ceiling (maxFeePerGas = maxBaseFee + tip)
export function worstBaseFee(gas: Gas, p: DoorPolicy): bigint {
  return min((gas.baseFee * 9n + 7n) / 8n, p.maxBaseFee);
}

// the keeper's own cost of a call: its gas at the worst base fee plus its tip
export function ownCost(gasUsed: bigint, gas: Gas, p: DoorPolicy): bigint {
  return gasUsed * (worstBaseFee(gas, p) + p.tip);
}

// the profit rule of every paid door: Core payment >= own gas x (base fee + tip) + margin
export function profitable(payment: bigint, cost: bigint, margin: bigint): boolean {
  return payment >= cost + margin;
}

// Core.buyListing: min(min(counted, BUYLISTING_GAS) * min(basefee, keeperMaxBaseFee) + keeperFee, bid - price,
// room - price - royalty), where the room is the pot read after the door's book less the reserve (Core.room) and the
// royalty is buyToArtistBps of the price, paid to the artist on top (decision 163). a listing whose price plus
// royalty passes the room reverts PotTooSmall
export function listingPayment(s: State, l: Listing, gasUsed: bigint, b: bigint): bigint {
  const royalty = (l.price * BigInt(s.settings.buyToArtistBps)) / 10_000n;
  if (l.price > l.bid || l.price + royalty > s.potRoom) return 0n;
  const refund = min(gasUsed, BUYLISTING_GAS) * min(b, s.settings.keeperMaxBaseFee) + s.settings.keeperFee;
  return min(refund, l.bid - l.price, s.potRoom - l.price - royalty);
}

// Core.buyback guards and payment at base fee `b`. the swap budget is `slice - maxPay`; the fee is scaled by the eth
// spent over `buybackSlice - maxPay`, with spent taken as the whole budget (an exact in swap without a price limit)
export function buybackQuote(s: State, nextBlock: bigint, gasUsed: bigint, b: bigint) {
  const cfg = s.settings;
  if (s.ethToBuyback === 0n) return { ok: false as const, reason: "NothingToBuy: ethToBuyback is 0" };
  const open = s.lastBuybackBlock + BigInt(cfg.buybackDelay);
  if (nextBlock < open) return { ok: false as const, reason: `TooSoon: open at block ${open}` };
  const slice = min(s.ethToBuyback, cfg.buybackSlice);
  const rate = min(b, cfg.keeperMaxBaseFee);
  const maxPay = BUYBACK_GAS * rate + cfg.keeperFee;
  if (slice < 2n * maxPay) return { ok: false as const, reason: `SliceTooSmall: slice ${slice} under 2 * maxPay ${maxPay}` };
  const spent = slice - maxPay;
  const fee = min(cfg.keeperFee, (cfg.keeperFee * spent) / (cfg.buybackSlice - maxPay));
  const payment = min(gasUsed, BUYBACK_GAS) * rate + fee;
  return { ok: true as const, slice, maxPay, payment };
}

// Core._payCaller for compose and redeemStatement: nothing when both caller settings are 0, else
// min(counted, cap) * min(basefee, callerMaxBaseFee) + callerFee, at most ethPot
export function callerPayment(s: State, gasUsed: bigint, cap: bigint, b: bigint): bigint {
  const cfg = s.settings;
  if (cfg.callerFee === 0n && cfg.callerMaxBaseFee === 0n) return 0n;
  return min(min(gasUsed, cap) * min(b, cfg.callerMaxBaseFee) + cfg.callerFee, s.potWithPending);
}

// Core.spend: the first purchase of a bucket always passes; a later one reverts SpendCapReached when the bucket's spent
// total plus its cost (price plus keeper payment) exceeds the budget. returns the time the next bucket starts when blocked
export function spendBlocked(s: State, cost: bigint): bigint | undefined {
  const { budget, spent, bucket } = s.spend;
  if (s.settings.spendCapBps === 10_000 || spent === 0n || spent + cost <= budget) return undefined;
  return (bucket + 1n) * BigInt(s.settings.bucketSeconds);
}

// whether a book now latches the payee share: Core._book returns before the latch when the income is 0, and the latch
// needs block.timestamp >= launchedAt + settings.sniperSeconds
export function bookLatches(s: State): { ok: boolean; reason: string } {
  if (s.payeeOn) return { ok: false, reason: "payee share already latched" };
  if (s.launchedAt === 0n) return { ok: false, reason: "launch not recorded by the factory" };
  const end = s.launchedAt + s.sniperSeconds;
  if (s.timestamp < end) return { ok: false, reason: `anti sniper window ends at ${end}` };
  if (s.pendingIncome === 0n) return { ok: false, reason: "no unbooked income, a book would not latch" };
  return { ok: true, reason: "window over, income pending, payee share not latched" };
}

// whether a book now moves pending income into the booked pots once the payee share is latched: the income exceeds
// `bookMinWei` and the keeper's last book is more than `bookMinSec` old
export function bookFollowsIncome(s: State, p: Pick<Policy, "bookMinWei" | "bookMinSec">): { ok: boolean; reason: string } {
  if (s.pendingIncome <= p.bookMinWei) return { ok: false, reason: `pending income ${s.pendingIncome} not above ${p.bookMinWei}` };
  if (s.timestamp - s.lastBookAt <= BigInt(p.bookMinSec)) return { ok: false, reason: `last book under ${p.bookMinSec} seconds ago` };
  return { ok: true, reason: "income pending above the book minimum" };
}

export const listingKey = (l: Pick<Listing, "venue" | "id" | "price">) => `${l.venue}:${l.id}:${l.price}`;

// the first time each listing key was seen sweepable: kept for keys still sweepable, set to `now` for new ones,
// dropped for the rest, so a listing that leaves the sweepable set restarts its delay
export function observe(seen: ReadonlyMap<string, bigint>, sweepable: string[], now: bigint): Map<string, bigint> {
  const next = new Map<string, bigint>();
  for (const k of sweepable) next.set(k, seen.get(k) ?? now);
  return next;
}

// whether a reference refresh is due: the controller holds a reference (the pool key is set), the reference can be
// usable (referenceMaxStale nonzero), and referenceMinSeconds has passed since the last sample. the contract gates the
// refresh at referenceMinSeconds, so a call before then does nothing. A low rate can take several cadences before
// integer division gives a nonzero move; the controller leaves referenceTime unchanged while it waits
export function refreshReferenceDue(s: State): { ok: boolean; reason: string } {
  if (s.referencePrice === 0n) return { ok: false, reason: "no reference: the balance pool key is not set" };
  if (s.referenceMaxStale === 0n) return { ok: false, reason: "referenceMaxStale is 0, the reference is never usable" };
  if (s.spot === 0n) return { ok: false, reason: "pool spot is unavailable" };
  const due = s.referenceTime + s.referenceMinSeconds;
  if (s.timestamp < due) return { ok: false, reason: `reference sampled at ${s.referenceTime}, next refresh at ${due}` };
  const move = (s.referenceRateBpsPerHour * (s.timestamp - s.referenceTime)) / 3_600n;
  if (move === 0n || s.referenceStepBps === 0n) return { ok: false, reason: "reference move rounds to zero" };
  return { ok: true, reason: "referenceMinSeconds since the last sample" };
}

// whether a refresh of the standing bid policy's CC reference is due: the treasury names a policy that answers VERSION()
// with the standing bid version, CC redemption is on (nothing prices while it is off) unless BID_REFRESH_ALWAYS, and the
// policy's refreshDue() is true (one refresh per block, referenceMinSeconds since the last sample, the mode on, a priced
// spot, a nonzero move). the policy's own gates are read through refreshDue rather than restated: a refresh that would
// not move the reference returns false without reverting, so the simulation cannot catch it
export function refreshBidReferenceDue(s: State, p: Pick<Policy, "bidRefreshAlways">): { ok: boolean; reason: string } {
  if (/^0x0{40}$/i.test(s.balanceModule)) return { ok: false, reason: "no balance module bound" };
  if (!s.bidPolicy) return { ok: false, reason: "no redemption policy: the treasury names none or has no such view" };
  if (s.bidPolicyVersion !== STANDING_BID_VERSION) {
    return { ok: false, reason: `redemption policy ${s.bidPolicy} answers VERSION ${s.bidPolicyVersion === undefined ? "nothing" : JSON.stringify(s.bidPolicyVersion)}, not ${STANDING_BID_VERSION}` };
  }
  if (!p.bidRefreshAlways && s.ccRedemptionEnabled !== true) {
    return { ok: false, reason: s.ccRedemptionEnabled === false ? "RedemptionOff: ccRedemptionEnabled is off, nothing prices (BID_REFRESH_ALWAYS=1 refreshes anyway)" : "ccRedemptionEnabled not read" };
  }
  if (s.bidRefreshDue === undefined) return { ok: false, reason: "refreshDue not read" };
  if (!s.bidRefreshDue) return { ok: false, reason: "the policy reports no refresh due: the block gate, referenceMinSeconds, the mode, the spot or a zero move" };
  return { ok: true, reason: "the policy reports a refresh due" };
}

// the legs of the artist and operator split that are due: ETH when the split holds at least minEth, the balance token
// when the BALANCE leg is on (minBalance set), the Core has a balance token and the split holds at least minBalance.
// a leg whose balance was not read is skipped with its reason rather than guessed
export function splitLegs(s: State, split: SplitConfig): { due: { token: Address; amount: bigint; leg: "eth" | "balance" }[]; skips: string[] } {
  const due: { token: Address; amount: bigint; leg: "eth" | "balance" }[] = [];
  const skips: string[] = [];
  if (s.splitEth === undefined) skips.push("split ETH balance not read");
  else if (s.splitEth < split.minEth) skips.push(`split ETH ${s.splitEth} under SPLIT_MIN_ETH ${split.minEth}`);
  else due.push({ token: zeroAddress, amount: s.splitEth, leg: "eth" });
  if (split.minBalance !== undefined) {
    if (s.balanceToken === zeroAddress) skips.push("no balance token bound, the BALANCE leg waits");
    else if (s.splitBalance === undefined) skips.push("split BALANCE balance not read");
    else if (s.splitBalance < split.minBalance) skips.push(`split BALANCE ${s.splitBalance} under SPLIT_MIN_BALANCE ${split.minBalance}`);
    else due.push({ token: s.balanceToken, amount: s.splitBalance, leg: "balance" });
  }
  return { due, skips };
}

// every call the keeper would make at this state, in priority order: buyListing (best gap first), buyback, compose,
// collectEscrow, book, redeemStatement, refreshReference, distributeSplit, refreshBidReference. returns the updated
// listing observation map
export function decide(
  s: State,
  listings: Listing[],
  gas: Gas,
  p: Policy,
  seen: ReadonlyMap<string, bigint>,
): { calls: Intended[]; skips: Skip[]; seen: Map<string, bigint> } {
  const calls: Intended[] = [];
  const skips: Skip[] = [];
  const blockedByPause = (d: Door) => d === "buyListing" || d === "buyback" || d === "compose";
  const on = (d: Door) => p.doorsOn.has(d) && !(s.paused && blockedByPause(d));
  // A pause stops acquisitions, composition and buybacks. Bookkeeping, escrow collection, reference refresh and
  // redemption remain callable by the Core, so the keeper can continue those jobs.
  if (s.paused) {
    for (const d of p.doorsOn) if (blockedByPause(d)) skips.push({ door: d, reason: "Paused: the Core is paused" });
  }
  const ceiling = (d: Door) => {
    if (gas.baseFee > p.doors[d].maxBaseFee) {
      skips.push({ door: d, reason: `base fee ${gas.baseFee} above the door ceiling ${p.doors[d].maxBaseFee}` });
      return false;
    }
    return true;
  };

  // 1. buyListing
  const sweepable: { l: Listing; key: string; payment: bigint; cost: bigint }[] = [];
  // `noQuote` reports an unusable protected quote; the pinned Core bid for each listing is zero then, so a sweep
  // cannot pass the listing's price check. The quote flag itself is informational here.
  if (on("buyListing") && !s.retired && s.potRoom === 0n) {
    skips.push({ door: "buyListing", reason: `ReserveHeld: the pot ${s.potWithPending} is at or under the reserve ${s.reserve}, acquisitions wait for fees` });
  } else if (on("buyListing") && !s.retired && ceiling("buyListing")) {
    const pol = p.doors.buyListing;
    const b = worstBaseFee(gas, pol);
    for (const l of listings) {
      const key = listingKey(l);
      if (!l.valid) {
        skips.push({ door: "buyListing", key, reason: l.why ?? "order not fillable" });
        continue;
      }
      if (l.price > l.bid) continue;
      // the pot pays the price plus its artist royalty, so the room bounds price + royalty (Core.buyListing, decision 163)
      const royalty = (l.price * BigInt(s.settings.buyToArtistBps)) / 10_000n;
      if (l.price + royalty > s.potRoom) {
        skips.push({ door: "buyListing", key, reason: "PotTooSmall: price plus its artist royalty above ethPot less the reserve" });
        continue;
      }
      const payment = listingPayment(s, l, GAS_GUESS.buyListing, b);
      const cost = ownCost(GAS_GUESS.buyListing, gas, pol);
      if (!profitable(payment, cost, p.margin)) {
        skips.push({ door: "buyListing", key, reason: `unprofitable: payment ${payment} under cost ${cost} plus margin` });
        continue;
      }
      const waitUntil = spendBlocked(s, l.price + royalty + payment);
      if (waitUntil !== undefined) {
        skips.push({ door: "buyListing", key, reason: `SpendCapReached: bucket budget ${s.spend.budget} has ${s.spend.spent} spent, next bucket at ${waitUntil}` });
        continue;
      }
      sweepable.push({ l, key, payment, cost });
    }
  }
  const nextSeen = observe(seen, sweepable.map((x) => x.key), s.timestamp);
  sweepable
    .sort((x, y) => (y.l.bid - y.l.price > x.l.bid - x.l.price ? 1 : y.l.bid - y.l.price < x.l.bid - x.l.price ? -1 : 0))
    .forEach(({ l, key, payment, cost }) => {
      const age = s.timestamp - nextSeen.get(key)!;
      if (age < BigInt(p.listingDelaySec)) {
        skips.push({ door: "buyListing", key, reason: `listing seen ${age} s ago, delay ${p.listingDelaySec} s` });
        return;
      }
      calls.push({
        door: "buyListing",
        functionName: "buyListing",
        args: [l.adapter, l.id, l.params],
        gas: GAS_GUESS.buyListing,
        payment,
        cost,
        key,
        note: { venue: l.venue, id: l.id, price: l.price, bid: l.bid, gap: l.bid - l.price, ageSec: age },
      });
    });

  // 2. buyback
  if (on("buyback") && ceiling("buyback")) {
    const pol = p.doors.buyback;
    const q = buybackQuote(s, s.blockNumber + 1n, GAS_GUESS.buyback, worstBaseFee(gas, pol));
    if (!q.ok) skips.push({ door: "buyback", reason: q.reason });
    else {
      const cost = ownCost(GAS_GUESS.buyback, gas, pol);
      if (!profitable(q.payment, cost, p.margin)) skips.push({ door: "buyback", reason: `unprofitable: payment ${q.payment} under cost ${cost} plus margin` });
      else calls.push({ door: "buyback", functionName: "buyback", args: [], gas: GAS_GUESS.buyback, payment: q.payment, cost, key: "buyback", note: { slice: q.slice, maxPay: q.maxPay } });
    }
  }

  // 3. compose
  if (on("compose") && !s.pageReady) skips.push({ door: "compose", reason: "NotReady: nextPage not ready" });
  else if (on("compose") && !s.retired && ceiling("compose")) {
    const pol = p.doors.compose;
    const payment = callerPayment(s, GAS_GUESS.compose, COMPOSE_GAS, worstBaseFee(gas, pol));
    const cost = ownCost(GAS_GUESS.compose, gas, pol);
    if (!profitable(payment, cost, p.margin)) skips.push({ door: "compose", reason: `unprofitable: payment ${payment} under cost ${cost} plus margin` });
    else calls.push({ door: "compose", functionName: "compose", args: [], gas: GAS_GUESS.compose, payment, cost, key: "compose" });
  }

  // 4. collectEscrow: unpaid; books the escrow credit (a partial buyback fill refund) into the pot when it is worth
  // at least the gas that moves it
  if (on("collectEscrow") && s.escrowBalance > 0n && ceiling("collectEscrow")) {
    const cost = ownCost(GAS_GUESS.collectEscrow, gas, p.doors.collectEscrow);
    if (s.escrowBalance < cost) skips.push({ door: "collectEscrow", reason: `escrow ${s.escrowBalance} under the gas cost ${cost}` });
    else calls.push({ door: "collectEscrow", functionName: "collectEscrow", args: [], gas: GAS_GUESS.collectEscrow, payment: 0n, cost, key: "collectEscrow", note: { escrow: s.escrowBalance } });
  }

  // 5. book: unpaid; the book that latches the payee share, then the book that follows pending income once latched
  if (on("book")) {
    const r = s.payeeOn ? bookFollowsIncome(s, p) : bookLatches(s);
    if (!r.ok) skips.push({ door: "book", reason: r.reason });
    else if (ceiling("book")) {
      const cost = ownCost(GAS_GUESS.book, gas, p.doors.book);
      calls.push({ door: "book", functionName: "book", args: [], gas: GAS_GUESS.book, payment: 0n, cost, key: "book", note: { income: s.pendingIncome } });
    }
  }

  // 6. redeemStatement: reverts NoBalanceModule until a module is set, so it is skipped (one log per tick, no simulation)
  // until then. A phase 2 treasury whose conversionReady() is false reverts ConversionOff (or the upstream token refuses
  // the withdrawal), so the door is skipped until the treasury reports ready; a module without the view is treated as ready
  if (on("redeemStatement") && s.atFloor.length > 0) {
    const pol = p.doors.redeemStatement;
    if (/^0x0{40}$/i.test(s.balanceModule)) skips.push({ door: "redeemStatement", reason: "no balance module bound" });
    else if (!s.settings.redeemOn) skips.push({ door: "redeemStatement", reason: "RedeemOff" });
    else if (s.conversionReady === false) skips.push({ door: "redeemStatement", reason: "conversion not ready" });
    else if (ceiling("redeemStatement")) {
      for (const sid of s.atFloor) {
        const payment = callerPayment(s, GAS_GUESS.redeemStatement, REDEEM_GAS, worstBaseFee(gas, pol));
        const cost = ownCost(GAS_GUESS.redeemStatement, gas, pol);
        const key = `redeem:${sid}`;
        if (!profitable(payment, cost, p.margin)) {
          skips.push({ door: "redeemStatement", key, reason: `unprofitable: payment ${payment} under cost ${cost} plus margin` });
        } else {
          calls.push({ door: "redeemStatement", functionName: "redeemStatement", args: [sid], gas: GAS_GUESS.redeemStatement, payment, cost, key, note: { sid } });
        }
      }
    }
  }

  // 7. refreshReference: the Core door forwards to the controller and pays the caller like compose when a refresh runs,
  // so the keeper keeps the reference tracking the market. paid, profit gated
  if (on("refreshReference")) {
    const r = refreshReferenceDue(s);
    if (!r.ok) skips.push({ door: "refreshReference", reason: r.reason });
    else if (ceiling("refreshReference")) {
      const pol = p.doors.refreshReference;
      const payment = callerPayment(s, GAS_GUESS.refreshReference, REFRESH_GAS, worstBaseFee(gas, pol));
      const cost = ownCost(GAS_GUESS.refreshReference, gas, pol);
      if (!profitable(payment, cost, p.margin)) {
        skips.push({ door: "refreshReference", reason: `unprofitable: payment ${payment} under cost ${cost} plus margin` });
      } else {
        calls.push({ door: "refreshReference", functionName: "refreshReference", args: [], gas: GAS_GUESS.refreshReference, payment, cost, key: "refreshReference", note: { referenceTime: s.referenceTime, referenceMinSeconds: s.referenceMinSeconds } });
      }
    }
  }

  // 8. distributeSplit: the owner's own money (the artist and operator cut) moving from the split to its recipients, so
  // it is not profit gated: the split's distribution incentive, if any, pays the keeper as distributor, otherwise the
  // keeper pays the gas. gated on the balance thresholds and the door's base fee ceiling; the cost is logged
  if (on("distributeSplit")) {
    if (!p.split) skips.push({ door: "distributeSplit", reason: "no split configured" });
    else {
      const legs = splitLegs(s, p.split);
      for (const reason of legs.skips) skips.push({ door: "distributeSplit", reason });
      if (legs.due.length > 0 && ceiling("distributeSplit")) {
        const split = p.split;
        const cost = ownCost(GAS_GUESS.distributeSplit, gas, p.doors.distributeSplit);
        const config = { recipients: split.recipients, allocations: split.allocations, totalAllocation: split.totalAllocation, distributionIncentive: split.distributionIncentive };
        for (const leg of legs.due) {
          calls.push({
            door: "distributeSplit",
            functionName: "distribute",
            target: "split",
            args: [config, leg.token, split.distributor],
            gas: GAS_GUESS.distributeSplit,
            payment: 0n,
            cost,
            key: `distributeSplit:${leg.leg}`,
            note: { split: split.address, token: leg.token, amount: leg.amount, distributor: split.distributor, incentive: split.distributionIncentive },
          });
        }
      }
    }
  }

  // 9. refreshBidReference: the standing bid policy's own refreshReference, permissionless and unpaid (no caller payment,
  // unlike the Core doors), so the keeper pays the gas like the distributeSplit door: gated on the policy's refreshDue,
  // the treasury's CC redemption switch and the door's base fee ceiling, not on profit; the cost is logged
  if (on("refreshBidReference")) {
    const r = refreshBidReferenceDue(s, p);
    if (!r.ok) skips.push({ door: "refreshBidReference", reason: r.reason });
    else if (ceiling("refreshBidReference")) {
      const cost = ownCost(GAS_GUESS.refreshBidReference, gas, p.doors.refreshBidReference);
      calls.push({
        door: "refreshBidReference",
        functionName: "refreshReference",
        target: "bidPolicy",
        args: [],
        gas: GAS_GUESS.refreshBidReference,
        payment: 0n,
        cost,
        key: "refreshBidReference",
        note: { policy: s.bidPolicy, version: s.bidPolicyVersion, ccRedemptionEnabled: s.ccRedemptionEnabled, bidBudgetAvailable: s.bidBudgetAvailable },
      });
    }
  }

  return { calls, skips, seen: nextSeen };
}

// the payment and cost of a decided call at the gas its simulation measured, and whether it still clears the rule.
// unpaid doors pass when the measured cost is what the decision allowed for
export function recheck(c: Intended, s: State, listing: Listing | undefined, gasUsed: bigint, gas: Gas, p: Policy) {
  const pol = p.doors[c.door];
  const b = worstBaseFee(gas, pol);
  const cost = ownCost(gasUsed, gas, pol);
  let payment = 0n;
  switch (c.door) {
    case "buyListing":
      payment = listing ? listingPayment(s, listing, gasUsed, b) : 0n;
      break;
    case "buyback": {
      const q = buybackQuote(s, s.blockNumber + 1n, gasUsed, b);
      payment = q.ok ? q.payment : 0n;
      break;
    }
    case "compose":
      payment = callerPayment(s, gasUsed, COMPOSE_GAS, b);
      break;
    case "redeemStatement":
      payment = callerPayment(s, gasUsed, REDEEM_GAS, b);
      break;
    case "refreshReference":
      payment = callerPayment(s, gasUsed, REFRESH_GAS, b);
      break;
    case "collectEscrow":
      return { ok: s.escrowBalance >= cost, payment, cost };
    case "book":
      return { ok: true, payment, cost };
    case "distributeSplit":
      // the owner's own money moving; the measured cost is logged, never a gate
      return { ok: true, payment, cost };
    case "refreshBidReference":
      // unpaid upkeep of the owner's policy; the measured cost is logged, never a gate
      return { ok: true, payment, cost };
  }
  // compose and refreshReference are paid through the caller fee: they go only when the Core pays at least the cost
  return { ok: profitable(payment, cost, p.margin), payment, cost };
}
