"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicClient, useBlockNumber } from "wagmi";
import { formatUnits, zeroAddress, type Address } from "viem";
import { addresses, deployBlock, isLive, poolReady, ethUsdFeed } from "./config";
import {
  coreLensAbi,
  coreEventsAbi,
  stateViewAbi,
  quoterAbi,
  chainlinkAbi,
  transferEventAbi,
} from "./abis";
import { V4, poolId, poolKey, ccPerEthFromSqrt } from "./v4";

export type FeedKind = "fee" | "credit" | "composed" | "listed" | "sold" | "burn";

export interface FeedEvent {
  key: string;
  ts: number; // unix seconds
  kind: FeedKind;
  detail: string;
  eth?: string; // pre-formatted for the eth column
  tx: string; // short display label
  txHash?: string; // full hash, present on live rows, drives the evm.now link
  tile?: { kind: "credit" | "statement"; id: number };
  addr?: string; // an address in the detail (e.g. the statement buyer), ENS-ified
}

export interface Stats {
  creditsBought: number;
  statements: number;
  ethIntoCredits: number;
  ccBurned: number;
}

export const STATEMENT_SIZE = 80; // credits composed into one statement

export interface Market {
  live: boolean;
  ccPerEth: number; // tokens per 1 eth
  nextCreditPaid: bigint; // wei toward the next credit
  bid: bigint; // wei the engine pays per credit (rate)
  creditsReady: number; // credits in the pile toward the next statement
  balances?: { cc: bigint; engine: bigint; pool: bigint };
}

// ---- sample data (engine not deployed) -------------------------------------

const SAMPLE_BID = 7100000000000000n; // 0.0071 eth

function sampleFeed(now: number): FeedEvent[] {
  // one rolling window mirroring a live engine: fees flush in, credits get
  // bought at the bid, 80 compose into a statement, statements list and sell,
  // proceeds buy and burn the coin.
  const rows: Array<Omit<FeedEvent, "ts" | "key"> & { back: number }> = [
    { back: 2, kind: "fee", detail: "swap fee to engine", eth: "0.0345", tx: "0x8e1f" },
    { back: 3, kind: "credit", detail: "bought credit #48213 → statement 213", eth: "0.0071", tx: "0x2c94", tile: { kind: "credit", id: 48213 } },
    { back: 3, kind: "credit", detail: "bought credit #48207 → statement 213", eth: "0.0070", tx: "0x2c94", tile: { kind: "credit", id: 48207 } },
    { back: 3, kind: "credit", detail: "bought credit #48204 → statement 213", eth: "0.0072", tx: "0x2c94", tile: { kind: "credit", id: 48204 } },
    { back: 20, kind: "fee", detail: "swap fee to engine", eth: "0.0052", tx: "0x61ad" },
    { back: 31, kind: "composed", detail: "statement 212 · 80 credits · cost 0.562 eth", tx: "0x0f37", tile: { kind: "statement", id: 212 } },
    { back: 31, kind: "listed", detail: "statement 212 for sale, price falling", eth: "2.10", tx: "0x0f37" },
    { back: 59, kind: "credit", detail: "bought credit #48190 → statement 213", eth: "0.0069", tx: "0x9b02", tile: { kind: "credit", id: 48190 } },
    { back: 69, kind: "fee", detail: "swap fee to engine", eth: "0.0255", tx: "0x44c8" },
    { back: 68, kind: "credit", detail: "bought credit #48188 → statement 213", eth: "0.0071", tx: "0x7d5e", tile: { kind: "credit", id: 48188 } },
    { back: 116, kind: "sold", detail: "statement 208 bought by", addr: "0x91ac4df2a1e8b7c3d5f6a9e0b2c4d6e8f0a244de", eth: "1.40", tx: "0x3a90", tile: { kind: "statement", id: 208 } },
    { back: 116, kind: "burn", detail: "burned 310,000 cc", tx: "0x3a90" },
    { back: 115, kind: "credit", detail: "bought credit #48161 → statement 213", eth: "0.0068", tx: "0xe6f1", tile: { kind: "credit", id: 48161 } },
    { back: 179, kind: "fee", detail: "swap fee to engine", eth: "0.0759", tx: "0xb3a4" },
    { back: 178, kind: "credit", detail: "bought credit #48151 → statement 213", eth: "0.0070", tx: "0x5c2d", tile: { kind: "credit", id: 48151 } },
  ];
  return rows.map((r, i) => ({
    key: `${r.tx}-${i}`,
    ts: now - r.back,
    kind: r.kind,
    detail: r.detail,
    eth: r.eth,
    tx: r.tx,
    tile: r.tile,
    addr: r.addr,
  }));
}

const SAMPLE_STATS: Stats = {
  creditsBought: 17017,
  statements: 212,
  ethIntoCredits: 119.4,
  ccBurned: 41820000,
};

const SAMPLE_MARKET: Market = {
  live: false,
  ccPerEth: 2564900,
  nextCreditPaid: 1200000000000000n, // 0.0012 eth
  bid: SAMPLE_BID,
  creditsReady: 56, // 56 of 80 toward the next statement
  balances: { cc: 0n, engine: 0n, pool: 0n },
};

// live mode starts from zeros until the first read lands
const EMPTY_MARKET: Market = {
  live: true,
  ccPerEth: 0,
  nextCreditPaid: 0n,
  bid: 0n,
  creditsReady: 0,
  balances: { cc: 0n, engine: 0n, pool: 0n },
};
const BASE_MARKET = isLive ? EMPTY_MARKET : SAMPLE_MARKET;

// ---- hooks ------------------------------------------------------------------

// ---- event scan --------------------------------------------------------------

export interface StatementSale {
  id: number;
  buyer: string;
  price: bigint; // wei
}

// One pass over the Core logs (and the coin burn transfers) since the deploy
// block: the newest FEED_ROWS rows for the feed, totals over every log.
export interface Scan {
  feed: FeedEvent[];
  stats: Stats; // statements = Composed events; ccBurned = coin burned by the core
  sold: StatementSale[]; // StatementSoldTo
  exited: number[]; // StatementExited sids
}

const FEED_ROWS = 60;
const SAMPLE_SCAN = (now: number): Scan => ({ feed: sampleFeed(now), stats: SAMPLE_STATS, sold: [], exited: [] });
const EMPTY_SCAN: Scan = {
  feed: [],
  stats: { creditsBought: 0, statements: 0, ethIntoCredits: 0, ccBurned: 0 },
  sold: [],
  exited: [],
};

// block number -> timestamp. A mined block's timestamp does not change.
const blockTime = new Map<bigint, number>();

function useScan() {
  const client = usePublicClient();
  const { data: head } = useBlockNumber({ watch: isLive });
  const q = useQuery<Scan>({
    queryKey: ["scan", isLive, head?.toString()],
    enabled: !isLive || Boolean(head),
    refetchInterval: isLive ? 12000 : 30000,
    placeholderData: (prev) => prev,
    queryFn: async () => {
      const now = Math.floor(Date.now() / 1000);
      if (!isLive) return SAMPLE_SCAN(now);
      if (!client || !addresses.core || !head) return EMPTY_SCAN;
      try {
        // bounded scan: from the deploy block, else the last ~50k blocks.
        const from = deployBlock ?? (head > 50000n ? head - 50000n : 0n);
        const [logs, burnLogs] = await Promise.all([
          client.getLogs({
            address: addresses.core as Address,
            events: coreEventsAbi as any,
            fromBlock: from,
            toBlock: head,
          }),
          addresses.cc
            ? client.getLogs({
                address: addresses.cc,
                event: transferEventAbi[0],
                args: { from: addresses.core, to: zeroAddress },
                fromBlock: from,
                toBlock: head,
              })
            : [],
        ]);
        // coin burned per transaction: the Buyback event carries the eth spent only
        const burnedBy = new Map<string, bigint>();
        let burned = 0n;
        for (const b of burnLogs) {
          const v = b.args.value ?? 0n;
          burned += v;
          burnedBy.set(b.transactionHash, (burnedBy.get(b.transactionHash) ?? 0n) + v);
        }

        const stats: Stats = { creditsBought: 0, statements: 0, ethIntoCredits: 0, ccBurned: Number(formatUnits(burned, 18)) };
        const sold: StatementSale[] = [];
        const exited: number[] = [];
        const rows: Array<FeedEvent & { block: bigint }> = [];
        for (const log of logs) {
          const hash = log.transactionHash ?? "0x";
          const block = log.blockNumber ?? head;
          const base = { key: `${hash}-${log.logIndex}`, ts: 0, tx: hash.slice(0, 6), txHash: hash, block };
          const a = (log as any).args ?? {};
          const name = (log as any).eventName as string;
          if (name === "FeesAdded")
            rows.push({ ...base, kind: "fee", detail: "swap fee to engine", eth: fmt(a.amount) });
          else if (name === "CreditBought") {
            stats.creditsBought++;
            stats.ethIntoCredits += Number(formatUnits(a.cost, 18));
            rows.push({ ...base, kind: "credit", detail: `bought credit #${a.id}`, eth: fmt(a.cost), tile: { kind: "credit", id: Number(a.id) } });
          } else if (name === "Composed") {
            stats.statements++;
            rows.push({ ...base, kind: "composed", detail: `statement ${a.sid} · ${STATEMENT_SIZE} credits · cost ${fmt(a.cost)} eth`, tile: { kind: "statement", id: Number(a.sid) } });
          } else if (name === "CreditSold")
            rows.push({ ...base, kind: "sold", detail: `credit #${a.id} bought by`, addr: a.buyer as string, eth: fmt(a.price), tile: { kind: "credit", id: Number(a.id) } });
          else if (name === "StatementSoldTo") {
            sold.push({ id: Number(a.sid), buyer: a.buyer as string, price: a.price });
            rows.push({ ...base, kind: "sold", detail: `statement ${a.sid} bought by`, addr: a.buyer as string, eth: fmt(a.price), tile: { kind: "statement", id: Number(a.sid) } });
          } else if (name === "StatementExited")
            exited.push(Number(a.sid));
          else if (name === "Buyback")
            rows.push({ ...base, kind: "burn", detail: `burned ${Math.floor(Number(formatUnits(burnedBy.get(hash) ?? 0n, 18))).toLocaleString()} cc`, eth: fmt(a.amountIn) });
        }
        // logs arrive oldest first; the feed is newest first
        const feed = rows.reverse().slice(0, FEED_ROWS);
        // exact block timestamps for the shown rows (cached per block)
        await Promise.all(
          [...new Set(feed.map((r) => r.block))]
            .filter((n) => !blockTime.has(n))
            .map(async (n) => blockTime.set(n, Number((await client.getBlock({ blockNumber: n })).timestamp)))
        );
        for (const r of feed) r.ts = blockTime.get(r.block) ?? 0;
        return { feed, stats, sold, exited };
      } catch {
        return EMPTY_SCAN;
      }
    },
  });
  return { ...q, data: q.data ?? (isLive ? EMPTY_SCAN : SAMPLE_SCAN(Math.floor(Date.now() / 1000))) };
}

export const useStats = () => {
  const { data, ...q } = useScan();
  return { ...q, data: data.stats };
};

// Statements that left the engine: sold by StatementSoldTo, redeemed by StatementExited.
export const useStatementHistory = () => {
  const { data, ...q } = useScan();
  return { ...q, data: { total: data.stats.statements, sold: data.sold, exited: data.exited } };
};

export function useMarket() {
  const client = usePublicClient();
  const { data: head } = useBlockNumber({ watch: isLive || poolReady });
  return useQuery<Market>({
    queryKey: ["market", isLive, poolReady, head?.toString()],
    refetchInterval: 15000,
    queryFn: async () => {
      if (!client || (!isLive && !poolReady)) return SAMPLE_MARKET;
      let ccPerEth = BASE_MARKET.ccPerEth;
      let bid = BASE_MARKET.bid;
      let engine = 0n;
      let creditsReady = BASE_MARKET.creditsReady;

      // real cc/eth spot from the v4 pool slot0 (coin deployed).
      if (poolReady && addresses.cc) {
        try {
          const slot0 = (await client.readContract({
            address: V4.stateView,
            abi: stateViewAbi,
            functionName: "getSlot0",
            args: [poolId(addresses.cc)],
          })) as readonly [bigint, number, number, number];
          const spot = ccPerEthFromSqrt(slot0[0]);
          if (spot > 0) ccPerEth = spot;
        } catch {
          /* pool not live yet */
        }
      }

      // engine state (bid, pot) from the lens.
      if (isLive && addresses.coreLens) {
        try {
          const s = (await client.readContract({
            address: addresses.coreLens,
            abi: coreLensAbi,
            functionName: "snapshot",
          })) as any;
          bid = s.ethRate as bigint;
          engine = s.ethPot as bigint;
          creditsReady = Number(s.pileSize as bigint) % STATEMENT_SIZE;
        } catch {
          /* engine not live yet */
        }
      }

      return {
        live: true,
        ccPerEth,
        nextCreditPaid: 0n,
        bid,
        creditsReady,
        balances: { cc: 0n, engine, pool: 0n },
      };
    },
    initialData: BASE_MARKET,
  });
}

// ETH/USD from the Chainlink feed (8 decimals). Cached 60s; always live.
export function useEthUsd() {
  const client = usePublicClient();
  return useQuery<number | undefined>({
    queryKey: ["ethusd"],
    refetchInterval: 60000,
    staleTime: 60000,
    queryFn: async () => {
      if (!client) return undefined;
      try {
        const r = (await client.readContract({
          address: ethUsdFeed,
          abi: chainlinkAbi,
          functionName: "latestRoundData",
        })) as readonly [bigint, bigint, bigint, bigint, bigint];
        return Number(r[1]) / 1e8;
      } catch {
        return undefined;
      }
    },
    initialData: undefined,
  });
}

// Accurate exact-in quote from the v4 Quoter. Returns amountOut in wei, or
// undefined when the pool is not live (panel falls back to spot math).
export function useQuote(side: "buy" | "sell", amountInWei: bigint) {
  const client = usePublicClient();
  return useQuery<bigint | undefined>({
    queryKey: ["quote", side, amountInWei.toString(), poolReady],
    enabled: poolReady && amountInWei > 0n,
    refetchInterval: 15000,
    queryFn: async () => {
      if (!poolReady || !client || !addresses.cc || amountInWei <= 0n) return undefined;
      try {
        const res = (await client.readContract({
          address: V4.quoter,
          abi: quoterAbi,
          functionName: "quoteExactInputSingle",
          args: [
            {
              poolKey: poolKey(addresses.cc),
              zeroForOne: side === "buy", // ETH(0)->CC on buy
              exactAmount: amountInWei,
              hookData: "0x",
            },
          ],
        })) as readonly [bigint, bigint];
        return res[0];
      } catch {
        return undefined;
      }
    },
  });
}

export const useFeed = () => {
  const { data, ...q } = useScan();
  return { ...q, data: data.feed };
};

function fmt(wei?: bigint): string {
  if (wei == null) return "0.0000";
  return Number(formatUnits(wei, 18)).toLocaleString("en-US", {
    minimumFractionDigits: 4,
    maximumFractionDigits: 4,
  });
}
