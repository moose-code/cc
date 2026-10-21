"use client";

// Reads of the swap panel: the markets it trades, pool spot price, exact-in quote, ETH/USD.

import { useCallback, useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { usePublicClient, useReadContract, useReadContracts } from "wagmi";
import { formatUnits, parseAbi, parseAbiItem, zeroAddress, type Address } from "viem";
import { chain, core, ethUsdFeed, expectedPool } from "./config";
import { chainlinkAbi, controllerAbi, erc20Abi, hookAbi, mevAbi, quoterAbi, stateViewAbi } from "./abis";
import { useCoinLive, useHead, useSnapshot } from "./live";
import { SCOPE, lsGet, lsSet } from "./cache";
import { V4, ccPerEthFromSqrt, poolIdOf, poolKey, type PoolKey } from "./v4";

const DAY_BLOCKS = 7200n;
const BUCKET = 300n; // the 24h reference block moves once per hour, so the cached read is reused

// An eth/token v4 pool the swap panel trades: the token (currency1) and its pool key.
export type Market = { token: Address; symbol: string; decimals: number; key: PoolKey };

const corePoolAbi = parseAbi([
  "function HOOK() view returns (address)",
  "function POOL_FEE() view returns (uint24)",
  "function TICK_SPACING() view returns (int24)",
]);

// The CC pool key comes from the Core's immutable values after the coin launches.
// The one pool read is cached; a configured tuple that disagrees leaves the market unavailable.
export function useCcMarket(): { market?: Market; error?: string } {
  const client = usePublicClient();
  const coin = useSnapshot().data?.coin;
  const live = useCoinLive();
  const key = useQuery<PoolKey>({
    queryKey: ["cc-pool", chain.id, core, coin],
    enabled: Boolean(client && core && coin && live),
    staleTime: Infinity,
    retry: false,
    queryFn: async () => {
      const [hook, fee, tickSpacing] = await client!.multicall({
        allowFailure: false,
        contracts: [
          { address: core!, abi: corePoolAbi, functionName: "HOOK" },
          { address: core!, abi: corePoolAbi, functionName: "POOL_FEE" },
          { address: core!, abi: corePoolAbi, functionName: "TICK_SPACING" },
        ],
      }).catch(() => {
        throw new Error("Could not read CC pool settings from the configured Core. Check the Core address and RPC.");
      });
      return poolKey(coin!, { hook, fee, tickSpacing }, expectedPool);
    },
  });
  const market = useMemo(() => (coin && live && key.data ? { token: coin, symbol: "cc", decimals: 18, key: key.data } : undefined), [coin, live, key.data]);
  return { market, error: key.isError ? key.error.message : undefined };
}

// The balance token market from the controller's balancePoolKey. `loading`
// while the reads are in flight; `market` stays undefined while the key is unset.
export function useBalanceMarket(): { market?: Market; loading: boolean } {
  const controller = useSnapshot().data?.controller;
  const c = { address: controller, abi: controllerAbi } as const;
  const on = Boolean(controller);
  const set = useReadContract({ ...c, functionName: "balancePoolKeySet", query: { enabled: on } });
  const key = useReadContract({ ...c, functionName: "balancePoolKey", query: { enabled: set.data === true } });
  const [currency0, token, fee, tickSpacing, hooks] = (key.data ?? []) as readonly [Address, Address, number, number, Address];
  const meta = useReadContracts({
    contracts: [
      { address: token, abi: erc20Abi, functionName: "symbol" },
      { address: token, abi: erc20Abi, functionName: "decimals" },
    ],
    query: { enabled: Boolean(key.data) },
  });
  const market = useMemo<Market | undefined>(() => {
    const [sym, dec] = meta.data ?? [];
    if (!key.data || currency0 !== zeroAddress || sym?.status !== "success" || dec?.status !== "success") return undefined;
    return { token, symbol: sym.result, decimals: dec.result, key: { currency0, currency1: token, fee, tickSpacing, hooks } };
  }, [key.data, meta.data]); // eslint-disable-line react-hooks/exhaustive-deps
  const loading = !on || set.isLoading || (set.data === true && !meta.data && !key.isError && !meta.isError);
  return { market, loading };
}

// Tokens per 1 eth from the pool slot0. undefined while the pool has no price.
export function useTokensPerEth(market?: Market) {
  const client = usePublicClient();
  return useQuery<number | undefined>({
    queryKey: ["spot", market && poolIdOf(market.key)],
    enabled: Boolean(client && market),
    refetchInterval: 15000,
    queryFn: async () => {
      try {
        const [sqrt] = await client!.readContract({
          address: V4.stateView,
          abi: stateViewAbi,
          functionName: "getSlot0",
          args: [poolIdOf(market!.key)],
        });
        return sqrt > 0n ? ccPerEthFromSqrt(sqrt, market!.decimals) : undefined;
      } catch {
        return undefined;
      }
    },
  });
}

// The raw slot0 sqrtPriceX96 of a market's pool, for exact arithmetic (the pool door of the claim panel,
// web/lib/exchange.ts poolSellQuote). undefined while the pool has no price or the view does not answer.
export function useSqrtPrice(market?: Market) {
  const client = usePublicClient();
  return useQuery<bigint | undefined>({
    queryKey: ["sqrt", market && poolIdOf(market.key)],
    enabled: Boolean(client && market),
    refetchInterval: 15000,
    queryFn: async () => {
      try {
        const [sqrt] = await client!.readContract({ address: V4.stateView, abi: stateViewAbi, functionName: "getSlot0", args: [poolIdOf(market!.key)] });
        return sqrt > 0n ? sqrt : undefined;
      } catch {
        return undefined;
      }
    },
  });
}

// Eth value, in wei, of a balance token amount at the balance pool's spot price (useTokensPerEth, the swap panel's
// query). The returned function gives undefined while the market, its price or the Core's balance token is unknown,
// or when the pool token differs from the Core's balance token.
export function useBalanceInEth(): (amount: bigint) => bigint | undefined {
  const balanceToken = useSnapshot().data?.balanceToken;
  const { market } = useBalanceMarket();
  const { data: perEth } = useTokensPerEth(market);
  return useCallback(
    (amount: bigint) => {
      if (!market || !perEth || market.token.toLowerCase() !== balanceToken?.toLowerCase()) return undefined;
      return BigInt(Math.round((Number(formatUnits(amount, market.decimals)) / perEth) * 1e18));
    },
    [market, perEth, balanceToken],
  );
}

// Exact-in quote from the v4 Quoter: amountOut in wei, undefined when the quote reverts.
export function useQuote(market: Market | undefined, side: "buy" | "sell", amountIn: bigint) {
  const client = usePublicClient();
  return useQuery<bigint | undefined>({
    queryKey: ["quote", market && poolIdOf(market.key), side, amountIn.toString()],
    enabled: Boolean(client && market) && amountIn > 0n,
    refetchInterval: 15000,
    queryFn: async () => {
      try {
        const [out] = await client!.readContract({
          address: V4.quoter,
          abi: quoterAbi,
          functionName: "quoteExactInputSingle",
          args: [{ poolKey: market!.key, zeroForOne: side === "buy", exactAmount: amountIn, hookData: "0x" }],
        });
        return out;
      } catch {
        return undefined;
      }
    },
  });
}

// Swap fee of a hooked market, in bps: the pool's current skim. The pool charges
// no LP fee (the dynamic fee flag stays at 0), so the skim is the whole trading
// fee. While the MEV module reports an active window, the skim is its decaying
// value (not below the baseline), `endsAt` is the window end in unix seconds and
// `perMin` the decay in bps per minute, both from the module's schedule(poolId)
// (startingSkimBps, endSkimBps, windowSeconds, startTime; undefined when the read
// fails). `baseBps` is the fee after the window: the higher of the schedule's end
// skim and the baseline skim. Refetched every 12 s (the head poll) while the
// window is active, every 60 s otherwise. null when a read fails.
//
// Engine share (hook skimConfig.bountyBps, bountyRecipient): `bountyBps` is the part of the skim, in bps of the skim,
// paid to the bounty recipient; the rest goes to the protocol. `bountyToEngine` is true when the recipient is the Core.
// `engineBps` / `engineBaseBps` are that part in bps of trade volume at the current skim and after the window
// (bps * bountyBps / 10000; 0 when the recipient is not the Core). Of the engine income the Core books
// `feeToRedeemBurnBps` (snapshot settings) to the redeem burn pot and the rest to the pot, see potShareBps.
export type HookFee = {
  bps: number;
  baseBps: number;
  active: boolean;
  endsAt?: number;
  perMin?: number;
  bountyBps: number;
  bountyToEngine: boolean;
  engineBps: number;
  engineBaseBps: number;
};

// Share of trade volume, in bps of volume, that reaches the engine pot at fee `engineBps`: the engine income less the
// payee share (settings.payeePpm, while payeeOn) and less the redeem burn share (settings.feeToRedeemBurnBps), per
// Core._split. 621 bps of volume at the launch values (6.21% to the Core; all to the pot while feeToRedeemBurnBps is 0).
export function potShareBps(engineBps: number, s: { payeeOn: boolean; settings: { payeePpm: number; feeToRedeemBurnBps: number } }): number {
  const afterPayee = engineBps * (1 - (s.payeeOn ? s.settings.payeePpm / 1_000_000 : 0));
  return afterPayee * (1 - s.settings.feeToRedeemBurnBps / 10000);
}

const scheduleAbi = parseAbi([
  "function schedule(bytes32 poolId) view returns ((uint24 startingSkimBps, uint24 endSkimBps, uint32 windowSeconds, uint40 startTime))",
]);

export function useHookFeeBps(market?: Market) {
  const client = usePublicClient();
  const hook = market?.key.hooks;
  const on = Boolean(client && market && hook !== zeroAddress);
  return useQuery<HookFee | null>({
    queryKey: ["hook-fee", market && poolIdOf(market.key)],
    enabled: on,
    staleTime: 0,
    refetchInterval: (q) => (q.state.data?.active ? 12000 : 60000),
    queryFn: async () => {
      try {
        const id = poolIdOf(market!.key);
        const [cfg, info] = await Promise.all([
          client!.readContract({ address: hook!, abi: hookAbi, functionName: "skimConfig", args: [id] }),
          client!.readContract({ address: hook!, abi: hookAbi, functionName: "poolInfo", args: [id] }),
        ]);
        const baseline = Number(cfg.baselineSkimBps);
        let skim = baseline;
        let active = false;
        let endsAt: number | undefined;
        let perMin: number | undefined;
        let end = baseline;
        if (info.mevModule !== zeroAddress) {
          const [now, running] = await client!.readContract({ address: info.mevModule, abi: mevAbi, functionName: "currentSkimBps", args: [id] });
          if (running) {
            active = true;
            skim = Math.max(Number(now), baseline);
            const sch = await client!.readContract({ address: info.mevModule, abi: scheduleAbi, functionName: "schedule", args: [id] }).catch(() => undefined);
            if (sch && sch.windowSeconds > 0) {
              endsAt = Number(sch.startTime) + sch.windowSeconds;
              perMin = ((sch.startingSkimBps - sch.endSkimBps) / sch.windowSeconds) * 60;
              end = Math.max(sch.endSkimBps, baseline);
            }
          }
        }
        const bountyBps = Number(cfg.bountyBps);
        const bountyToEngine = cfg.bountyRecipient.toLowerCase() === core?.toLowerCase();
        const engine = (b: number) => (bountyToEngine ? (b * bountyBps) / 10000 : 0);
        return { bps: skim, baseBps: end, active, endsAt, perMin, bountyBps, bountyToEngine, engineBps: engine(skim), engineBaseBps: engine(end) };
      } catch {
        return null;
      }
    },
  });
}

// ETH/USD from the Chainlink feed. undefined when the feed read fails.
export function useEthUsd() {
  const client = usePublicClient();
  return useQuery<number | undefined>({
    queryKey: ["ethusd"],
    enabled: Boolean(client),
    refetchInterval: 60000,
    staleTime: 60000,
    queryFn: async () => {
      try {
        const [, answer] = await client!.readContract({ address: ethUsdFeed, abi: chainlinkAbi, functionName: "latestRoundData" });
        return Number(answer) / 1e8;
      } catch {
        return undefined;
      }
    },
  });
}

// Price in USD, market cap and the 24h change of a market. Price = pool spot x
// the eth/usd feed; market cap = price x totalSupply; the change compares the
// spot now with the spot DAY_BLOCKS earlier, read once per bucket with a
// blockTag and kept in localStorage. undefined for any figure whose read fails; `loading` while the reads are out.
export function useMarketStats(market?: Market) {
  const client = usePublicClient();
  const { data: perEth, isPending: spotPending } = useTokensPerEth(market);
  const { data: ethUsd, isPending: usdPending } = useEthUsd();
  const head = useHead().data?.n;
  const { data: supply, isPending: supplyPending } = useReadContract({ address: market?.token, abi: erc20Abi, functionName: "totalSupply", query: { enabled: Boolean(market) } });

  const ref = head != null && head > DAY_BLOCKS ? ((head - DAY_BLOCKS) / BUCKET) * BUCKET : undefined;
  // the reference price: the spot DAY_BLOCKS ago, or, for a pool younger than that, its opening price ("since launch")
  const { data: then, isPending: thenPending } = useQuery<{ perEth: number; since: "24h" | "launch" } | null>({
    queryKey: ["spot24", market && poolIdOf(market.key), ref?.toString()],
    enabled: Boolean(client && market && ref && head),
    staleTime: Infinity,
    retry: false,
    queryFn: async () => {
      const id = poolIdOf(market!.key);
      const key = `${SCOPE}:spot24:${id}:${ref}`;
      const hit = lsGet<number>(key);
      if (hit != null) return { perEth: hit, since: "24h" };
      let sqrt = 0n;
      try {
        [sqrt] = await client!.readContract({ address: V4.stateView, abi: stateViewAbi, functionName: "getSlot0", args: [id], blockNumber: ref });
      } catch {
        // pruned state, or a pool younger than the reference block
      }
      if (sqrt > 0n) {
        const v = ccPerEthFromSqrt(sqrt, market!.decimals);
        lsSet(key, v);
        return { perEth: v, since: "24h" };
      }
      const launch = await openingPerEth(client!, id, market!.decimals, ref!, head!);
      return launch != null ? { perEth: launch, since: "launch" } : null;
    },
  });
  const perEthThen = then?.perEth;

  const priceUsd = ethUsd != null && perEth ? ethUsd / perEth : undefined;
  const marketCap = priceUsd != null && supply != null && market ? priceUsd * Number(formatUnits(supply, market.decimals)) : undefined;
  const change = perEth && perEthThen != null ? (perEthThen / perEth - 1) * 100 : undefined;
  // loading: a read the figures need has not answered (as opposed to answered with nothing, shown as a dash)
  const loading = !market || spotPending || usdPending;
  return { priceUsd, ethUsd, marketCap, change, changeSince: then?.since, loading, capLoading: loading || supplyPending, changeLoading: loading || thenPending };
}

const initializeEvent = parseAbiItem(
  "event Initialize(bytes32 indexed id, address indexed currency0, address indexed currency1, uint24 fee, int24 tickSpacing, address hooks, uint160 sqrtPriceX96, int24 tick)"
);
const LOG_SPAN = 4_999n; // the website RPC API takes eth_getLogs spans under 5,000 blocks (lib/rpc-proxy.ts)

// The pool's opening price, tokens per eth, from its PoolManager Initialize event between `from` and `to`; null when
// the pool was not initialized in that range. Fixed once found, so kept in localStorage.
async function openingPerEth(client: NonNullable<ReturnType<typeof usePublicClient>>, id: `0x${string}`, decimals: number, from: bigint, to: bigint): Promise<number | null> {
  const key = `${SCOPE}:open:${id}`;
  const hit = lsGet<number>(key);
  if (hit != null) return hit;
  for (let a = from; a <= to; a += LOG_SPAN + 1n) {
    const b = a + LOG_SPAN < to ? a + LOG_SPAN : to;
    const logs = await client.getLogs({ address: V4.poolManager, event: initializeEvent, args: { id }, fromBlock: a, toBlock: b }).catch(() => []);
    const sqrt = logs[0]?.args.sqrtPriceX96;
    if (sqrt != null && sqrt > 0n) {
      const v = ccPerEthFromSqrt(sqrt, decimals);
      lsSet(key, v);
      return v;
    }
  }
  return null;
}
