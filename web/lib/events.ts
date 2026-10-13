// Turns the decoded Core, ControllerV1 and FeeRouter logs into feed rows and
// per credit / per statement histories. Pure functions over decoded logs.

import { formatUnits, type Address } from "viem";
import { eth, shortAddr, commas } from "./format";
import { EXIT_TOKEN_SYMBOL } from "./config";

export type FeedKind = "fee" | "credit" | "composed" | "listed" | "sold" | "burn" | "redeemed" | "price" | "admin";

export interface FeedEvent {
  key: string;
  block: bigint; // its timestamp is read per shown row
  kind: FeedKind;
  label: string; // short human name of the event
  detail: string;
  eth?: string; // pre-formatted for the eth column
  tx: string; // short display label
  txHash?: string; // full hash, drives the evm.now link
  tile?: { kind: "credit"; id: number } | { kind: "statement"; id: number };
  addr?: string; // an address closing the detail (buyer, seller, caller), ENS-ified
  link?: { text: string; href: string }; // opens the detail, linked page leads the detail cell
}

export interface Stats {
  creditsEth: number; // CreditBought through the eth bid
  creditsExit: number; // CreditBought through the $BALANCE bid
  creditsListing: number; // ListingBought
  creditsAdopted: number; // CreditAdopted
  creditsSold: number; // CreditSold from the credit sale
  composed: number;
  sold: number;
  redeemed: number;
  ethIntoCredits: number; // sum of EthRateFill.spent
  ccBurned: number;
}

export type CreditHow = "eth bid" | `${typeof EXIT_TOKEN_SYMBOL} bid` | "listing" | "adopted";

// One step in a credit's life, in log order.
export type CreditEvt =
  | {
      t: "bought";
      how: CreditHow;
      cost: bigint; // recorded cost basis, wei
      from?: string; // seller (bids) or caller (listing)
      paid?: bigint; // listing: paid to the caller on top of the listing cost
      target?: string; // listing: the market contract
      rate?: bigint; // eth bid and listing: rate state after the fill
      pot?: bigint; // eth bid: pot after the fill
      block: bigint;
      tx: string;
    }
  | { t: "sold"; buyer: string; price: bigint; block: bigint; tx: string }
  | { t: "composed"; sid: number; block: bigint; tx: string };

export type ComposeMode = "default" | "chosen";

export interface StatementRecord {
  sid: number;
  composed?: {
    ids: number[];
    format: number;
    cost: bigint;
    caller: string;
    mode?: ComposeMode; // set when the transaction called Core.compose or Core.composeChosen directly
    block: bigint;
    tx: string;
  };
  anchor: { saleBps: bigint; anchorBps: number; block: bigint; tx: string }[];
  sold?: { buyer: string; price: bigint; toBuyback?: bigint; block: bigint; tx: string };
  exited?: { received: bigint; block: bigint; tx: string };
}

export interface Scan {
  feed: FeedEvent[];
  stats: Stats;
  credits: Record<number, CreditEvt[]>;
  statements: Record<number, StatementRecord>;
}

export interface ExitTokenInfo {
  address: Address;
  decimals: number;
}

export interface ScanInput {
  logs: any[]; // decoded logs of the three contracts, sorted by block and log index
  head: bigint;
  router?: Address;
  burnedBy: Map<string, bigint>; // tx hash -> coin burned by the core in it
  burned: bigint; // total coin burned by the core
  modes: Map<string, ComposeMode>; // Composed tx hash -> compose / composeChosen
  prevSettings: Map<string, Record<string, unknown>>; // SettingsSet log key -> settings before it
  exitToken?: ExitTokenInfo;
  exitPaid: Map<string, bigint>; // `${tx}:${seller}` -> exit token sent by the core to the seller in that tx
  listedAt: Map<string, bigint>; // `${tx}:${sid}` -> controller priceOf(sid) at the Composed block
}

// Settings that carry a unit or a named value.
const UNIT: Record<string, "eth" | "gwei" | "cc" | "s" | "blocks" | "exitMode"> = {
  buybackSlice: "eth",
  keeperFee: "eth",
  rateCap: "eth",
  callerFee: "eth",
  anchorMinCost: "eth",
  keeperMaxBaseFee: "gwei",
  callerMaxBaseFee: "gwei",
  minCcToChoose: "cc",
  peakHalfLife: "s",
  anchorHalfLife: "s",
  creditWindow: "s",
  buybackDelay: "blocks",
  exitMode: "exitMode",
};
const EXIT_MODE = ["off", "hold", "on"];

function num(n: string | number): string {
  return Number(n).toLocaleString("en-US", { maximumFractionDigits: 6 });
}

// An exit token amount with its symbol; raw units until the token is read.
export function formatExit(v: bigint, info?: ExitTokenInfo): string {
  return info ? `${num(formatUnits(v, info.decimals))} ${EXIT_TOKEN_SYMBOL}` : `${v} ${EXIT_TOKEN_SYMBOL} units`;
}

export function settingValue(name: string, v: unknown): string {
  if (typeof v === "boolean") return v ? "on" : "off";
  const x = BigInt(v as bigint | number);
  switch (UNIT[name]) {
    case "eth":
      return `${num(formatUnits(x, 18))} eth`;
    case "gwei":
      return `${num(formatUnits(x, 9))} gwei`;
    case "cc":
      return `${num(formatUnits(x, 18))} cc`;
    case "s":
      return `${commas(Number(x))} s`;
    case "blocks":
      return `${commas(Number(x))} blocks`;
    case "exitMode":
      return EXIT_MODE[Number(x)] ?? String(x);
    default:
      return commas(Number(x));
  }
}

// Single value setters of the Core and the controller: event name minus "Set" is the setting.
const lowerFirst = (s: string) => s[0].toLowerCase() + s.slice(1);
const SETTERS = new Set([
  "RateSet",
  "CreditCostToPotBpsSet",
  "ChosenComposeOnSet",
  "MinCcToChooseSet",
  "AnchorBpsSet",
  "AnchorHalfLifeSet",
  "AnchorMinCostSet",
  "CreditFloorBpsSet",
  "CreditSaleOnSet",
  "CreditStartBpsSet",
  "CreditWindowSet",
  "FastDecayBpsPerHourSet",
  "FloorBpsSet",
  "KneeBpsSet",
  "MarkupBpsSet",
  "RefScoreSet",
  "SlowDecayBpsPerHourSet",
  "StartCapBpsSet",
]);

const LOCKS: Record<string, string> = {
  ControllerLocked: "controller",
  ExitModuleLocked: "exit module",
  TargetsLocked: "targets",
  SuccessorLocked: "successor",
};

const bps = (n: bigint | number) => `${(Number(n) / 100).toLocaleString("en-US", { maximumFractionDigits: 2 })}%`;

export function processLogs(inp: ScanInput): { stats: Stats; credits: Scan["credits"]; statements: Scan["statements"]; rows: FeedEvent[] } {
  const { logs, head } = inp;
  const stats: Stats = {
    creditsEth: 0,
    creditsExit: 0,
    creditsListing: 0,
    creditsAdopted: 0,
    creditsSold: 0,
    composed: 0,
    sold: 0,
    redeemed: 0,
    ethIntoCredits: 0,
    ccBurned: Number(formatUnits(inp.burned, 18)),
  };
  const credits: Scan["credits"] = {};
  const statements: Scan["statements"] = {};
  const rows: FeedEvent[] = [];
  const cr = (id: number) => (credits[id] ??= []);
  const st = (sid: number) => (statements[sid] ??= { sid, anchor: [] });
  const xtok = (v: bigint) => formatExit(v, inp.exitToken);

  // StatementSoldTo and the controller's Bought are one sale; one row.
  const soldKeys = new Set<string>();
  for (const l of logs) if (l.eventName === "StatementSoldTo") soldKeys.add(`${l.transactionHash}:${l.args.sid}`);

  // An EthRateFill is emitted just before the CreditBought or ListingBought it pays for.
  let fill: { tx: string; spent: bigint; rate: bigint; pot: bigint; row: Omit<FeedEvent, "kind" | "label" | "detail"> } | undefined;
  const flushFill = () => {
    if (!fill) return;
    rows.push({
      ...fill.row,
      kind: "credit",
      label: "eth bid fill",
      detail: `rate after ${eth(fill.rate)} eth · pot ${eth(fill.pot)} eth`,
      eth: eth(fill.spent),
    });
    fill = undefined;
  };

  for (const log of logs) {
    const name = log.eventName as string;
    const a = log.args ?? {};
    const tx = (log.transactionHash ?? "0x") as string;
    const block = (log.blockNumber ?? head) as bigint;
    const key = `${tx}-${log.logIndex}`;
    const base: Omit<FeedEvent, "kind" | "label" | "detail"> = { key, tx: tx.slice(0, 6), txHash: tx, block };
    const row = (r: Pick<FeedEvent, "kind" | "label" | "detail"> & Partial<FeedEvent>) => rows.push({ ...base, ...r });
    const fromRouter = inp.router != null && String(log.address).toLowerCase() === inp.router.toLowerCase();
    const admin = (label: string, detail: string, addr?: string) => row({ kind: "admin", label, detail, addr });
    // Every way the engine gets a credit is one row: the credit, linked, and what it paid.
    const creditRow = (id: number, amount?: string) =>
      row({ kind: "credit", label: "credit acquired", detail: "", eth: amount, link: { text: `credit #${id}`, href: `/credits/${id}` }, tile: { kind: "credit", id } });

    if (fill && (fill.tx !== tx || (name !== "CreditBought" && name !== "ListingBought"))) flushFill();

    switch (name) {
      // ---- fees ---------------------------------------------------------
      case "FeesAdded":
        row({ kind: "fee", label: "fee in", detail: "swap fee to engine", eth: eth(a.amount) });
        break;
      case "Skimmed":
        row({
          kind: "fee",
          label: "skim",
          detail: `unbooked balance booked to the pots${a.exitToken > 0n ? ` · ${xtok(a.exitToken)}` : ""}`,
          eth: a.eth > 0n ? eth(a.eth) : undefined,
        });
        break;
      case "Flushed":
        row({
          kind: "fee",
          label: "fee flush",
          detail: `router to engine ${eth(a.toEngine)} eth · to payees ${eth(a.toPayees)} eth`,
          eth: eth(a.toEngine + a.toPayees),
        });
        break;
      case "PayeePaid":
        row({ kind: "fee", label: "payee paid", detail: "router paid payee", eth: eth(a.amount), addr: a.payee });
        break;
      case "PayeeOwed":
        row({ kind: "fee", label: "payee owed", detail: "router credited payee, send failed", eth: eth(a.amount), addr: a.payee });
        break;
      case "Claimed":
        row({ kind: "fee", label: "payee claimed", detail: "payee claimed owed eth", eth: eth(a.amount), addr: a.payee });
        break;
      case "SplitStarted":
        row({ kind: "fee", label: "split started", detail: "router payee split turned on" });
        break;

      // ---- credits into the pile ------------------------------------------
      case "EthRateFill":
        stats.ethIntoCredits += Number(formatUnits(a.spent, 18));
        fill = { tx, spent: a.spent, rate: a.rate, pot: a.pot, row: base };
        break;
      case "CreditBought": {
        const id = Number(a.id);
        const viaEth = fill?.tx === tx;
        const f = viaEth ? fill : undefined;
        cr(id).push({ t: "bought", how: viaEth ? "eth bid" : `${EXIT_TOKEN_SYMBOL} bid`, cost: a.cost, from: a.from, rate: f?.rate, pot: f?.pot, block, tx });
        if (viaEth) stats.creditsEth++;
        else stats.creditsExit++;
        const paid = inp.exitPaid.get(`${tx}:${String(a.from).toLowerCase()}`);
        creditRow(id, viaEth ? eth(a.cost) : paid != null ? formatExit(paid, inp.exitToken) : undefined);
        fill = undefined;
        break;
      }
      case "ListingBought": {
        const id = Number(a.id);
        const total = a.cost + a.paid;
        cr(id).push({ t: "bought", how: "listing", cost: total, from: a.caller, paid: a.paid, target: a.target, rate: a.rate, block, tx });
        stats.creditsListing++;
        creditRow(id, eth(total));
        fill = undefined;
        break;
      }
      case "CreditAdopted": {
        const id = Number(a.id);
        cr(id).push({ t: "bought", how: "adopted", cost: a.cost, block, tx });
        stats.creditsAdopted++;
        creditRow(id, eth(a.cost));
        break;
      }

      // ---- statements ------------------------------------------------------
      case "Composed": {
        const sid = Number(a.sid);
        const ids = (a.ids as readonly bigint[]).map(Number);
        const mode = inp.modes.get(tx);
        const listed = inp.listedAt.get(`${tx}:${sid}`);
        st(sid).composed = { ids, format: Number(a.format), cost: a.cost, caller: a.caller, mode, block, tx };
        for (const id of ids) cr(id).push({ t: "composed", sid, block, tx });
        stats.composed++;
        row({
          kind: "composed",
          label: mode === "chosen" ? "composed · chosen" : "statement composed",
          detail: `statement ${sid}${listed != null ? ` · listed at ${eth(listed)} eth` : ""} · cost ${eth(a.cost)} eth · composed by`,
          addr: a.caller,
          tile: { kind: "statement", id: sid },
        });
        break;
      }
      case "StatementSoldTo": {
        const sid = Number(a.sid);
        st(sid).sold = { buyer: a.buyer, price: a.price, toBuyback: a.toBuyback, block, tx };
        stats.sold++;
        row({
          kind: "sold",
          label: "statement sold",
          detail: `statement ${sid} · ${eth(a.toBuyback)} eth to buyback · bought by`,
          eth: eth(a.price),
          addr: a.buyer,
          tile: { kind: "statement", id: sid },
        });
        break;
      }
      case "Bought": {
        const sid = Number(a.sid);
        if (soldKeys.has(`${tx}:${sid}`)) break;
        st(sid).sold = { buyer: a.buyer, price: a.price, block, tx };
        stats.sold++;
        row({ kind: "sold", label: "statement sold", detail: `statement ${sid} bought by`, eth: eth(a.price), addr: a.buyer, tile: { kind: "statement", id: sid } });
        break;
      }
      case "AnchorMoved": {
        const sid = Number(a.sid);
        st(sid).anchor.push({ saleBps: a.saleBps, anchorBps: Number(a.anchorBps), block, tx });
        row({
          kind: "price",
          label: "anchor moved",
          detail: `statement ${sid} sold at ${bps(a.saleBps)} of its reference · anchor now ${bps(a.anchorBps)}`,
          tile: { kind: "statement", id: sid },
        });
        break;
      }
      case "CreditSold": {
        const id = Number(a.id);
        cr(id).push({ t: "sold", buyer: a.buyer, price: a.price, block, tx });
        stats.creditsSold++;
        row({ kind: "sold", label: "credit sold", detail: `credit #${id} bought from the credit sale by`, eth: eth(a.price), addr: a.buyer, tile: { kind: "credit", id } });
        break;
      }
      case "StatementExited": {
        const sid = Number(a.sid);
        st(sid).exited = { received: a.received, block, tx };
        stats.redeemed++;
        row({ kind: "redeemed", label: "statement redeemed", detail: `statement ${sid} redeemed · received ${xtok(a.received)}`, tile: { kind: "statement", id: sid } });
        break;
      }

      // ---- burns -------------------------------------------------------------
      case "Buyback": {
        const burned = Math.floor(Number(formatUnits(inp.burnedBy.get(tx) ?? 0n, 18))).toLocaleString();
        row({ kind: "burn", label: "buyback", detail: `burned ${burned} cc · keeper paid ${eth(a.paid)} eth · called by`, eth: eth(a.amountIn), addr: a.caller });
        break;
      }
      case "RedeemBurnReleased":
        row({ kind: "burn", label: "redeem burn release", detail: "redeem burn reserve moved to the buyback pot", eth: eth(a.amount) });
        break;

      // ---- settings ----------------------------------------------------------
      case "SettingsSet": {
        const prev = inp.prevSettings.get(key);
        const now = a.settings as Record<string, unknown>;
        let changed = 0;
        for (const f of Object.keys(now)) {
          if (prev && prev[f] === now[f]) continue;
          changed++;
          const to = settingValue(f, now[f]);
          const label = f === "exitMode" ? "exit mode set" : "setting";
          const detail = prev ? `${f} ${settingValue(f, prev[f])} → ${to}` : `${f} set to ${to}`;
          rows.push({ ...base, key: `${key}-${f}`, kind: "admin", label, detail });
        }
        if (changed === 0) admin("setting", "settings written with the same values");
        break;
      }
      case "PausedSet":
        admin(a.paused ? "paused" : "unpaused", a.paused ? "statement and credit sales paused" : "statement and credit sales resumed");
        break;
      case "ExitPoolKeySet":
        admin(
          "exit pool key set",
          `${shortAddr(a.currency0)} / ${shortAddr(a.currency1)} · fee ${commas(Number(a.fee))} · tick spacing ${a.tickSpacing} · hooks ${shortAddr(a.hooks)}`
        );
        break;
      case "ExitModuleSet":
        admin("exit module set", `token ${shortAddr(a.exitToken)} · unit per point ${a.unitPerPoint} · module`, a.exitModule);
        break;
      case "UnitPerPointRefreshed":
        admin("unit per point refreshed", `${a.unitPerPoint} from module`, a.exitModule);
        break;
      case "ControllerSet":
        admin("controller set", "sale controller is now", a.controller);
        break;
      case "TargetAdded":
        admin("target added", "buyListing target allowed", a.target);
        break;
      case "TargetRemoved":
        admin("target removed", "buyListing target removed", a.target);
        break;
      case "CoinRescued":
        admin("coin rescued", `${num(formatUnits(a.amount, 18))} cc sent to`, a.to);
        break;
      case "NftRescued":
        admin("nft rescued", `token ${shortAddr(a.token)} #${a.id} sent to`, a.to);
        break;
      case "SuccessorSet":
        admin("successor set", "migration target is now", a.successor);
        break;
      case "Migrated":
        admin("migrated", `${eth(a.eth)} eth · ${xtok(a.exitTokens)} · ${a.credits} credits moved to`, a.successor);
        break;
      case "EngineRetired":
        admin("engine retired", "core retired, successor", a.successor);
        break;
      case "ExitTokenMigrationSkipped":
        admin(`${EXIT_TOKEN_SYMBOL} migration skipped`, `${xtok(a.amount)} stays in the pot, successor`, a.successor);
        break;
      case "OwnershipTransferStarted":
        admin("ownership transfer started", `${fromRouter ? "fee router" : "core"} ownership offered to`, a.pending);
        break;
      case "OwnershipTransferred":
        admin("ownership transferred", `${fromRouter ? "fee router" : "core"} owner is now`, a.to);
        break;
      case "EngineSet":
        admin("router engine set", `flush target changed from ${shortAddr(a.previous)} to`, a.engine);
        break;
      case "Locked":
        admin("router locked", "router engine and payees locked, engine", a.engine);
        break;
      case "PayeesSet":
        admin(
          "payees set",
          (a.payees as string[]).length
            ? (a.payees as string[]).map((p, i) => `${shortAddr(p)} ${commas(Number(a.ppm[i]))} ppm`).join(" · ")
            : "payee list cleared"
        );
        break;
      case "SplitStartSet":
        admin("split start set", a.at === 0n ? "payee split disabled" : `payee split starts at ${new Date(Number(a.at) * 1000).toISOString().slice(0, 16).replace("T", " ")} UTC`);
        break;
      default:
        if (LOCKS[name]) admin("locked", `${LOCKS[name]} locked`);
        else if (SETTERS.has(name)) {
          const field = lowerFirst(name.replace(/Set$/, ""));
          const v = Object.values(a)[0];
          if (name === "RateSet") row({ kind: "admin", label: "eth rate set", detail: "eth bid rate set by the owner", eth: eth(v as bigint) });
          else admin("setting", `${field} set to ${settingValue(field, v)}`);
        }
    }
  }
  flushFill();
  return { stats, credits, statements, rows };
}
