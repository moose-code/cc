// Turns the decoded Core and ControllerV1 logs into feed rows and per credit /
// per statement histories. Pure functions over decoded logs.

import { formatUnits } from "viem";
import { BALANCE_SYMBOL, commas, eth, formatBalance, formatHistoricalBalance, type BalanceTokenInfo } from "./format";

export { BALANCE_SYMBOL, formatBalance };
export type { BalanceTokenInfo };

// Rows from the chain scan carry `block` (its timestamp is read per shown row); rows from the indexer carry `ts`.

// exchanged: a Credit sold to the engine for $BALANCE on /exchange (CreditBought through the balance bid)
export type FeedKind = "credit" | "exchanged" | "composed" | "sold" | "redeemed" | "burned";

export interface FeedEvent {
  key: string;
  block?: bigint;
  ts?: number; // unix seconds, with indexer rows
  kind: FeedKind;
  label: string; // short human name of the event
  detail: string;
  amount?: Amount; // what the engine (or its treasury) paid or received; undefined when nothing moved
  tx: string; // short display label
  txHash?: string; // full hash, drives the evm.now link
  tile?: { kind: "credit"; id: number } | { kind: "statement"; id: number };
  addr?: string; // an address closing the detail (buyer), ENS-ified
  link?: { text: string; href: string }; // names the credit or statement, leads the detail cell
  title?: string; // leads the detail cell of a row with no page to link (a $CC burn)
  rating?: bigint; // statement rows from the indexer
  composed?: { format: number; credits: number; cost: bigint }; // composed rows from the indexer
}

// The ledger's amount cell: the sign is from the engine's side ("+" came in, "−" went out), the value is compact
// above 10,000 (exact in `exact`), the unit always shown. A token the site cannot read keeps raw units, no unit.
export type Amount = { sign: "+" | "−"; value: string; unit: "ETH" | typeof BALANCE_SYMBOL | "$CC" | ""; exact?: string };

const compact = (n: number) =>
  n >= 1e6 ? `${+(n / 1e6).toFixed(1)}M` : n >= 1e4 ? `${+(n / 1e3).toFixed(1)}k` : n.toLocaleString("en-US", { maximumFractionDigits: 2 });

export const ethAmount = (sign: Amount["sign"], wei: bigint): Amount => ({ sign, value: eth(wei), unit: "ETH" });

export function balanceAmountCell(sign: Amount["sign"], v: bigint, token: string | undefined, info?: BalanceTokenInfo): Amount {
  const known = token && info?.address.toLowerCase() === token.toLowerCase() ? info : undefined;
  if (!known) return { sign, value: formatHistoricalBalance(v, token, info), unit: "" };
  const n = Number(formatUnits(v, known.decimals));
  return { sign, value: compact(n), unit: BALANCE_SYMBOL, exact: n.toLocaleString("en-US", { maximumFractionDigits: 6 }) };
}

export interface Stats {
  creditsEth: number; // CreditBought through the eth bid
  creditsBalance: number; // CreditBought through the balance bid
  creditsListing: number; // ListingBought
  creditsAdopted: number; // CreditAdopted
  creditsSold: number; // CreditSold from the credit sale
  composed: number;
  sold: number;
  redeemed: number;
  buybacks: number;
  ethIntoCredits: number; // sum of EthRateFill.spent and ValueRateFill.spent
  ccBurned: number;
  ethToPot: number; // the pot's part of StatementSoldTo sales (price less buyback, artist and operator), eth
  potSales: number; // the StatementSoldTo sales summed in ethToPot; a controller-only Bought sale has no split
  feesBooked: number; // sum of FeesAdded, eth
  artistReceived: number; // sum of the artist cut (StatementSoldTo and CreditSold toArtist), eth
  payeeReceived: number; // the operator cut of sales plus the pushed fee share, eth
}

export type CreditHow = "eth bid" | `${typeof BALANCE_SYMBOL} bid` | "listing" | "adopted";

// One step in a credit's life, in log order.
export type CreditEvt =
  | {
      t: "bought";
      how: CreditHow;
      cost: bigint; // recorded cost basis, wei
      from?: string; // seller (bids) or caller (listing)
      paid?: bigint; // listing: paid to the caller on top of the listing cost
      adapter?: string; // listing: the adapter that priced it
      rate?: bigint; // mode-off eth bid and listing: wei rate state after the fill
      pot?: bigint; // eth bid: pot after the fill
      block?: bigint;
      ts?: number;
      tx: string;
    }
  | { t: "sold"; buyer: string; price: bigint; toArtist: bigint; toOperator: bigint; block?: bigint; ts?: number; tx: string } // price split: toArtist and toOperator off the top, the rest stays with the engine
  | { t: "composed"; sid: number; block?: bigint; ts?: number; tx: string }
  | { t: "swapped"; dir: "in" | "out"; other: number; caller: string; fee: bigint; block?: bigint; ts?: number; tx: string };

export type ComposeMode = "default" | "chosen";

export interface StatementRecord {
  sid: number;
  composed?: {
    ids: number[];
    format: number;
    cost: bigint;
    caller: string;
    mode?: ComposeMode; // set when the transaction called Core.compose or Core.composeChosen directly
    block?: bigint;
    ts?: number;
    tx: string;
  };
  restyled: { format: number; caller: string; block?: bigint; ts?: number; tx: string }[];
  anchor: { saleBps: bigint; anchorBps: number; block?: bigint; ts?: number; tx: string }[];
  sold?: { buyer: string; price: bigint; toBuyback?: bigint; toArtist?: bigint; toOperator?: bigint; toPot?: bigint; block?: bigint; ts?: number; tx: string };
  redeemed?: { received: bigint; token?: string; block?: bigint; ts?: number; tx: string };
}

export interface Scan {
  feed: FeedEvent[];
  stats: Stats;
  credits: Record<number, CreditEvt[]>;
  statements: Record<number, StatementRecord>;
  balanceToken?: BalanceTokenInfo; // undefined while the Core has no module
}

export interface ScanInput {
  logs: any[]; // decoded logs of the Core and the controllers, sorted by block and log index
  head: bigint;
  burned: bigint; // total coin burned by the core
  burns?: Map<string, bigint>; // coin burned by the core per tx hash, read beside each Buyback
  modes: Map<string, ComposeMode>; // Composed tx hash -> compose / composeChosen
  balanceToken?: BalanceTokenInfo;
}

export function emptyStats(): Stats {
  return {
    creditsEth: 0,
    creditsBalance: 0,
    creditsListing: 0,
    creditsAdopted: 0,
    creditsSold: 0,
    composed: 0,
    sold: 0,
    redeemed: 0,
    buybacks: 0,
    ethIntoCredits: 0,
    ccBurned: 0,
    ethToPot: 0,
    potSales: 0,
    feesBooked: 0,
    artistReceived: 0,
    payeeReceived: 0,
  };
}

// The detail of a statement sale row: the pot's part and the buyback's part, then the buyer.
export const soldDetail = (toPot: bigint, toBuyback: bigint) => `· ${eth(toPot)} ETH to the pot · ${eth(toBuyback)} to buyback · bought by`;

export function processLogs(inp: ScanInput): { stats: Stats; credits: Scan["credits"]; statements: Scan["statements"]; rows: FeedEvent[] } {
  const { logs, head } = inp;
  const stats: Stats = { ...emptyStats(), ccBurned: Number(formatUnits(inp.burned, 18)) };
  const credits: Scan["credits"] = {};
  const statements: Scan["statements"] = {};
  const rows: FeedEvent[] = [];
  const cr = (id: number) => (credits[id] ??= []);
  const st = (sid: number) => (statements[sid] ??= { sid, anchor: [], restyled: [] });
  const stmtLink = (sid: number) => ({ text: `statement ${sid}`, href: `/statements/${sid}` });

  // StatementSoldTo and the controller's Bought are one sale; one row.
  const soldKeys = new Set<string>();
  for (const l of logs) if (l.eventName === "StatementSoldTo") soldKeys.add(`${l.transactionHash}:${l.args.sid}`);

  // An EthRateFill or ValueRateFill is emitted just before the CreditBought it pays for.
  let fill: { tx: string; rate?: bigint; pot: bigint } | undefined;
  let token: string | undefined;
  let balanceBuy: { tx: string; row: FeedEvent } | undefined;

  for (const log of logs) {
    const name = log.eventName as string;
    const a = log.args ?? {};
    const tx = (log.transactionHash ?? "0x") as string;
    const block = (log.blockNumber ?? head) as bigint;
    const key = `${tx}-${log.logIndex}`;
    const base = { key, tx: tx.slice(0, 6), txHash: tx, block };
    const row = (r: Pick<FeedEvent, "kind" | "label" | "detail"> & Partial<FeedEvent>) => rows.push({ ...base, ...r });
    // Every way the engine gets a credit is one row: the credit, linked, and what it paid.
    const creditRow = (id: number, amount?: Amount) =>
      row({ kind: "credit", label: "credit acquired", detail: "", amount, link: { text: `credit #${id}`, href: `/credits/${id}` }, tile: { kind: "credit", id } });

    if (fill && (fill.tx !== tx || name !== "CreditBought")) fill = undefined;

    switch (name) {
      case "BalanceModuleSet":
        token = String(a.balanceToken).toLowerCase();
        break;
      case "BalanceFill":
        // the seller's posted payout; the artist royalty (a.toArtist) rides on top from the module (decisions 163, 164)
        if (balanceBuy?.tx === tx) balanceBuy.row.amount = balanceAmountCell("−", a.paid, token, inp.balanceToken);
        balanceBuy = undefined;
        break;
      // ---- credits into the pile ------------------------------------------
      case "EthRateFill":
        stats.ethIntoCredits += Number(formatUnits(a.spent, 18));
        fill = { tx, rate: a.rate, pot: a.pot };
        break;
      case "ValueRateFill":
        stats.ethIntoCredits += Number(formatUnits(a.spent, 18));
        // rateBps is a shared multiplier, not an ETH rate; keep the rate field empty.
        fill = { tx, pot: a.pot };
        break;
      case "CreditBought": {
        const id = Number(a.id);
        const viaEth = fill?.tx === tx;
        const f = viaEth ? fill : undefined;
        // cost is the pile cost basis: on the eth bid the price plus the artist royalty (decision 163)
        cr(id).push({ t: "bought", how: viaEth ? "eth bid" : `${BALANCE_SYMBOL} bid`, cost: a.cost, from: a.from, rate: f?.rate, pot: f?.pot, block, tx });
        if (viaEth) stats.creditsEth++;
        else stats.creditsBalance++;
        if (viaEth) creditRow(id, ethAmount("−", a.cost));
        else {
          // the amount is filled in by the BalanceFill that follows in the same tx
          row({ kind: "exchanged", label: "credit exchanged", detail: `for ${BALANCE_SYMBOL} by`, addr: a.from, link: { text: `credit #${id}`, href: `/credits/${id}` }, tile: { kind: "credit", id } });
          balanceBuy = { tx, row: rows[rows.length - 1] };
        }
        fill = undefined;
        break;
      }
      case "ListingBought": {
        const id = Number(a.id);
        // the price, the artist royalty on it and the keeper payment: the pile cost basis (decision 163)
        const total = a.cost + (a.toArtist ?? 0n) + a.paid;
        cr(id).push({ t: "bought", how: "listing", cost: total, from: a.caller, paid: a.paid, adapter: a.adapter, rate: a.rate, block, tx });
        stats.creditsListing++;
        creditRow(id, ethAmount("−", total));
        break;
      }
      case "CreditAdopted": {
        const id = Number(a.id);
        cr(id).push({ t: "bought", how: "adopted", cost: a.cost, block, tx });
        stats.creditsAdopted++;
        // adoption pays nothing: the engine already held the credit, the cost is only its recorded basis
        creditRow(id);
        break;
      }
      case "CreditSwapped": {
        const inId = Number(a.inId);
        const outId = Number(a.outId);
        cr(inId).push({ t: "swapped", dir: "in", other: outId, caller: a.caller, fee: a.fee, block, tx });
        cr(outId).push({ t: "swapped", dir: "out", other: inId, caller: a.caller, fee: a.fee, block, tx });
        row({
          kind: "credit",
          label: "credit swapped",
          detail: `credit #${inId} in for #${outId} · fee ${eth(a.fee)} CC · by`,
          addr: a.caller,
          link: { text: `credit #${inId}`, href: `/credits/${inId}` },
          tile: { kind: "credit", id: inId },
        });
        break;
      }

      // ---- statements ------------------------------------------------------
      case "Composed": {
        const sid = Number(a.sid);
        const ids = (a.ids as readonly bigint[]).map(Number);
        const mode = inp.modes.get(tx);
        st(sid).composed = { ids, format: Number(a.format), cost: a.cost, caller: a.caller, mode, block, tx };
        for (const id of ids) cr(id).push({ t: "composed", sid, block, tx });
        stats.composed++;
        row({
          kind: "composed",
          label: mode === "chosen" ? "composed · chosen" : "statement composed",
          link: stmtLink(sid),
          detail: `${a.price > 0n ? `· listed at ${eth(a.price)} eth ` : ""}· format ${a.format} · cost ${eth(a.cost)} eth`,
          tile: { kind: "statement", id: sid },
        });
        break;
      }
      case "HeldFormatSet": {
        const sid = Number(a.sid);
        st(sid).restyled.push({ format: Number(a.format), caller: a.caller, block, tx });
        row({ kind: "composed", label: "statement restyled", link: stmtLink(sid), detail: `· format ${a.format} · by`, addr: a.caller, tile: { kind: "statement", id: sid } });
        break;
      }
      case "StatementSoldTo": {
        const sid = Number(a.sid);
        const toPot = (a.price as bigint) - (a.toBuyback as bigint) - (a.toArtist as bigint) - (a.toOperator as bigint);
        st(sid).sold = { buyer: a.buyer, price: a.price, toBuyback: a.toBuyback, toArtist: a.toArtist, toOperator: a.toOperator, toPot, block, tx };
        stats.sold++;
        stats.potSales++;
        stats.ethToPot += Number(formatUnits(toPot, 18));
        stats.artistReceived += Number(formatUnits(a.toArtist, 18));
        stats.payeeReceived += Number(formatUnits(a.toOperator, 18));
        row({
          kind: "sold",
          label: "statement sold",
          link: stmtLink(sid),
          detail: soldDetail(toPot, a.toBuyback),
          amount: ethAmount("+", a.price),
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
        row({ kind: "sold", label: "statement sold", link: stmtLink(sid), detail: "bought by", amount: ethAmount("+", a.price), addr: a.buyer, tile: { kind: "statement", id: sid } });
        break;
      }
      case "AnchorMoved": {
        const sid = Number(a.sid);
        st(sid).anchor.push({ saleBps: a.saleBps, anchorBps: Number(a.anchorBps), block, tx });
        break;
      }
      case "CreditSold": {
        const id = Number(a.id);
        cr(id).push({ t: "sold", buyer: a.buyer, price: a.price, toArtist: a.toArtist, toOperator: a.toOperator, block, tx });
        stats.creditsSold++;
        stats.artistReceived += Number(formatUnits(a.toArtist, 18));
        stats.payeeReceived += Number(formatUnits(a.toOperator, 18));
        row({ kind: "sold", label: "credit sold", detail: `credit #${id} bought from the credit sale by`, amount: ethAmount("+", a.price), addr: a.buyer, tile: { kind: "credit", id } });
        break;
      }
      case "StatementRedeemed": {
        const sid = Number(a.sid);
        st(sid).redeemed = { received: a.received, token, block, tx };
        stats.redeemed++;
        row({ kind: "redeemed", label: "statement redeemed", link: stmtLink(sid), detail: `· converted to ${BALANCE_SYMBOL}`, amount: balanceAmountCell("+", a.received, token, inp.balanceToken), tile: { kind: "statement", id: sid } });
        break;
      }

      // ---- engine events that feed the stats --------------------------------
      case "Buyback": {
        stats.buybacks++;
        // the buyback pools the buyback share of every sale, so the burn names no source statement
        const burned = inp.burns?.get(tx);
        row({ kind: "burned", label: "$CC burned", title: burned != null ? `${commas(Number(formatUnits(burned, 18)))} $CC` : "$CC", detail: `bought with ${eth(a.amountIn)} ETH`, amount: ethAmount("−", a.amountIn) });
        break;
      }
      case "FeesAdded":
        stats.feesBooked += Number(formatUnits(a.amount, 18));
        stats.payeeReceived += Number(formatUnits(a.toPayee, 18));
        break;
    }
  }
  return { stats, credits, statements, rows };
}
