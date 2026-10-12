// Config-bound v4 wrappers. Binds the launch pool params to the pure encoders
// in v4core.ts, keeping the app's call sites short.

import type { Address } from "viem";
import { pool } from "./config";
import {
  makePoolKey,
  poolIdOf,
  buildBuyFor,
  buildSellFor,
  type PoolKey,
  type SwapCall,
} from "./v4core";

export { V4, ccPerEthFromSqrt, minOut } from "./v4core";
export type { PoolKey, SwapCall } from "./v4core";

export function poolKey(coin: Address): PoolKey {
  return makePoolKey(coin, pool.fee, pool.tickSpacing, pool.hook);
}

export function poolId(coin: Address) {
  return poolIdOf(poolKey(coin));
}

export function buildBuy(coin: Address, ethIn: bigint, minCcOut: bigint): SwapCall {
  return buildBuyFor(poolKey(coin), ethIn, minCcOut);
}

export function buildSell(coin: Address, ccIn: bigint, minEthOut: bigint): SwapCall {
  return buildSellFor(poolKey(coin), ccIn, minEthOut);
}
