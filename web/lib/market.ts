"use client";

// Reads of the swap panel: the markets it trades, pool spot price, exact-in quote, ETH/USD.

import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { usePublicClient, useReadContract, useReadContracts } from "wagmi";
import { formatUnits, parseAbi, zeroAddress, type Address } from "viem";
import { ethUsdFeed } from "./config";
import { chainlinkAbi, controllerAbi, erc20Abi, hookAbi, mevAbi, quoterAbi, stateViewAbi } from "./abis";
import { useHead, useSnapshot } from "./live";
import { SCOPE, lsGet, lsSet } from "./cache";
import { V4, ccPerEthFromSqrt, poolIdOf, poolKey, type PoolKey } from "./v4";

const DAY_BLOCKS = 7200n;
const BUCKET = 300n; // the 24h reference block moves once per hour, so the cached read is reused

// An eth/token v4 pool the swap panel trades: the token (currency1) and its pool key.
export type Market = { token: Address; symbol: string; decimals: number; key: PoolKey };

// The coin market. undefined until the Core snapshot has the coin.
export function useCcMarket(): Market | undefined {
  const coin = useSnapshot().data?.coin;
  return useMemo(() => (coin ? { token: coin, symbol: "cc", decimals: 18, key: poolKey(coin) } : undefined), [coin]);
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

// Swap fee of a hooked market, in bps: the pool's current skim plus the hook's
// LP fee (pips / 100). While the MEV module reports an active window, the skim
// is its decaying value (not below the baseline), `endsAt` is the window end in
// unix seconds and `perMin` the decay in bps per minute, both from the module's
// schedule(poolId) (startingSkimBps, endSkimBps, windowSeconds, startTime; undefined
// when the read fails). `baseBps` is the fee after the window: the higher of the
// schedule's end skim and the baseline skim, plus the LP fee. Refetched every
// 12 s (the head poll) while the window is active, every 60 s otherwise. null
// when a read fails.
// bps: skim plus lp fee, the swapper's total. skimBps: the skim alone. bountyBps: the bounty recipient's share of the skim.
export type HookFee = { bps: number; baseBps: number; skimBps: number; bountyBps: number; active: boolean; endsAt?: number; perMin?: number };

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
        const lp = Number(cfg.lpFeePips) / 100;
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
        return { bps: skim + lp, baseBps: end + lp, skimBps: skim, bountyBps: Number(cfg.bountyBps), active, endsAt, perMin };
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
// blockTag and kept in localStorage. undefined for any figure whose read fails.
export function useMarketStats(market?: Market) {
  const client = usePublicClient();
  const { data: perEth } = useTokensPerEth(market);
  const { data: ethUsd } = useEthUsd();
  const head = useHead().data?.n;
  const { data: supply } = useReadContract({ address: market?.token, abi: erc20Abi, functionName: "totalSupply", query: { enabled: Boolean(market) } });

  const ref = head != null && head > DAY_BLOCKS ? ((head - DAY_BLOCKS) / BUCKET) * BUCKET : undefined;
  const { data: perEthThen } = useQuery<number | null>({
    queryKey: ["spot24", market && poolIdOf(market.key), ref?.toString()],
    enabled: Boolean(client && market && ref),
    staleTime: Infinity,
    retry: false,
    queryFn: async () => {
      const id = poolIdOf(market!.key);
      const key = `${SCOPE}:spot24:${id}:${ref}`;
      const hit = lsGet<number>(key);
      if (hit != null) return hit;
      try {
        const [sqrt] = await client!.readContract({ address: V4.stateView, abi: stateViewAbi, functionName: "getSlot0", args: [id], blockNumber: ref });
        if (sqrt === 0n) return null;
        const v = ccPerEthFromSqrt(sqrt, market!.decimals);
        lsSet(key, v);
        return v;
      } catch {
        return null; // pruned state, or a pool younger than the reference block
      }
    },
  });

  const priceUsd = ethUsd != null && perEth ? ethUsd / perEth : undefined;
  const marketCap = priceUsd != null && supply != null && market ? priceUsd * Number(formatUnits(supply, market.decimals)) : undefined;
  const change = perEth && perEthThen != null ? (perEthThen / perEth - 1) * 100 : undefined;
  return { priceUsd, marketCap, change };
}
