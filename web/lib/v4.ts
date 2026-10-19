// V4 swap wrappers around the pure encoders in v4core.ts.

import { buildBuyFor, buildSellFor, type PoolKey, type SwapCall } from "./v4core";

export { V4, ccPerEthFromSqrt, minOut, poolIdOf } from "./v4core";
export type { PoolKey, SwapCall } from "./v4core";
export { verifiedPoolKey as poolKey } from "./pool-config";

export const buildBuy = (key: PoolKey, ethIn: bigint, minTokenOut: bigint): SwapCall => buildBuyFor(key, ethIn, minTokenOut);

export const buildSell = (key: PoolKey, tokenIn: bigint, minEthOut: bigint): SwapCall => buildSellFor(key, tokenIn, minEthOut);
