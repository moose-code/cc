"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { decodeFunctionData, zeroAddress, type Address } from "viem";
import { addresses, deployBlock, engineDeployed, poolReady, ethUsdFeed, pool } from "./config";
import {
  coreAbi,
  controllerAbi,
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
import { lsGet, lsSet, persistedMap, setAnchor, SCOPE, verifyScope } from "./cache";
import { useHead } from "./live";
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
const blockTime = persistedMap<number>("ts");

async function timestampOf(client: Client, n: bigint): Promise<number> {
  await verifyScope(client);
  const cached = blockTime.get(n.toString());
  if (cached != null) return cached;
  const ts = Number((await client.getBlock({ blockNumber: n })).timestamp);
  blockTime.set(n.toString(), ts);
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
const composeMode = persistedMap<ComposeMode | null>("mode");

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
const settingsBefore = persistedMap<Record<string, unknown>>("settings");

// Controller priceOf(sid) at the Composed block: the price the statement is listed at. Immutable once mined.
const listedPrice = persistedMap<bigint>("listed");

async function listedAtCompose(client: Client, sid: bigint, block: bigint): Promise<bigint | undefined> {
  const core = addresses.core!;
  const controller = await client.readContract({ address: core, abi: coreAbi, functionName: "controller", blockNumber: block });
  return client.readContract({ address: controller, abi: controllerAbi, functionName: "priceOf", args: [sid], blockNumber: block });
}

const tokenInfo = new Map<string, ExitTokenInfo>();

async function exitTokenInfo(client: Client): Promise<ExitTokenInfo | undefined> {
  const token = await client.readContract({ address: addresses.core!, abi: coreAbi, functionName: "exitToken" });
  if (token === zeroAddress) return undefined;
  const hit = tokenInfo.get(token);
  if (hit) return hit;
  const decimals = await client.readContract({ address: token, abi: erc20Abi, functionName: "decimals" });
  const info = { address: token, decimals };
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

// Decoded logs of the Core, the fee router, every controller the Core has used and
// the coin burn transfers, kept per source. Each source records the first block not
// yet scanned; a scan reads that block minus RESCAN up to the head, in CHUNK block
// ranges. The state is saved in localStorage so a reload resumes where it stopped.
const RESCAN = 12n; // blocks re-read behind the last scanned block (reorg window)
const CHUNK = 10_000n; // blocks per getLogs call
const SCAN_KEY = `${SCOPE}:scan:${addresses.router?.toLowerCase()}:${addresses.cc?.toLowerCase()}`;

interface ScanState {
  start: bigint; // first block scanned
  next: Record<string, bigint>; // source -> first block not yet scanned
  logs: Record<string, any[]>; // source -> logs, oldest first
  controllers: Record<string, Address>;
  exit?: ExitTokenInfo;
}

let state: ScanState | undefined;
let exitChecked = false;
let saved = { total: -1, head: 0n };
let lastGood: Scan | undefined;
let queue: Promise<unknown> = Promise.resolve();

const slim = (l: any) => ({
  eventName: l.eventName,
  args: l.args,
  address: l.address,
  blockNumber: l.blockNumber,
  blockHash: l.blockHash,
  logIndex: l.logIndex,
  transactionHash: l.transactionHash,
});

// Reads one source from its resume point to the head; returns the logs read.
async function readSource(client: Client, st: ScanState, src: string, head: bigint, fetch: (from: bigint, to: bigint) => Promise<any[]>) {
  const prev = st.next[src];
  if (prev != null && head < prev) return []; // head unchanged
  const from = prev == null || prev > head + 1n ? st.start : prev > st.start + RESCAN ? prev - RESCAN : st.start;
  const fresh: any[] = [];
  for (let a = from; a <= head; a += CHUNK) fresh.push(...(await fetch(a, a + CHUNK - 1n < head ? a + CHUNK - 1n : head)).map(slim));
  st.logs[src] = [...(st.logs[src] ?? []).filter((l) => l.blockNumber < from), ...fresh];
  st.next[src] = head + 1n;
  return fresh;
}

async function scanTo(client: Client, head: bigint): Promise<Scan> {
  const core = addresses.core!;
  await verifyScope(client);
  if (!state) {
    const s = lsGet<ScanState>(SCAN_KEY);
    state = s && typeof s.start === "bigint" ? s : { start: deployBlock ?? (head > 50000n ? head - 50000n : 0n), next: {}, logs: {}, controllers: {} };
  }
  const st = state;
  const events = engineEventsAbi as any;

  const [coreFresh, burnFresh] = await Promise.all([
    readSource(client, st, "core", head, (fromBlock, toBlock) =>
      client.getLogs({ address: [core, ...(addresses.router ? [addresses.router] : [])], events, fromBlock, toBlock })
    ),
    readSource(client, st, "burn", head, (fromBlock, toBlock) =>
      addresses.cc
        ? client.getLogs({ address: addresses.cc, event: transferEventAbi[0], args: { from: core, to: zeroAddress }, fromBlock, toBlock })
        : Promise.resolve([])
    ),
  ]);

  // every controller the Core has used: its own logs carry the sale events
  if (Object.keys(st.controllers).length === 0) {
    const c = await client.readContract({ address: core, abi: coreAbi, functionName: "controller" });
    st.controllers[c.toLowerCase()] = c;
  }
  for (const l of st.logs.core) if (l.eventName === "ControllerSet") st.controllers[l.args.controller.toLowerCase()] = l.args.controller;
  const ctl = Object.entries(st.controllers);
  const ctlFresh = await Promise.all(
    ctl.map(([k, address]) => readSource(client, st, `ctl:${k}`, head, (fromBlock, toBlock) => client.getLogs({ address, events, fromBlock, toBlock })))
  );

  // the exit token changes only through ExitModuleSet
  if (!exitChecked || coreFresh.some((l) => l.eventName === "ExitModuleSet")) {
    st.exit = await exitTokenInfo(client).catch(() => st.exit);
    exitChecked = true;
  }

  const logs = [...st.logs.core, ...ctl.flatMap(([k]) => st.logs[`ctl:${k}`] ?? [])].sort((x, y) =>
    x.blockNumber === y.blockNumber ? Number(x.logIndex - y.logIndex) : x.blockNumber < y.blockNumber ? -1 : 1
  );

  // exit token paid by the core to a credit seller, per transaction and seller
  if (st.exit?.address) {
    const token = st.exit.address;
    await readSource(client, st, `xpay:${token.toLowerCase()}`, head, (fromBlock, toBlock) =>
      client.getLogs({ address: token, event: transferEventAbi[0], args: { from: core }, fromBlock, toBlock })
    );
  }
  const exitPaid = new Map<string, bigint>();
  for (const t of st.exit?.address ? st.logs[`xpay:${st.exit.address.toLowerCase()}`] ?? [] : []) {
    const k = `${t.transactionHash}:${String(t.args.to).toLowerCase()}`;
    exitPaid.set(k, (exitPaid.get(k) ?? 0n) + (t.args.value ?? 0n));
  }

  // coin burned per transaction: the Buyback event carries the eth spent only
  const burnedBy = new Map<string, bigint>();
  let burned = 0n;
  for (const b of st.logs.burn ?? []) {
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

  // listed price per Composed log
  const listedAt = new Map<string, bigint>();
  await Promise.all(
    logs
      .filter((l) => l.eventName === "Composed")
      .map(async (l) => {
        const k = `${l.transactionHash}:${Number(l.args.sid)}`;
        let p = listedPrice.get(k);
        if (p === undefined) {
          p = await listedAtCompose(client, l.args.sid, l.blockNumber).catch(() => undefined);
          if (p !== undefined) listedPrice.set(k, p);
        }
        if (p !== undefined) listedAt.set(k, p);
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
          .readContract({ address: core, abi: coreAbi, functionName: "settings", blockNumber: l.blockNumber - 1n })
          .catch(() => undefined)) as Record<string, unknown> | undefined;
        if (prev) settingsBefore.set(key, prev);
      }
    }
    if (prev) prevSettings.set(key, prev);
    prev = l.args.settings;
  }

  // save when logs were added, else every 300 blocks
  const total = Object.values(st.logs).reduce((n, a) => n + a.length, 0);
  if (total !== saved.total || head - saved.head > 300n) {
    lsSet(SCAN_KEY, st, 2_500_000);
    const last = logs.reduce((m, l) => (m == null || l.blockNumber > m.blockNumber ? l : m), undefined as any);
    if (last?.blockHash) setAnchor(last.blockNumber, last.blockHash);
    saved = { total, head };
  }

  const { stats, credits, statements, rows } = processLogs({
    logs,
    head,
    router: addresses.router,
    burnedBy,
    burned,
    modes,
    prevSettings,
    exitToken: st.exit,
    exitPaid,
    listedAt,
  });
  // logs arrive oldest first; the feed is newest first
  return (lastGood = { feed: rows.reverse(), stats, credits, statements });
}

// Every row for the feed (newest first), totals and per credit / per statement
// histories over every log. Runs once per new head and reads only the blocks since the last run.
export function useScan() {
  const client = usePublicClient();
  const { data: hd } = useHead();
  const head = hd?.n;
  const q = useQuery<Scan>({
    queryKey: ["scan", head?.toString()],
    enabled: engineDeployed && Boolean(head),
    gcTime: 30000,
    placeholderData: (prev) => prev,
    queryFn: () => {
      if (!client || !addresses.core || !head) return EMPTY_SCAN;
      const p = queue.then(() => scanTo(client, head)).catch(() => lastGood ?? EMPTY_SCAN);
      queue = p;
      return p;
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
  const head = useHead().data?.n;
  return useQuery<Market>({
    queryKey: ["market", engineDeployed, poolReady, head?.toString()],
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
