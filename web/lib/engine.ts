"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicClient, useBlockNumber } from "wagmi";
import { formatUnits, zeroAddress, type Address } from "viem";
import { addresses, deployBlock, engineDeployed, poolReady, ethUsdFeed } from "./config";
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
  txHash?: string; // full hash, drives the evm.now link
  tile?: { kind: "credit"; id: number } | { kind: "statement"; id: number; ids: number[] };
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
  ccPerEth: number; // tokens per 1 eth, from the v4 pool slot0
  bid: bigint; // wei the engine pays per credit (snapshot.ethRate)
  pot: bigint; // wei available to buy credits (snapshot.ethPot)
  creditsReady: number; // credits in the pile toward the next statement
}

const EMPTY_MARKET: Market = { ccPerEth: 0, bid: 0n, pot: 0n, creditsReady: 0 };

// ---- event scan --------------------------------------------------------------

export interface StatementSale {
  id: number;
  buyer: string;
  price: bigint; // wei
  block: bigint;
}

// A Composed event: the statement's 80 credit ids in burn order.
export interface ComposedStatement {
  sid: number;
  ids: number[];
  cost: bigint; // wei
  block: bigint;
}

// One pass over the Core logs (and the coin burn transfers) since the deploy
// block: the newest FEED_ROWS rows for the feed, totals over every log.
export interface Scan {
  feed: FeedEvent[];
  stats: Stats; // statements = Composed events; ccBurned = coin burned by the core
  composed: Record<number, ComposedStatement>; // by statement id
  creditStatement: Record<number, number>; // credit id -> statement id it composed into
  bought: Record<number, { cost: bigint; block: bigint }>; // CreditBought, latest per credit
  creditSold: Record<number, { buyer: string; price: bigint; block: bigint }>; // CreditSold, latest per credit
  sold: StatementSale[]; // StatementSoldTo
  exited: number[]; // StatementExited sids
}

const FEED_ROWS = 60;
const EMPTY_SCAN: Scan = {
  feed: [],
  stats: { creditsBought: 0, statements: 0, ethIntoCredits: 0, ccBurned: 0 },
  composed: {},
  creditStatement: {},
  bought: {},
  creditSold: {},
  sold: [],
  exited: [],
};

// block number -> timestamp. A mined block's timestamp does not change.
const blockTime = new Map<bigint, number>();

async function timestampOf(client: NonNullable<ReturnType<typeof usePublicClient>>, n: bigint): Promise<number> {
  const cached = blockTime.get(n);
  if (cached != null) return cached;
  const ts = Number((await client.getBlock({ blockNumber: n })).timestamp);
  blockTime.set(n, ts);
  return ts;
}

// Timestamp of one block, undefined until read.
export function useBlockTs(block?: bigint) {
  const client = usePublicClient();
  return useQuery<number | undefined>({
    queryKey: ["block-ts", block?.toString()],
    enabled: block != null,
    staleTime: Infinity,
    queryFn: () => timestampOf(client!, block!),
  });
}

export function useScan() {
  const client = usePublicClient();
  const { data: head } = useBlockNumber({ watch: engineDeployed });
  const q = useQuery<Scan>({
    queryKey: ["scan", head?.toString()],
    enabled: engineDeployed && Boolean(head),
    refetchInterval: 12000,
    placeholderData: (prev) => prev,
    queryFn: async () => {
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
        const composed: Scan["composed"] = {};
        const creditStatement: Scan["creditStatement"] = {};
        const bought: Scan["bought"] = {};
        const creditSold: Scan["creditSold"] = {};
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
            bought[Number(a.id)] = { cost: a.cost, block };
            rows.push({ ...base, kind: "credit", detail: `bought credit #${a.id}`, eth: fmt(a.cost), tile: { kind: "credit", id: Number(a.id) } });
          } else if (name === "Composed") {
            stats.statements++;
            const sid = Number(a.sid);
            const ids = (a.ids as readonly bigint[]).map(Number);
            composed[sid] = { sid, ids, cost: a.cost, block };
            for (const id of ids) creditStatement[id] = sid;
            rows.push({ ...base, kind: "composed", detail: `statement ${a.sid} · ${STATEMENT_SIZE} credits · cost ${fmt(a.cost)} eth`, tile: { kind: "statement", id: sid, ids } });
          } else if (name === "CreditSold") {
            creditSold[Number(a.id)] = { buyer: a.buyer as string, price: a.price, block };
            rows.push({ ...base, kind: "sold", detail: `credit #${a.id} bought by`, addr: a.buyer as string, eth: fmt(a.price), tile: { kind: "credit", id: Number(a.id) } });
          } else if (name === "StatementSoldTo") {
            const sid = Number(a.sid);
            sold.push({ id: sid, buyer: a.buyer as string, price: a.price, block });
            rows.push({ ...base, kind: "sold", detail: `statement ${a.sid} bought by`, addr: a.buyer as string, eth: fmt(a.price), tile: { kind: "statement", id: sid, ids: composed[sid]?.ids ?? [] } });
          } else if (name === "StatementExited")
            exited.push(Number(a.sid));
          else if (name === "Buyback")
            rows.push({ ...base, kind: "burn", detail: `burned ${Math.floor(Number(formatUnits(burnedBy.get(hash) ?? 0n, 18))).toLocaleString()} cc`, eth: fmt(a.amountIn) });
        }
        // logs arrive oldest first; the feed is newest first
        const feed = rows.reverse().slice(0, FEED_ROWS);
        // exact block timestamps for the shown rows (cached per block)
        await Promise.all([...new Set(feed.map((r) => r.block))].map((n) => timestampOf(client, n)));
        for (const r of feed) r.ts = blockTime.get(r.block) ?? 0;
        return { feed, stats, composed, creditStatement, bought, creditSold, sold, exited };
      } catch {
        return EMPTY_SCAN;
      }
    },
  });
  return { ...q, data: q.data ?? EMPTY_SCAN };
}

export const useStats = () => {
  const { data, ...q } = useScan();
  return { ...q, data: data.stats };
};

// Statements that left the engine: sold by StatementSoldTo, redeemed by StatementExited.
export const useStatementHistory = () => {
  const { data, ...q } = useScan();
  return { ...q, data: { total: data.stats.statements, sold: data.sold, exited: data.exited, composed: data.composed } };
};

export function useMarket() {
  const client = usePublicClient();
  const { data: head } = useBlockNumber({ watch: engineDeployed || poolReady });
  return useQuery<Market>({
    queryKey: ["market", engineDeployed, poolReady, head?.toString()],
    refetchInterval: 15000,
    queryFn: async () => {
      if (!client) return EMPTY_MARKET;
      let ccPerEth = 0;
      let bid = 0n;
      let pot = 0n;
      let creditsReady = 0;

      // cc/eth spot from the v4 pool slot0 (coin deployed).
      if (poolReady && addresses.cc) {
        try {
          const slot0 = (await client.readContract({
            address: V4.stateView,
            abi: stateViewAbi,
            functionName: "getSlot0",
            args: [poolId(addresses.cc)],
          })) as readonly [bigint, number, number, number];
          ccPerEth = Math.max(0, ccPerEthFromSqrt(slot0[0]));
        } catch {
          /* pool not initialized */
        }
      }

      // engine state (bid, pot, pile) from the lens.
      if (engineDeployed && addresses.coreLens) {
        try {
          const s = await client.readContract({
            address: addresses.coreLens,
            abi: coreLensAbi,
            functionName: "snapshot",
          });
          bid = s.ethRate;
          pot = s.ethPot;
          creditsReady = Number(s.pileSize % BigInt(STATEMENT_SIZE));
        } catch {
          /* lens not readable */
        }
      }

      return { ccPerEth, bid, pot, creditsReady };
    },
    initialData: EMPTY_MARKET,
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
