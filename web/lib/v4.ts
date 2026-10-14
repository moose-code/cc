// Config-bound v4 wrappers. Binds the launch pool params to the pure encoders
// in v4core.ts, keeping the app's call sites short.

import type { Address } from "viem";
import { pool } from "./config";
import { makePoolKey, buildBuyFor, buildSellFor, type PoolKey, type SwapCall } from "./v4core";

export { V4, ccPerEthFromSqrt, minOut, poolIdOf } from "./v4core";
export type { PoolKey, SwapCall } from "./v4core";

// The coin market's pool key: the launch params of config.pool.
export function poolKey(coin: Address): PoolKey {
  return makePoolKey(coin, pool.fee, pool.tickSpacing, pool.hook);
}

export const buildBuy = (key: PoolKey, ethIn: bigint, minTokenOut: bigint): SwapCall => buildBuyFor(key, ethIn, minTokenOut);

export const buildSell = (key: PoolKey, tokenIn: bigint, minEthOut: bigint): SwapCall => buildSellFor(key, tokenIn, minEthOut);
