"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicClient, useBlockNumber } from "wagmi";
import { decodeFunctionData, zeroAddress, type Address } from "viem";
import { addresses, deployBlock, engineDeployed, poolReady, ethUsdFeed, pool } from "./config";
import {
  coreAbi,
  coreLensAbi,
  engineEventsAbi,
  stateViewAbi,
  quoterAbi,
  chainlinkAbi,
  transferEventAbi,
  erc20Abi,
  hookAbi,
  mevAbi,
  routerAbi,
} from "./abis";
import { V4, poolId, poolKey, ccPerEthFromSqrt, type PoolParams } from "./v4";
import { processLogs, type ComposeMode, type ExitTokenInfo, type FeedEvent, type Scan } from "./events";

export type { FeedEvent, FeedKind, Stats, Scan, CreditEvt, CreditHow, StatementRecord, ComposeMode } from "./events";

export const STATEMENT_SIZE = 80; // credits composed into one statement (Core PAGE, the length of Composed.ids)

export interface Market {
  ccPerEth: number; // tokens per 1 eth, from the v4 pool slot0
  bid: bigint; // wei the engine pays per credit (snapshot.ethRate)
  pot: bigint; // wei available to buy credits (snapshot.ethPot)
  creditsReady: number; // credits in the pile toward the next statement
}

const EMPTY_MARKET: Market = { ccPerEth: 0, bid: 0n, pot: 0n, creditsReady: 0 };

type Client = NonNullable<ReturnType<typeof usePublicClient>>;

// ---- event scan --------------------------------------------------------------

const EMPTY_SCAN: Scan = {
  feed: [],
  stats: {
    creditsEth: 0,
    creditsExit: 0,
    creditsListing: 0,
    creditsAdopted: 0,
    creditsSold: 0,
    composed: 0,
    sold: 0,
    redeemed: 0,
    ethIntoCredits: 0,
    ccBurned: 0,
  },
  credits: {},
  statements: {},
};

// block number -> timestamp. A mined block's timestamp does not change.
const blockTime = new Map<bigint, number>();

async function timestampOf(client: Client, n: bigint): Promise<number> {
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

// Immutable per transaction: did it call Core.compose or Core.composeChosen directly?
const composeMode = new Map<string, ComposeMode | null>();

async function modeOf(client: Client, hash: string): Promise<ComposeMode | null> {
  const cached = composeMode.get(hash);
  if (cached !== undefined) return cached;
  const t = await client.getTransaction({ hash: hash as `0x${string}` });
  let mode: ComposeMode | null = null;
  if (t.to?.toLowerCase() === addresses.core?.toLowerCase()) {
    try {
      const fn = decodeFunctionData({ abi: coreAbi, data: t.input }).functionName;
      mode = fn === "compose" ? "default" : fn === "composeChosen" ? "chosen" : null;
    } catch {
      /* not a compose call */
    }
  }
  composeMode.set(hash, mode);
  return mode;
}

// Settings in force just before a SettingsSet log, cached per log key.
const settingsBefore = new Map<string, Record<string, unknown>>();

const tokenInfo = new Map<string, ExitTokenInfo>();

async function exitTokenInfo(client: Client): Promise<ExitTokenInfo | undefined> {
  const token = await client.readContract({ address: addresses.core!, abi: coreAbi, functionName: "exitToken" });
  if (token === zeroAddress) return undefined;
  const hit = tokenInfo.get(token);
  if (hit) return hit;
  const [symbol, decimals] = await Promise.all([
    client.readContract({ address: token, abi: erc20Abi, functionName: "symbol" }),
    client.readContract({ address: token, abi: erc20Abi, functionName: "decimals" }),
  ]);
  const info = { symbol, decimals };
  tokenInfo.set(token, info);
  return info;
}

export function useExitToken() {
  const client = usePublicClient();
  return useQuery<ExitTokenInfo | undefined>({
    queryKey: ["exit-token", addresses.core],
    enabled: engineDeployed && Boolean(client),
    staleTime: 60000,
    queryFn: () => exitTokenInfo(client!).catch(() => undefined),
  });
}

// One pass over the logs of the Core, the controller(s) and the fee router since
// the deploy block, plus the coin burn transfers: every row for
// the feed (newest first), totals and per credit / per statement histories over every log.
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
        const range = { fromBlock: from, toBlock: head } as const;
        const events = engineEventsAbi as any;
        const [coreRouterLogs, burnLogs, controllerNow, xInfo] = await Promise.all([
          client.getLogs({ address: [addresses.core, ...(addresses.router ? [addresses.router] : [])], events, ...range }),
          addresses.cc
            ? client.getLogs({
                address: addresses.cc,
                event: transferEventAbi[0],
                args: { from: addresses.core, to: zeroAddress },
                ...range,
              })
            : [],
          client.readContract({ address: addresses.core, abi: coreAbi, functionName: "controller" }),
          exitTokenInfo(client).catch(() => undefined),
        ]);
        // every controller the Core has used: its own logs carry the sale events
        const controllers = new Map<string, Address>([[controllerNow.toLowerCase(), controllerNow]]);
        for (const l of coreRouterLogs as any[])
          if (l.eventName === "ControllerSet") controllers.set(l.args.controller.toLowerCase(), l.args.controller);
        const controllerLogs = await client.getLogs({ address: [...controllers.values()], events, ...range });

        const logs = [...(coreRouterLogs as any[]), ...(controllerLogs as any[])].sort((x, y) =>
          x.blockNumber === y.blockNumber ? Number(x.logIndex - y.logIndex) : x.blockNumber < y.blockNumber ? -1 : 1
        );

        // coin burned per transaction: the Buyback event carries the eth spent only
        const burnedBy = new Map<string, bigint>();
        let burned = 0n;
        for (const b of burnLogs) {
          const v = b.args.value ?? 0n;
          burned += v;
          burnedBy.set(b.transactionHash, (burnedBy.get(b.transactionHash) ?? 0n) + v);
        }

        // compose mode per Composed transaction
        const modes = new Map<string, ComposeMode>();
        await Promise.all(
          logs
            .filter((l) => l.eventName === "Composed")
            .map(async (l) => {
              const m = await modeOf(client, l.transactionHash).catch(() => null);
              if (m) modes.set(l.transactionHash, m);
            })
        );

        // settings before each SettingsSet: the previous event's value, the first from the chain
        const prevSettings = new Map<string, Record<string, unknown>>();
        let prev: Record<string, unknown> | undefined;
        for (const l of logs) {
          if (l.eventName !== "SettingsSet") continue;
          const key = `${l.transactionHash}-${l.logIndex}`;
          if (prev === undefined) {
            prev = settingsBefore.get(key);
            if (prev === undefined && l.blockNumber > 0n) {
              prev = (await client
                .readContract({ address: addresses.core, abi: coreAbi, functionName: "settings", blockNumber: l.blockNumber - 1n })
                .catch(() => undefined)) as Record<string, unknown> | undefined;
              if (prev) settingsBefore.set(key, prev);
            }
          }
          if (prev) prevSettings.set(key, prev);
          prev = l.args.settings;
        }

        const { stats, credits, statements, rows } = processLogs({
          logs,
          head,
          router: addresses.router,
          burnedBy,
          burned,
          modes,
          prevSettings,
          exitToken: xInfo,
        });
        // logs arrive oldest first; the feed is newest first
        const feed: FeedEvent[] = rows.reverse();
        return { feed, stats, credits, statements };
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

// ---- pool params and fees, from the chain --------------------------------------

// The pool key the Core buys back in: HOOK, POOL_FEE and TICK_SPACING are Core
// immutables. Without a deployed Core the config values (the launch config) apply.
const poolParamsCache = new Map<string, Promise<PoolParams>>();

export function poolParams(client: Client): Promise<PoolParams> {
  const core = addresses.core;
  if (!core) return Promise.resolve(pool);
  let hit = poolParamsCache.get(core);
  if (!hit) {
    hit = Promise.all([
      client.readContract({ address: core, abi: coreAbi, functionName: "HOOK" }),
      client.readContract({ address: core, abi: coreAbi, functionName: "POOL_FEE" }),
      client.readContract({ address: core, abi: coreAbi, functionName: "TICK_SPACING" }),
    ]).then(([hook, fee, tickSpacing]) => ({ hook, fee: Number(fee), tickSpacing: Number(tickSpacing) }));
    hit.catch(() => poolParamsCache.delete(core));
    poolParamsCache.set(core, hit);
  }
  return hit;
}

export function usePoolParams() {
  const client = usePublicClient();
  return useQuery<PoolParams>({
    queryKey: ["pool-params", addresses.core],
    enabled: Boolean(client),
    staleTime: Infinity,
    queryFn: () => poolParams(client!).catch(() => pool),
  });
}

export interface SwapFees {
  fee: number; // share of the swap amount taken as fee: the pool's current skim plus the lp fee
  engineShare: number; // share of that fee that reaches the engine: the hook's bounty share, less the router payee split
}

// Reads the hook's skim config for the CC/ETH pool, the MEV module's current
// skim (decays after launch) and the router's payee split.
export function useSwapFees() {
  const client = usePublicClient();
  return useQuery<SwapFees | undefined>({
    queryKey: ["swap-fees", addresses.cc, addresses.router],
    enabled: poolReady && Boolean(client),
    staleTime: 60000,
    refetchInterval: 60000,
    queryFn: async () => {
      if (!client || !addresses.cc) return undefined;
      try {
        const p = await poolParams(client);
        const id = poolId(addresses.cc, p);
        const cfg = await client.readContract({ address: p.hook, abi: hookAbi, functionName: "skimConfig", args: [id] });
        let skimBps = Number(cfg.baselineSkimBps);
        const info = await client.readContract({ address: p.hook, abi: hookAbi, functionName: "poolInfo", args: [id] });
        if (info.mevModule !== zeroAddress) {
          const [now] = await client.readContract({ address: info.mevModule, abi: mevAbi, functionName: "currentSkimBps", args: [id] });
          skimBps = Number(now);
        }
        let engineShare = Number(cfg.bountyBps) / 10000;
        if (addresses.router) {
          const [on, ppm] = await Promise.all([
            client.readContract({ address: addresses.router, abi: routerAbi, functionName: "splitOn" }),
            client.readContract({ address: addresses.router, abi: routerAbi, functionName: "payeePpmTotal" }),
          ]);
          if (on) engineShare *= 1 - Number(ppm) / 1e6;
        }
        return { fee: skimBps / 10000 + Number(cfg.lpFeePips) / 1e6, engineShare };
      } catch {
        return undefined;
      }
    },
  });
}

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
            args: [poolId(addresses.cc, await poolParams(client))],
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
              poolKey: poolKey(addresses.cc, await poolParams(client)),
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
