"use client";

// Reads of the swap panel: the markets it trades, pool spot price, exact-in quote, ETH/USD.

import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { usePublicClient, useReadContract, useReadContracts } from "wagmi";
import { formatUnits, zeroAddress, type Address } from "viem";
import { core, ethUsdFeed } from "./config";
import { chainlinkAbi, controllerAbi, coreAbi, erc20Abi, hookAbi, mevAbi, quoterAbi, stateViewAbi } from "./abis";
import { MULTICALL3, useHead, useSnapshot } from "./live";
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

// Swap fee in bps of a hooked market: the pool's current skim (the MEV module's
// value when one is set, else the baseline) plus the hook's LP fee (pips / 100).
// null when a read fails.
export function useHookFeeBps(market?: Market) {
  const client = usePublicClient();
  const hook = market?.key.hooks;
  const on = Boolean(client && market && hook !== zeroAddress);
  return useQuery<number | null>({
    queryKey: ["hook-fee", market && poolIdOf(market.key)],
    enabled: on,
    staleTime: 60000,
    queryFn: async () => {
      try {
        const id = poolIdOf(market!.key);
        const [cfg, info] = await Promise.all([
          client!.readContract({ address: hook!, abi: hookAbi, functionName: "skimConfig", args: [id] }),
          client!.readContract({ address: hook!, abi: hookAbi, functionName: "poolInfo", args: [id] }),
        ]);
        let skim = Number(cfg.baselineSkimBps);
        if (info.mevModule !== zeroAddress) {
          const [now] = await client!.readContract({ address: info.mevModule, abi: mevAbi, functionName: "currentSkimBps", args: [id] });
          skim = Number(now);
        }
        return skim + Number(cfg.lpFeePips) / 100;
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

// Engine pots read at the latest block: `pot` is ethPot plus the share of the
// unbooked fee income that the next Core._book adds (Core._income, _split),
// `bid` is ethRate, `balancePot` is the balance token pot.
export type Pots = { pot: bigint; bid: bigint; balancePot: bigint };

export async function readPots(client: NonNullable<ReturnType<typeof usePublicClient>>): Promise<Pots> {
  const c = { address: core!, abi: coreAbi } as const;
  const [[bid, ethPot, toBuyback, redeemBurn, owed, balancePot, payeeOn, st], held] = await Promise.all([
    client.multicall({
      multicallAddress: MULTICALL3,
      allowFailure: false,
      contracts: [
        { ...c, functionName: "ethRate" },
        { ...c, functionName: "ethPot" },
        { ...c, functionName: "ethToBuyback" },
        { ...c, functionName: "ethRedeemBurn" },
        { ...c, functionName: "payeeOwed" },
        { ...c, functionName: "balancePot" },
        { ...c, functionName: "payeeOn" },
        { ...c, functionName: "settings" },
      ] as const,
    }),
    client.getBalance({ address: core! }),
  ]);
  const booked = ethPot + toBuyback + redeemBurn + owed;
  const income = held > booked ? held - booked : 0n;
  const toPayee = payeeOn ? (income * BigInt(st.payeePpm)) / 1_000_000n : 0n;
  const toRedeemBurn = ((income - toPayee) * BigInt(st.feeToRedeemBurnBps)) / 10000n;
  return { pot: ethPot + income - toPayee - toRedeemBurn, bid, balancePot };
}
