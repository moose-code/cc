"use client";

// Indexer data with the on-chain path behind it. Each hook returns one shape in both modes (lib/indexer.ts
// useIxMode): "ix" reads the indexer, "chain" derives the same values from the browser log scan (lib/engine.ts)
// and the live reads. Components call these hooks and never branch on the mode.

import { useMemo } from "react";
import { engineDeployed } from "./config";
import { BANDS, BUCKET_WEI, WEEK_S, bandOf, bandReport, cheapestByBand, type BandReport } from "./market-report";
import { useMarketView } from "./market-view";
import { useBlockTs, useScan } from "./engine";
import type { CreditEvt, FeedEvent, StatementRecord } from "./events";
import {
  feedEvent,
  howLabel,
  useBuyRateIx,
  useCreditHistoryIx,
  useCreditRow,
  useFeedIx,
  useIxMode,
  useMarketIx,
  useStatementDetailIx,
  useStatementRowsIx,
  useStatsIx,
  type FeedFilter,
  type Stats,
  type StatementDetail,
} from "./indexer";
import { useBalanceToken, useCredit, useCreditCostToPotAt, usePile, useCreditOwner, useCreditTraits, useScores, useSnapshot, useStatementOwner, useHead, type PileCredit } from "./live";

export type { Stats, FeedFilter };

/** True when no source can serve history: the chain scan failed and the indexer is not usable. */
export function useHistoryDown(): boolean {
  const mode = useIxMode();
  const scan = useScan();
  return mode === "chain" && scan.isError;
}

/** True until history answers: the indexer check, then the indexer query (`ix`, answered or failed) or the chain
 * scan. While true an empty list or a missing record is not yet known to be empty or missing. */
function useHistoryPending(ix: { data?: unknown; isError: boolean }): boolean {
  const mode = useIxMode();
  const scan = useScan();
  if (!engineDeployed) return false; // no engine: no source will answer, the history is empty
  if (mode === "checking") return true;
  if (mode === "ix") return ix.data === undefined && !ix.isError;
  return !scan.ready && !scan.isError;
}

// ---- stats ---------------------------------------------------------------------------------------------------

export function useStats(): { data?: Stats } {
  const mode = useIxMode();
  const ixq = useStatsIx();
  const { data: scan, ready } = useScan();
  const s = scan.stats;
  return {
    data:
      mode === "ix"
        ? ixq.data
        : mode === "chain" && ready
          ? {
              ccBurned: s.ccBurned,
              artistReceived: s.artistReceived,
              payeeReceived: s.payeeReceived,
              composed: s.composed,
              creditsAcquired: s.creditsEth + s.creditsBalance + s.creditsListing + s.creditsAdopted,
              ethToPot: s.ethToPot,
              potSales: s.potSales,
            }
          : undefined,
  };
}

/** Credits bought per hour over the last 24 hours (adopted credits are not buys). undefined while unknown. */
export function useBuyRate(): { perHour: number | undefined; recent: boolean } {
  const mode = useIxMode();
  const { data: head } = useHead();
  const ix = useBuyRateIx(head?.ts);
  const { data: scan } = useScan();
  const { blocks, oldest } = useMemo(() => {
    const blocks: bigint[] = [];
    for (const evts of Object.values(scan.credits))
      for (const e of evts) if (e.t === "bought" && e.how !== "adopted" && e.block != null) blocks.push(e.block);
    const oldest = blocks.reduce<bigint | undefined>((m, b) => (m === undefined || b < m ? b : m), undefined);
    return { blocks, oldest };
  }, [scan.credits]);
  const { data: oldestTs } = useBlockTs(mode === "chain" ? oldest : undefined);
  const chainRate = useMemo(() => {
    if (!head) return undefined;
    if (oldest === undefined) return 0;
    if (oldestTs == null) return undefined;
    const WINDOW = 24 * 3600;
    const span = Number(head.n - oldest);
    const secPerBlock = span > 0 ? Math.max(1, (head.ts - oldestTs) / span) : 12;
    const cutoff = head.n - BigInt(Math.floor(WINDOW / secPerBlock));
    const count = blocks.filter((b) => b >= cutoff).length;
    const seconds = Math.min(WINDOW, Math.max(3600, head.ts - oldestTs));
    return count / (seconds / 3600);
  }, [blocks, oldest, head, oldestTs]);
  return mode === "ix" ? ix : { perHour: mode === "chain" ? chainRate : undefined, recent: false };
}

// ---- feed ----------------------------------------------------------------------------------------------------

/** Ledger rows, newest first, `limit` of them; total counts all rows of the filter. */
export function useFeed(filter: FeedFilter, limit: number): { events: FeedEvent[]; total: number; loading: boolean } {
  const mode = useIxMode();
  const ixq = useFeedIx(filter, limit);
  const balance = useBalanceToken();
  const { data: scan } = useScan();
  const loading = useHistoryPending(ixq);
  return useMemo(() => {
    if (mode === "ix") return { events: (ixq.data?.rows ?? []).map((r) => feedEvent(r, balance)), total: ixq.data?.total ?? 0, loading };
    const all = scan.feed.filter((e) => filter === "all" || (filter === "credits" ? e.tile?.kind === "credit" : e.tile?.kind === "statement"));
    return { events: all.slice(0, limit), total: all.length, loading };
  }, [mode, ixq.data, balance, scan.feed, filter, limit, loading]);
}

// ---- credit detail -------------------------------------------------------------------------------------------

export interface CreditSale {
  price: bigint;
  paid?: bigint; // what the engine paid
  paidBalance?: bigint; // a $BALANCE purchase: the seller's payout plus the royalty, in the token it was paid in
  paidBalanceToken?: string;
  toArtist: bigint;
  toOperator: bigint;
  toBuyback?: bigint;
  toPot?: bigint;
  approx: boolean; // split computed with the current creditCostToPotBps (chain mode, state of the sale block unreadable)
}

export interface CreditDetail {
  loading: boolean; // the sources have not answered: state, facts and history are not known yet
  evts: CreditEvt[]; // oldest first
  last?: CreditEvt;
  known: boolean;
  inPile: boolean;
  c?: PileCredit;
  state: "held" | "composed" | "sold" | "other";
  cost?: bigint;
  acquiredAt?: number;
  how?: string;
  tx?: string;
  owner?: string;
  score?: bigint;
  mask?: number;
  sale?: CreditSale;
}

export function useCreditDetail(id: number): CreditDetail {
  const mode = useIxMode();
  const { data: scan, ready: scanReady } = useScan();
  const { data: pile, loading: pileLoading } = usePile();
  const { data: snap } = useSnapshot();
  const { data: c } = useCredit(id);
  const { data: owner } = useCreditOwner(id);
  const { data: scores } = useScores([BigInt(id)]);
  const { data: traits } = useCreditTraits([BigInt(id)]);
  const rowQ = useCreditRow(id);
  const row = rowQ.data ?? undefined;
  const histQ = useCreditHistoryIx(id);
  const hist = histQ.data;
  const rowPending = useHistoryPending(rowQ);
  const histPending = useHistoryPending(histQ);
  const chainEvts = scan.credits[id];
  const evts = (mode === "ix" ? hist : chainEvts) ?? [];
  const last = evts[evts.length - 1];
  const lastBought = [...evts].reverse().find((e): e is Extract<CreditEvt, { t: "bought" }> => e.t === "bought");
  const inPile = mode === "ix" ? (row ? row.state === "held" : false) : c?.inPile ?? false;
  const { data: boughtTs } = useBlockTs(mode === "chain" && !inPile ? lastBought?.block : undefined);
  const saleEvt = last?.t === "sold" ? last : undefined;
  const { data: thenBps, isLoading: bpsLoading } = useCreditCostToPotAt(mode === "chain" ? saleEvt?.block : undefined);

  let sale: CreditSale | undefined;
  if (mode === "ix" && row?.state === "sold")
    sale = { price: row.salePrice ?? 0n, paid: row.costBasis ?? undefined,
      paidBalance: row.acquiredHow === "balance_bid" && row.balancePaid != null ? row.balancePaid + (row.royalty ?? 0n) : undefined,
      paidBalanceToken: row.balancePaidToken ?? undefined, toArtist: row.toArtist ?? 0n, toOperator: row.toOperator ?? 0n, toBuyback: row.toBuyback ?? undefined, toPot: row.toPot ?? undefined, approx: false };
  else if (mode === "chain" && saleEvt) {
    // Core.sellCreditTo: after the artist and operator cuts, min(cost * creditCostToPotBps / 10000, rest) goes to the pot
    const potBps = thenBps ?? (bpsLoading ? undefined : snap?.creditCostToPotBps);
    const rest = saleEvt.price - saleEvt.toArtist - saleEvt.toOperator;
    const paid = lastBought?.cost;
    const toPot = paid != null && potBps != null ? (paid * BigInt(potBps)) / 10000n : undefined;
    const toBuyback = toPot != null ? rest - (toPot < rest ? toPot : rest) : undefined;
    sale = { price: saleEvt.price, paid, toArtist: saleEvt.toArtist, toOperator: saleEvt.toOperator, toBuyback, toPot: toBuyback != null ? rest - toBuyback : undefined, approx: thenBps == null };
  }

  const ixState = row?.state === "composed" ? "composed" : row?.state === "sold" ? "sold" : "other";
  const chainState = last?.t === "composed" ? "composed" : last?.t === "sold" ? "sold" : "other";
  // loading: the record or its history has not answered. In chain mode the facts come from the scan and, for a pile
  // credit only, the live credit read (a credit the engine never held has none to wait for)
  const chainPending = mode === "chain" && (!scanReady || pileLoading || (pile.some((p) => p.id === id) && c === undefined));
  const loading = (mode !== "chain" && (rowPending || histPending)) || chainPending || mode === "checking" || !snap;
  return {
    loading,
    evts,
    last,
    known: mode === "ix" ? (row ? row.state !== "outside" : false) : inPile || evts.length > 0,
    inPile,
    c,
    state: inPile ? "held" : mode === "ix" ? ixState : chainState,
    cost: mode === "ix" ? row?.costBasis ?? undefined : inPile ? c?.cost : lastBought?.cost,
    acquiredAt: mode === "ix" ? (row?.acquiredAt != null ? Number(row.acquiredAt) : undefined) : inPile ? c?.acquiredAt : boughtTs,
    how: mode === "ix" ? (row?.acquiredHow ? howLabel(row.acquiredHow) : undefined) : lastBought?.how,
    tx: mode === "ix" ? row?.acquiredTx ?? undefined : lastBought?.tx,
    owner: owner ?? undefined,
    score: scores?.[id.toString()],
    mask: traits?.[id.toString()]?.mask,
    sale,
  };
}

// ---- statements ----------------------------------------------------------------------------------------------

export interface StatementIndexItem {
  id: number;
  format?: number;
  formatName?: string | null;
  cost?: bigint;
  rating?: bigint;
  composedAt?: number; // unix seconds, indexer mode
  block?: bigint; // compose block, chain mode
  soldPrice?: bigint;
  redeemed: boolean;
}

/** Statements with a record outside the held set: composed, sold or redeemed. */
export function useStatementIndex(): { data: StatementIndexItem[]; loading: boolean } {
  const mode = useIxMode();
  const rows = useStatementRowsIx();
  const { data: scan } = useScan();
  const loading = useHistoryPending(rows);
  return {
    loading,
    data: useMemo(() => {
      if (mode === "ix")
        return (rows.data ?? []).map((r) => ({ id: r.id, format: r.format, formatName: r.formatName, cost: r.cost, rating: r.rating, composedAt: r.composedAt, soldPrice: r.state === "sold" ? r.salePrice : undefined, redeemed: r.state === "redeemed" }));
      return Object.entries(scan.statements).map(([k, r]) => ({
        id: Number(k),
        format: r.restyled.at(-1)?.format ?? r.composed?.format,
        cost: r.composed?.cost,
        block: r.composed?.block,
        soldPrice: r.sold?.price,
        redeemed: Boolean(r.redeemed),
      }));
    }, [mode, rows.data, scan.statements]),
  };
}

export type StatementView = StatementRecord & { owner?: string | null; rating?: bigint; format?: number; formatName?: string | null };

/** One statement's record. undefined: not composed by the engine, or still loading (isPending). */
export function useStatementView(id: number): { rec?: StatementView; owner?: string; isPending: boolean } {
  const mode = useIxMode();
  const ixq = useStatementDetailIx(id);
  const { data: scan } = useScan();
  const pending = useHistoryPending(ixq);
  const { data: owner } = useStatementOwner(id);
  const chainRec = scan.statements[id];
  const d: StatementDetail | null | undefined = ixq.data;
  const rec: StatementView | undefined =
    mode === "ix" ? (d ?? undefined) : chainRec ? { ...chainRec, format: chainRec.restyled.at(-1)?.format ?? chainRec.composed?.format } : undefined;
  return { rec, owner: owner ?? undefined, isPending: pending };
}

// ---- credits market report ----------------------------------------------------------------------------------

export interface MarketReport {
  bands: BandReport[];
  loading: boolean;
  basis: "week" | "latest"; // week: every purchase of the 14 days (indexer); latest: the newest CHAIN_SALES (chain mode)
}

const CHAIN_SALES = 200; // chain mode: newest purchases scored live (scores are a multicall per credit)
const BLOCKS_PER_WEEK = BigInt(WEEK_S / 12);

/** What the engine paid for Credits by rating band (lib/market-report.ts): purchases at the eth bid or from a listing,
 * the last 7 days against the 7 before. Indexer mode counts every purchase in SQL; chain mode reads the newest
 * CHAIN_SALES of the scan with their scores. */
export function useMarketReport(): MarketReport {
  const mode = useIxMode();
  const { data: head } = useHead();
  const ixq = useMarketIx(mode === "ix" ? head?.ts : undefined);
  const { data: scan, ready } = useScan();
  const chainSales = useMemo(() => {
    if (mode !== "chain" || !head) return [];
    const from = head.n - 2n * BLOCKS_PER_WEEK;
    const out: { id: number; cost: bigint; block: bigint }[] = [];
    for (const [id, evts] of Object.entries(scan.credits))
      for (const e of evts) if (e.t === "bought" && (e.how === "eth bid" || e.how === "listing") && e.block != null && e.block >= from) out.push({ id: Number(id), cost: e.cost, block: e.block });
    return out.sort((a, b) => (a.block > b.block ? -1 : 1)).slice(0, CHAIN_SALES);
  }, [mode, head, scan.credits]);
  const { data: scores, loading: scoresLoading } = useScores(chainSales.map((s) => BigInt(s.id)));
  const pending = useHistoryPending(ixq);
  return useMemo(() => {
    const week = BANDS.map(() => new Map<bigint, number>());
    const prior = BANDS.map(() => new Map<bigint, number>());
    if (mode === "ix") {
      for (const r of ixq.data ?? []) (r.period === 0 ? week : prior)[r.band]?.set(r.bucket, r.n);
      return { bands: BANDS.map((b) => bandReport(b, week[b.key], prior[b.key])), loading: pending, basis: "week" };
    }
    // the indexer check: the source is not known yet, so the report waits (and keeps the usual basis)
    if (mode === "checking") return { bands: BANDS.map((b) => bandReport(b, week[b.key], prior[b.key])), loading: true, basis: "week" };
    // chain mode: exact prices, put through the same report by bucketing each sale on its own
    const edge = (head?.n ?? 0n) - BLOCKS_PER_WEEK;
    const add = (m: Map<bigint, number>, cost: bigint) => m.set(cost / BUCKET_WEI, (m.get(cost / BUCKET_WEI) ?? 0) + 1);
    for (const s of chainSales) {
      const score = scores?.[String(s.id)];
      if (score == null) continue;
      add((s.block >= edge ? week : prior)[bandOf(score).key], s.cost);
    }
    return { bands: BANDS.map((b) => bandReport(b, week[b.key], prior[b.key])), loading: pending || !ready || scoresLoading, basis: "latest" };
  }, [mode, ixq.data, pending, head, chainSales, scores, ready, scoresLoading]);
}

/** The market's cheapest ask per rating band: the keeper's market view (its best OpenSea asks by price per point and
 * the CreditStrategy rows, each with its score) through the shared /api/listings poll. `available` is false while the
 * site has no keeper view. */
export function useMarketAsks(): { asks: Map<number, bigint>; loading: boolean; available: boolean } {
  const { data, isPending, isError } = useMarketView();
  return useMemo(() => {
    const view = data?.available ? data.view : undefined;
    const now = Math.floor(Date.now() / 1000);
    const asks = [
      ...(view?.rows ?? []).filter((r) => r.endTime === 0 || r.endTime > now),
      ...(view?.strategy.rows ?? []),
    ].map((r) => ({ price: BigInt(r.price), score: r.score == null ? null : BigInt(r.score) }));
    return { asks: cheapestByBand(asks), loading: engineDeployed && isPending && !isError, available: Boolean(view) };
  }, [data, isPending, isError]);
}
