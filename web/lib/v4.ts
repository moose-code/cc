// Config-bound v4 wrappers. Binds the pool params (read from the Core, see
// engine.ts poolParams) to the pure encoders in v4core.ts.

import type { Address } from "viem";
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

export interface PoolParams {
  hook: Address;
  fee: number;
  tickSpacing: number;
}

export function poolKey(coin: Address, p: PoolParams): PoolKey {
  return makePoolKey(coin, p.fee, p.tickSpacing, p.hook);
}

export function poolId(coin: Address, p: PoolParams) {
  return poolIdOf(poolKey(coin, p));
}

export function buildBuy(coin: Address, p: PoolParams, ethIn: bigint, minCcOut: bigint): SwapCall {
  return buildBuyFor(poolKey(coin, p), ethIn, minCcOut);
}

export function buildSell(coin: Address, p: PoolParams, ccIn: bigint, minEthOut: bigint): SwapCall {
  return buildSellFor(poolKey(coin, p), ccIn, minEthOut);
}
