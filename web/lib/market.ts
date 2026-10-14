"use client";

// Reads of the swap panel: pool spot price, exact-in quote, ETH/USD.

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import type { Address } from "viem";
import { ethUsdFeed } from "./config";
import { chainlinkAbi, quoterAbi, stateViewAbi } from "./abis";
import { V4, ccPerEthFromSqrt, poolId, poolKey } from "./v4";

// Coin per 1 eth from the pool slot0. undefined while the pool has no price.
export function useCcPerEth(coin?: Address) {
  const client = usePublicClient();
  return useQuery<number | undefined>({
    queryKey: ["spot", coin],
    enabled: Boolean(client && coin),
    refetchInterval: 15000,
    queryFn: async () => {
      try {
        const [sqrt] = await client!.readContract({
          address: V4.stateView,
          abi: stateViewAbi,
          functionName: "getSlot0",
          args: [poolId(coin!)],
        });
        return sqrt > 0n ? ccPerEthFromSqrt(sqrt) : undefined;
      } catch {
        return undefined;
      }
    },
  });
}

// Exact-in quote from the v4 Quoter: amountOut in wei, undefined when the quote reverts.
export function useQuote(coin: Address | undefined, side: "buy" | "sell", amountIn: bigint) {
  const client = usePublicClient();
  return useQuery<bigint | undefined>({
    queryKey: ["quote", coin, side, amountIn.toString()],
    enabled: Boolean(client && coin) && amountIn > 0n,
    refetchInterval: 15000,
    queryFn: async () => {
      try {
        const [out] = await client!.readContract({
          address: V4.quoter,
          abi: quoterAbi,
          functionName: "quoteExactInputSingle",
          args: [{ poolKey: poolKey(coin!), zeroForOne: side === "buy", exactAmount: amountIn, hookData: "0x" }],
        });
        return out;
      } catch {
        return undefined;
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
