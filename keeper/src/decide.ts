// The keeper's decisions: pure functions of the chain state read at one block, the candidate listings and the gas
// state. Every gate restates a Core rule (src/Core.sol) so a call that would revert or pay less than its own cost is
// never simulated, and the simulation stays the final check. Payments are evaluated at the worst base fee the
// transaction can land at, `min(baseFee * 9 / 8, door maxBaseFee)`: the gas refund of a paid door tracks the base fee
// up to its setting's ceiling, so the worst case is the highest base fee.

import type { Address, Hex } from "viem";
import type { Door, DoorPolicy } from "./config.ts";

// the private gas constants of the Core (src/Core.sol 224 to 236), restated
export const COMPOSE_GAS = 13_700_000n;
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
};

export interface Settings {
  buybackSlice: bigint;
  buybackDelay: number;
  keeperFee: bigint;
  keeperMaxBaseFee: bigint;
  callerFee: bigint;
  callerMaxBaseFee: bigint;
  redeemOn: boolean;
}

// the state the decisions read, all from one block
export interface State {
  core: Address;
  blockNumber: bigint;
  timestamp: bigint;
  baseFee: bigint;
  settings: Settings;
  ethPot: bigint;
  // ethPot plus the pot share of the unbooked income that the door's own `_book` adds first
  potWithPending: bigint;
  pendingIncome: bigint;
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
  // the held statements with controller.atFloor(sid) true
  atFloor: bigint[];
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
  functionName: "buyListing" | "buyback" | "compose" | "collectEscrow" | "book" | "redeemStatement";
  args: readonly unknown[];
  // the gas the decision assumed; the executor replaces it with the simulation's measure and calls `recheck`
  gas: bigint;
  // the payment the Core sends at `gas`, at the worst base fee
  payment: bigint;
  cost: bigint;
  // logged only, never sent (redeemStatement while no balance module is set)
  dryOnly?: boolean;
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

// Core.buyListing: min(min(counted, BUYLISTING_GAS) * min(basefee, keeperMaxBaseFee) + keeperFee, bid - price, ethPot - price),
// the pot read after the door's book
export function listingPayment(s: State, l: Listing, gasUsed: bigint, b: bigint): bigint {
  if (l.price > l.bid || l.price > s.potWithPending) return 0n;
  const refund = min(gasUsed, BUYLISTING_GAS) * min(b, s.settings.keeperMaxBaseFee) + s.settings.keeperFee;
  return min(refund, l.bid - l.price, s.potWithPending - l.price);
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

// whether a book now latches the payee share: Core._book returns before the latch when the income is 0, and the latch
// needs block.timestamp >= launchedAt + SNIPER_SECONDS
export function bookLatches(s: State): { ok: boolean; reason: string } {
  if (s.payeeOn) return { ok: false, reason: "payee share already latched" };
  if (s.launchedAt === 0n) return { ok: false, reason: "launch not recorded by the factory" };
  const end = s.launchedAt + s.sniperSeconds;
  if (s.timestamp < end) return { ok: false, reason: `anti sniper window ends at ${end}` };
  if (s.pendingIncome === 0n) return { ok: false, reason: "no unbooked income, a book would not latch" };
  return { ok: true, reason: "window over, income pending, payee share not latched" };
}

export const listingKey = (l: Pick<Listing, "venue" | "id" | "price">) => `${l.venue}:${l.id}:${l.price}`;

// the first time each listing key was seen sweepable: kept for keys still sweepable, set to `now` for new ones,
// dropped for the rest, so a listing that leaves the sweepable set restarts its delay
export function observe(seen: ReadonlyMap<string, bigint>, sweepable: string[], now: bigint): Map<string, bigint> {
  const next = new Map<string, bigint>();
  for (const k of sweepable) next.set(k, seen.get(k) ?? now);
  return next;
}

// every call the keeper would make at this state, in priority order: buyListing (best gap first), buyback, compose,
// collectEscrow, book, redeemStatement. returns the updated staleness map
export function decide(
  s: State,
  listings: Listing[],
  gas: Gas,
  p: Policy,
  seen: ReadonlyMap<string, bigint>,
): { calls: Intended[]; skips: Skip[]; seen: Map<string, bigint> } {
  const calls: Intended[] = [];
  const skips: Skip[] = [];
  const on = (d: Door) => p.doorsOn.has(d);
  const ceiling = (d: Door) => {
    if (gas.baseFee > p.doors[d].maxBaseFee) {
      skips.push({ door: d, reason: `base fee ${gas.baseFee} above the door ceiling ${p.doors[d].maxBaseFee}` });
      return false;
    }
    return true;
  };

  // 1. buyListing
  const sweepable: { l: Listing; key: string; payment: bigint; cost: bigint }[] = [];
  if (on("buyListing") && !s.retired && ceiling("buyListing")) {
    const pol = p.doors.buyListing;
    const b = worstBaseFee(gas, pol);
    for (const l of listings) {
      const key = listingKey(l);
      if (!l.valid) {
        skips.push({ door: "buyListing", key, reason: l.why ?? "order not fillable" });
        continue;
      }
      if (l.price > l.bid) continue;
      if (l.price > s.potWithPending) {
        skips.push({ door: "buyListing", key, reason: "PotTooSmall: price above ethPot" });
        continue;
      }
      const payment = listingPayment(s, l, GAS_GUESS.buyListing, b);
      const cost = ownCost(GAS_GUESS.buyListing, gas, pol);
      if (!profitable(payment, cost, p.margin)) {
        skips.push({ door: "buyListing", key, reason: `unprofitable: payment ${payment} under cost ${cost} plus margin` });
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

  // 5. book: unpaid; only the book that latches the payee share is the keeper's, every other door books on its own
  if (on("book")) {
    const r = bookLatches(s);
    if (!r.ok) skips.push({ door: "book", reason: r.reason });
    else if (ceiling("book")) {
      const cost = ownCost(GAS_GUESS.book, gas, p.doors.book);
      calls.push({ door: "book", functionName: "book", args: [], gas: GAS_GUESS.book, payment: 0n, cost, key: "book", note: { income: s.pendingIncome } });
    }
  }

  // 6. redeemStatement: reverts NoBalanceModule until a module is set, so it is logged only until then
  if (on("redeemStatement") && s.atFloor.length > 0) {
    const pol = p.doors.redeemStatement;
    const noModule = /^0x0{40}$/i.test(s.balanceModule);
    if (!noModule && !s.settings.redeemOn) skips.push({ door: "redeemStatement", reason: "RedeemOff" });
    else if (noModule || ceiling("redeemStatement")) {
      for (const sid of s.atFloor) {
        const payment = callerPayment(s, GAS_GUESS.redeemStatement, REDEEM_GAS, worstBaseFee(gas, pol));
        const cost = ownCost(GAS_GUESS.redeemStatement, gas, pol);
        const key = `redeem:${sid}`;
        if (noModule) {
          calls.push({ door: "redeemStatement", functionName: "redeemStatement", args: [sid], gas: GAS_GUESS.redeemStatement, payment, cost, key, dryOnly: true, note: { sid, why: "NoBalanceModule: no module set" } });
        } else if (!profitable(payment, cost, p.margin)) {
          skips.push({ door: "redeemStatement", key, reason: `unprofitable: payment ${payment} under cost ${cost} plus margin` });
        } else {
          calls.push({ door: "redeemStatement", functionName: "redeemStatement", args: [sid], gas: GAS_GUESS.redeemStatement, payment, cost, key, note: { sid } });
        }
      }
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
    case "collectEscrow":
      return { ok: s.escrowBalance >= cost, payment, cost };
    case "book":
      return { ok: true, payment, cost };
  }
  return { ok: profitable(payment, cost, p.margin), payment, cost };
}
