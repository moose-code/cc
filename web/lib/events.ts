// Turns the decoded Core, ControllerV1 and FeeRouter logs into feed rows and
// per credit / per statement histories. Pure functions over decoded logs.

import { formatUnits, type Address } from "viem";
import { eth } from "./format";
import { EXIT_TOKEN_SYMBOL } from "./config";

export type FeedKind = "credit" | "composed" | "sold" | "redeemed";

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
  addr?: string; // an address closing the detail (buyer), ENS-ified
  link?: { text: string; href: string }; // names the credit or statement, leads the detail cell
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
  burned: bigint; // total coin burned by the core
  modes: Map<string, ComposeMode>; // Composed tx hash -> compose / composeChosen
  exitToken?: ExitTokenInfo;
  exitPaid: Map<string, bigint>; // `${tx}:${seller}` -> exit token sent by the core to the seller in that tx
  listedAt: Map<string, bigint>; // `${tx}:${sid}` -> controller priceOf(sid) at the Composed block
}

function num(n: string | number): string {
  return Number(n).toLocaleString("en-US", { maximumFractionDigits: 6 });
}

// An exit token amount with its symbol; raw units until the token is read.
export function formatExit(v: bigint, info?: ExitTokenInfo): string {
  return info ? `${num(formatUnits(v, info.decimals))} ${EXIT_TOKEN_SYMBOL}` : `${v} ${EXIT_TOKEN_SYMBOL} units`;
}

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
  const stmtLink = (sid: number) => ({ text: `statement ${sid}`, href: `/statements/${sid}` });
  const xtok = (v: bigint) => formatExit(v, inp.exitToken);

  // StatementSoldTo and the controller's Bought are one sale; one row.
  const soldKeys = new Set<string>();
  for (const l of logs) if (l.eventName === "StatementSoldTo") soldKeys.add(`${l.transactionHash}:${l.args.sid}`);

  // An EthRateFill is emitted just before the CreditBought it pays for.
  let fill: { tx: string; rate: bigint; pot: bigint } | undefined;

  for (const log of logs) {
    const name = log.eventName as string;
    const a = log.args ?? {};
    const tx = (log.transactionHash ?? "0x") as string;
    const block = (log.blockNumber ?? head) as bigint;
    const key = `${tx}-${log.logIndex}`;
    const base = { key, tx: tx.slice(0, 6), txHash: tx, block };
    const row = (r: Pick<FeedEvent, "kind" | "label" | "detail"> & Partial<FeedEvent>) => rows.push({ ...base, ...r });
    // Every way the engine gets a credit is one row: the credit, linked, and what it paid.
    const creditRow = (id: number, amount?: string) =>
      row({ kind: "credit", label: "credit acquired", detail: "", eth: amount, link: { text: `credit #${id}`, href: `/credits/${id}` }, tile: { kind: "credit", id } });

    if (fill && (fill.tx !== tx || name !== "CreditBought")) fill = undefined;

    switch (name) {
      // ---- credits into the pile ------------------------------------------
      case "EthRateFill":
        stats.ethIntoCredits += Number(formatUnits(a.spent, 18));
        fill = { tx, rate: a.rate, pot: a.pot };
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
          link: stmtLink(sid),
          detail: `${listed != null ? `· listed at ${eth(listed)} eth ` : ""}· cost ${eth(a.cost)} eth`,
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
          link: stmtLink(sid),
          detail: `· ${eth(a.toBuyback)} eth to buyback · bought by`,
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
        row({ kind: "sold", label: "statement sold", link: stmtLink(sid), detail: "bought by", eth: eth(a.price), addr: a.buyer, tile: { kind: "statement", id: sid } });
        break;
      }
      case "AnchorMoved": {
        const sid = Number(a.sid);
        st(sid).anchor.push({ saleBps: a.saleBps, anchorBps: Number(a.anchorBps), block, tx });
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
        row({ kind: "redeemed", label: "statement redeemed", link: stmtLink(sid), detail: `redeemed · received ${xtok(a.received)}`, tile: { kind: "statement", id: sid } });
        break;
      }

  }
  }
  return { stats, credits, statements, rows };
}
