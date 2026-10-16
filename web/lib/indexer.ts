"use client";

// Reads from the indexer (docs/INDEXER.md): history, lists and slow-moving state, over @ponder/client SQL with the
// tables of ./indexer-schema. Every hook is a react-query query under the "ix" key; IndexerSync invalidates that key
// when the indexer reports a new engine block.
//
// One app-wide mode decides the source of every indexer read (owner decision 133): "ix" while the indexer is
// configured, reachable, within IX_MAX_BEHIND blocks of the chain head and consistent with the Core, "chain" otherwise
// (each hook's on-chain path then runs), "checking" until the first health result. The queries here run only in "ix"
// mode and the on-chain paths only in "chain" mode, so a healthy indexer means no log scan or per-row block read.

import { useSyncExternalStore } from "react";
import { useQuery, keepPreviousData } from "@tanstack/react-query";
import { createClient, and, asc, count, desc, eq, gte, inArray, min, ne, or, sql } from "@ponder/client";
import { getTableColumns } from "drizzle-orm";
import { formatUnits } from "viem";
import { engineDeployed, indexerUrl, STATEMENT_SIZE } from "./config";
import { eth, formatBalance, type BalanceTokenInfo } from "./format";
import type { CreditEvt, FeedEvent, StatementRecord } from "./events";
import * as schema from "./indexer-schema";
import type { AcquiredHow } from "./indexer-schema";

const { activity, anchorMove, credit, engine, log, statement, statementCredit, statementFormat, stats, statsHourly, strategyListing } = schema;

export const ix = indexerUrl ? createClient(`${indexerUrl}/sql`, { schema }) : undefined;
type Db = NonNullable<typeof ix>["db"];

export const IX_MAX_BEHIND = 5; // blocks the indexer may trail the chain head

export type IxMode = "checking" | "ix" | "chain";
let mode: IxMode = ix ? "checking" : "chain";
const subs = new Set<() => void>();
export const getIxMode = () => mode;
export function setIxMode(m: IxMode) {
  if (m === mode) return;
  mode = m;
  subs.forEach((f) => f());
}
const subscribe = (f: () => void) => {
  subs.add(f);
  return () => void subs.delete(f);
};
/** The source of indexer reads. The server render and the first client render are "checking" (or "chain" without an indexer). */
export const useIxMode = (): IxMode => useSyncExternalStore(subscribe, getIxMode, () => (ix ? "checking" : "chain"));

/** Health of the indexer: its latest indexed block and the number of credits it holds in the pile. */
export async function fetchIxHealth() {
  const [status, held] = await Promise.all([
    ix!.getStatus(),
    ix!.db.select({ n: count() }).from(credit).where(eq(credit.state, "held")),
  ]);
  const block = Math.max(0, ...Object.values(status).map((c) => c.block.number));
  return { block, held: Number(held[0]?.n ?? 0) };
}

function useIx<T>(key: unknown[], fn: (db: Db) => Promise<T>, opts: { enabled?: boolean } = {}) {
  const on = useIxMode() === "ix";
  return useQuery<T>({
    queryKey: ["ix", ...key],
    enabled: on && engineDeployed && (opts.enabled ?? true),
    queryFn: () => fn(ix!.db),
    staleTime: 60_000,
    retry: 1,
    placeholderData: keepPreviousData,
  });
}

const num = (v: bigint | null | undefined) => (v == null ? undefined : Number(v));
const lc = (a: string) => a.toLowerCase() as `0x${string}`;
const creditCols = (() => {
  const { tokenUri: _t, ...rest } = getTableColumns(credit);
  return rest;
})();
const statementCols = (() => {
  const { tokenUri: _t, ...rest } = getTableColumns(statement);
  return rest;
})();

// ---- engine, stats ---------------------------------------------------------------------------------------------

/** Artist, payee and the credit sale split, which change only through setters. */
export function useEngine() {
  return useIx(["engine"], async (db) => (await db.select().from(engine).limit(1))[0] ?? null);
}

export interface Stats {
  ccBurned: number; // Core buyback burns plus swap fee burns
  artistReceived: number; // eth
  payeeReceived: number; // eth, the operator cut of sales plus the pushed fee share
  composed: number;
  creditsAcquired: number; // every credit the engine took in: eth bid, balance bid, listing, adopted
}

export function useStatsIx() {
  return useIx(["stats"], async (db): Promise<Stats> => {
    const r = (await db.select().from(stats).limit(1))[0];
    const eth18 = (v?: bigint) => Number(formatUnits(v ?? 0n, 18));
    return {
      ccBurned: eth18(r?.ccBurned),
      artistReceived: eth18(r?.toArtist),
      payeeReceived: eth18((r?.toOperator ?? 0n) + (r?.toPayee ?? 0n)),
      composed: Number(r?.composed ?? 0n),
      creditsAcquired: Number(r?.creditsBought ?? 0n),
    };
  });
}

/**
 * Credits the engine bought per hour over the last 24 hourly buckets, from stats_hourly (adopted credits are not
 * buys). `headTs` is chain time; the window ends at the current bucket and starts at the earlier of 23 bucket
 * starts back and the first bucket, never shorter than one hour.
 */
export function useBuyRateIx(headTs: number | undefined) {
  const hour = headTs == null ? undefined : Math.floor(headTs / 3600);
  const q = useIx(
    ["buy-rate", hour],
    async (db) => {
      const rows = await db
        .select({ bought: statsHourly.creditsBought, adopted: statsHourly.creditsAdopted })
        .from(statsHourly)
        .where(gte(statsHourly.hour, BigInt(hour! - 23)));
      const first = (await db.select({ h: min(statsHourly.hour) }).from(statsHourly))[0]?.h;
      return { count: rows.reduce((n, r) => n + Number(r.bought - r.adopted), 0), first: first == null ? undefined : Number(first) * 3600 };
    },
    { enabled: hour != null },
  );
  const d = q.data;
  const perHour =
    d == null || headTs == null
      ? undefined
      : d.first == null
        ? 0
        : d.count / (Math.min(headTs - (hour! - 23) * 3600, Math.max(3600, headTs - d.first)) / 3600);
  return { perHour };
}

/** Credits the CreditStrategy lists, cheapest first, with the credit score when the credit table holds the id. */
export async function fetchStrategyListings() {
  const rows = await ix!.db
    .select({ id: strategyListing.id, price: strategyListing.listPrice, score: credit.score })
    .from(strategyListing)
    .leftJoin(credit, eq(credit.id, strategyListing.id))
    .where(eq(strategyListing.active, true))
    .orderBy(asc(strategyListing.listPrice));
  return rows.map((r) => ({ id: r.id, price: r.price, score: r.score }));
}

/** Scores of credits by id from the credit table; ids the table lacks are absent. */
// The SQL client sends each query in a GET url; a long id list exceeds the server's header limit (431, reported by the
// browser as a CORS failure), so id lists are queried in chunks of ID_CHUNK.
const ID_CHUNK = 200;
async function chunked<I, R>(ids: I[], q: (part: I[]) => Promise<R[]>): Promise<R[]> {
  const parts: I[][] = [];
  for (let i = 0; i < ids.length; i += ID_CHUNK) parts.push(ids.slice(i, i + ID_CHUNK));
  return (await Promise.all(parts.map(q))).flat();
}

export async function fetchScoresIx(ids: bigint[]): Promise<Map<bigint, bigint>> {
  if (!ids.length) return new Map();
  const rows = await chunked(ids, (part) => ix!.db.select({ id: credit.id, score: credit.score }).from(credit).where(inArray(credit.id, part)));
  return new Map(rows.map((r) => [r.id, r.score]));
}

// ---- credits ---------------------------------------------------------------------------------------------------

export const howLabel = (h: AcquiredHow | null | undefined, balanceSymbol = "$BALANCE"): string =>
  h == null ? "—" : { eth_bid: "eth bid", balance_bid: `${balanceSymbol} bid`, listing: "listing", adopted: "adopted", swap_in: "swapped in" }[h];

export interface HeldCredit {
  id: number;
  cost: bigint; // wei the engine paid
  acquiredAt: number;
  score: bigint;
  mask: number;
  how: AcquiredHow | null;
}

/** Credits the engine holds, oldest first (compose order). */
export function useHeldCredits() {
  return useIx(["held-credits"], async (db): Promise<HeldCredit[]> => {
    const rows = await db
      .select({ id: credit.id, cost: credit.costBasis, at: credit.acquiredAt, score: credit.score, mask: credit.mask, how: credit.acquiredHow })
      .from(credit)
      .where(eq(credit.state, "held"))
      .orderBy(asc(credit.pileOrder));
    return rows.map((r) => ({ id: Number(r.id), cost: r.cost ?? 0n, acquiredAt: Number(r.at ?? 0n), score: r.score, mask: r.mask, how: r.how }));
  });
}

export type CreditRow = Awaited<ReturnType<typeof fetchCredit>>;

async function fetchCredit(db: Db, id: number) {
  const r = (await db.select(creditCols).from(credit).where(eq(credit.id, BigInt(id))).limit(1))[0];
  return r ?? null;
}

/** One credit's facts. null: the id is not in the credit table. */
export function useCreditRow(id: number, enabled = true) {
  return useIx(["credit", id], (db) => fetchCredit(db, id), { enabled });
}

/** Credits owned by a wallet with their scores, lowest id first. */
export function useWalletCreditsIx(address?: string) {
  return useIx(
    ["wallet-credits", address?.toLowerCase()],
    async (db) => {
      const rows = await db
        .select({ id: credit.id, score: credit.score, mask: credit.mask })
        .from(credit)
        .where(eq(credit.owner, lc(address!)))
        .orderBy(asc(credit.id));
      return rows.map((r) => ({ id: Number(r.id), score: r.score, mask: r.mask }));
    },
    { enabled: Boolean(address) },
  );
}

/** A credit's steps, oldest first: bought, swapped, sold, composed. */
export function useCreditHistoryIx(id: number) {
  return useIx(["credit-history", id], async (db): Promise<CreditEvt[]> => {
    const cid = BigInt(id);
    const [rows, composed] = await Promise.all([
      db
        .select({
          kind: activity.kind,
          creditId: activity.creditId,
          other: activity.otherCreditId,
          account: activity.account,
          amount: activity.amount,
          amount2: activity.amount2,
          ts: activity.blockTimestamp,
          tx: activity.txHash,
          adapter: sql<string | null>`${log.args}->>'adapter'`,
        })
        .from(activity)
        .leftJoin(log, eq(log.id, activity.id))
        .where(or(eq(activity.creditId, cid), eq(activity.otherCreditId, cid)))
        .orderBy(asc(activity.blockNumber), asc(activity.logIndex)),
      db
        .select({ sid: statement.id, ts: statement.composedAt, tx: statement.composeTx })
        .from(credit)
        .innerJoin(statement, eq(statement.id, credit.statementId))
        .where(eq(credit.id, cid))
        .limit(1),
    ]);
    const out: CreditEvt[] = [];
    for (const r of rows) {
      const base = { ts: Number(r.ts), tx: r.tx };
      if (r.kind === "credit_bought")
        out.push(
          r.amount2 && r.amount2 > 0n
            ? { t: "bought", how: "$BALANCE bid", cost: r.amount ?? 0n, from: r.account ?? undefined, ...base }
            : { t: "bought", how: "eth bid", cost: r.amount ?? 0n, from: r.account ?? undefined, ...base },
        );
      else if (r.kind === "listing_bought")
        out.push({ t: "bought", how: "listing", cost: r.amount ?? 0n, from: r.account ?? undefined, paid: r.amount2 ?? undefined, adapter: r.adapter ?? undefined, ...base });
      else if (r.kind === "credit_adopted") out.push({ t: "bought", how: "adopted", cost: r.amount ?? 0n, ...base });
      else if (r.kind === "credit_sold") out.push({ t: "sold", buyer: r.account ?? "", price: r.amount ?? 0n, toArtist: 0n, toOperator: 0n, ...base });
      else if (r.kind === "credit_swapped") {
        const dir = r.creditId === cid ? "in" : "out";
        out.push({ t: "swapped", dir, other: Number(dir === "in" ? r.other : r.creditId), caller: r.account ?? "", fee: r.amount2 ?? 0n, ...base });
      }
    }
    const c = composed[0];
    if (c) out.push({ t: "composed", sid: Number(c.sid), ts: Number(c.ts ?? 0n), tx: c.tx ?? "0x" });
    return out.sort((a, b) => (a.ts ?? 0) - (b.ts ?? 0));
  });
}

// ---- statements ------------------------------------------------------------------------------------------------

export interface StatementRow {
  id: number;
  state: schema.StatementState;
  owner: string | null;
  composedAt?: number;
  composer: string | null;
  mode: "default" | "chosen" | null;
  cost?: bigint;
  rating?: bigint; // ten-thousandths of a point
  format?: number; // current format
  formatName: string | null;
  salePrice?: bigint;
}

/** Statements the Core composed, newest first. */
export function useStatementRowsIx() {
  return useIx(["statements"], async (db): Promise<StatementRow[]> => {
    const rows = await db.select(statementCols).from(statement).where(ne(statement.state, "outside")).orderBy(desc(statement.id));
    return rows.map((r) => ({
      id: Number(r.id),
      state: r.state,
      owner: r.owner,
      composedAt: num(r.composedAt),
      composer: r.composer,
      mode: r.mode,
      cost: r.cost ?? undefined,
      rating: r.rating ?? undefined,
      format: r.format ?? undefined,
      formatName: r.formatName,
      salePrice: r.salePrice ?? undefined,
    }));
  });
}

/** The statement record of the scan plus the facts the indexer stores. */
export type StatementDetail = StatementRecord & {
  state: schema.StatementState;
  owner: string | null;
  rating?: bigint; // ten-thousandths of a point
  format?: number; // current format
  formatName: string | null;
};

/** One statement's facts and history. null: the id is not a statement the Core composed. */
export function useStatementDetailIx(id: number, enabled = true) {
  return useIx(["statement", id], async (db): Promise<StatementDetail | null> => {
    const sid = BigInt(id);
    const [rows, credits, formats, anchors, ends] = await Promise.all([
      db.select(statementCols).from(statement).where(eq(statement.id, sid)).limit(1),
      db.select({ id: statementCredit.creditId }).from(statementCredit).where(eq(statementCredit.statementId, sid)).orderBy(asc(statementCredit.position)),
      db.select().from(statementFormat).where(eq(statementFormat.statementId, sid)).orderBy(asc(statementFormat.blockTimestamp), asc(statementFormat.logIndex)),
      db.select().from(anchorMove).where(eq(anchorMove.statementId, sid)).orderBy(asc(anchorMove.blockTimestamp), asc(anchorMove.logIndex)),
      db
        .select({ kind: activity.kind, ts: activity.blockTimestamp, tx: activity.txHash })
        .from(activity)
        .where(and(eq(activity.statementId, sid), inArray(activity.kind, ["statement_sold", "redeemed"])))
        .orderBy(desc(activity.blockNumber), desc(activity.logIndex)),
    ]);
    const r = rows[0];
    if (!r || r.state === "outside") return null;
    const end = (kind: "statement_sold" | "redeemed") => ends.find((e) => e.kind === kind);
    const sold = end("statement_sold");
    const redeemed = end("redeemed");
    return {
      sid: id,
      state: r.state,
      owner: r.owner,
      rating: r.rating ?? undefined,
      format: r.format ?? undefined,
      formatName: r.formatName,
      composed:
        r.composedAt == null
          ? undefined
          : {
              ids: credits.map((c) => Number(c.id)),
              format: formats[0]?.from ?? r.format ?? 0,
              cost: r.cost ?? 0n,
              caller: r.composer ?? "",
              mode: r.mode ?? undefined,
              ts: Number(r.composedAt),
              tx: r.composeTx ?? "0x",
            },
      restyled: formats.map((f) => ({ format: f.to, caller: f.caller, ts: Number(f.blockTimestamp), tx: f.txHash })),
      anchor: anchors.map((m) => ({ saleBps: m.saleBps, anchorBps: Number(m.anchorBps), ts: Number(m.blockTimestamp), tx: m.txHash })),
      sold:
        r.state === "sold" || sold
          ? {
              buyer: r.buyer ?? "",
              price: r.salePrice ?? 0n,
              toBuyback: r.toBuyback ?? 0n,
              toArtist: r.toArtist ?? 0n,
              toOperator: r.toOperator ?? 0n,
              toPot: r.toPot ?? 0n,
              ts: Number(sold?.ts ?? 0n),
              tx: sold?.tx ?? "0x",
            }
          : undefined,
      redeemed: r.state === "redeemed" || redeemed ? { received: r.redeemedReceived ?? 0n, ts: Number(redeemed?.ts ?? 0n), tx: redeemed?.tx ?? "0x" } : undefined,
    };
  }, { enabled });
}

// ---- feed ------------------------------------------------------------------------------------------------------

export type FeedFilter = "all" | "credits" | "statements";

const CREDIT_KINDS: schema.ActivityKind[] = ["credit_bought", "listing_bought", "credit_adopted", "credit_swapped", "credit_sold"];
const STATEMENT_KINDS: schema.ActivityKind[] = ["composed", "restyled", "statement_sold", "redeemed"];
const kindsOf = (f: FeedFilter) => (f === "credits" ? CREDIT_KINDS : f === "statements" ? STATEMENT_KINDS : [...CREDIT_KINDS, ...STATEMENT_KINDS]);

/** Ledger rows, newest first, with the statement's rating. total counts all rows of the filter. */
export function useFeedIx(filter: FeedFilter, limit: number) {
  return useIx(["feed", filter, limit], async (db) => {
    const kinds = kindsOf(filter);
    const [rows, total] = await Promise.all([
      db
        .select({
          id: activity.id,
          kind: activity.kind,
          creditId: activity.creditId,
          other: activity.otherCreditId,
          statementId: activity.statementId,
          account: activity.account,
          amount: activity.amount,
          amount2: activity.amount2,
          ts: activity.blockTimestamp,
          tx: activity.txHash,
          rating: statement.rating,
          mode: statement.mode,
          composedFormat: sql<string | null>`${log.args}->>'format'`,
          restyledTo: statementFormat.to,
        })
        .from(activity)
        .leftJoin(statement, eq(statement.id, activity.statementId))
        .leftJoin(log, and(eq(log.id, activity.id), eq(activity.kind, "composed")))
        .leftJoin(statementFormat, eq(statementFormat.id, activity.id))
        .where(inArray(activity.kind, kinds))
        .orderBy(desc(activity.blockNumber), desc(activity.logIndex))
        .limit(limit),
      db.select({ n: count() }).from(activity).where(inArray(activity.kind, kinds)),
    ]);
    return { rows, total: Number(total[0]?.n ?? 0) };
  });
}

type FeedRow = NonNullable<ReturnType<typeof useFeedIx>["data"]>["rows"][number];

const stmtLink = (sid: number) => ({ text: `statement ${sid}`, href: `/statements/${sid}` });
const creditLink = (id: number) => ({ text: `credit #${id}`, href: `/credits/${id}` });

/** A ledger row as the feed shows it. `balance` formats $BALANCE amounts (undefined: raw units). */
export function feedEvent(r: FeedRow, balance?: BalanceTokenInfo): FeedEvent {
  const cid = r.creditId == null ? undefined : Number(r.creditId);
  const sid = r.statementId == null ? undefined : Number(r.statementId);
  const base = { key: r.id, ts: Number(r.ts), tx: r.tx.slice(0, 6), txHash: r.tx };
  const credit = {};
  const amount = r.amount ?? 0n;
  switch (r.kind) {
    case "credit_bought":
      return {
        ...base,
        ...credit,
        kind: "credit",
        label: "credit acquired",
        detail: "",
        eth: r.amount2 && r.amount2 > 0n ? formatBalance(r.amount2, balance) : eth(amount),
        link: creditLink(cid!),
        tile: { kind: "credit", id: cid! },
      };
    case "listing_bought":
    case "credit_adopted":
      return { ...base, ...credit, kind: "credit", label: "credit acquired", detail: "", eth: eth(amount), link: creditLink(cid!), tile: { kind: "credit", id: cid! } };
    case "credit_swapped":
      return {
        ...base,
        ...credit,
        kind: "credit",
        label: "credit swapped",
        detail: `credit #${cid} in for #${r.other} · fee ${eth(r.amount2 ?? 0n)} CC · by`,
        addr: r.account ?? undefined,
        link: creditLink(cid!),
        tile: { kind: "credit", id: cid! },
      };
    case "credit_sold":
      return {
        ...base,
        ...credit,
        kind: "sold",
        label: "credit sold",
        detail: `credit #${cid} bought from the credit sale by`,
        eth: eth(amount),
        addr: r.account ?? undefined,
        tile: { kind: "credit", id: cid! },
      };
    case "composed": {
      const format = Number(r.composedFormat ?? 0);
      const price = r.amount2 ?? 0n;
      return {
        ...base,
        kind: "composed",
        label: r.mode === "chosen" ? "composed · chosen" : "statement composed",
        link: stmtLink(sid!),
        detail: `${price > 0n ? `· listed at ${eth(price)} eth ` : ""}· format ${format} · cost ${eth(amount)} eth`,
        tile: { kind: "statement", id: sid! },
        rating: r.rating ?? undefined,
        composed: { format, credits: STATEMENT_SIZE, cost: amount },
      };
    }
    case "restyled":
      return {
        ...base,
        kind: "composed",
        label: "statement restyled",
        link: stmtLink(sid!),
        detail: `· format ${r.restyledTo} · by`,
        addr: r.account ?? undefined,
        tile: { kind: "statement", id: sid! },
      };
    case "statement_sold":
      return {
        ...base,
        kind: "sold",
        label: "statement sold",
        link: stmtLink(sid!),
        detail: `· ${eth(r.amount2 ?? 0n)} eth to buyback · bought by`,
        eth: eth(amount),
        addr: r.account ?? undefined,
        tile: { kind: "statement", id: sid! },
        rating: r.rating ?? undefined,
      };
    default:
      return {
        ...base,
        kind: "redeemed",
        label: "statement redeemed",
        link: stmtLink(sid!),
        detail: `· received ${formatBalance(amount, balance)}`,
        tile: { kind: "statement", id: sid! },
        rating: r.rating ?? undefined,
      };
  }
}

// ---- token art -------------------------------------------------------------------------------------------------

/** tokenURI data of credits or statements as the indexer stores it; a missing id or a null tokenUri is absent from the map. */
export async function fetchTokenUris(kind: "credit" | "statement", ids: number[]): Promise<Map<number, string>> {
  if (!ix) return new Map();
  const t = kind === "credit" ? credit : statement;
  const rows = await chunked(ids.map(BigInt), (part) => ix!.db.select({ id: t.id, uri: t.tokenUri }).from(t).where(inArray(t.id, part)));
  return new Map(rows.flatMap((r) => (r.uri ? [[Number(r.id), r.uri] as [number, string]] : [])));
}

// ---- scores, plates, owners ------------------------------------------------------------------------------------

/** Score and plate mask of credits by id; ids the indexer lacks are absent. */
export function useCreditTraitsIx(ids: number[]) {
  return useIx(
    ["credit-traits", ids.join(",")],
    async (db) => {
      const rows = await chunked(ids.map(BigInt), (part) =>
        db
          .select({ id: credit.id, score: credit.score, mask: credit.mask, active: credit.active, occupied: credit.occupied, eights: credit.eights, band: credit.band })
          .from(credit)
          .where(inArray(credit.id, part)),
      );
      return Object.fromEntries(rows.map((r) => [r.id.toString(), r]));
    },
    { enabled: ids.length > 0 },
  );
}
