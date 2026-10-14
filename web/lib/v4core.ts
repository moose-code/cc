// Pure Uniswap v4 encoders. viem-only, no app imports, so both the app and the
// node self-check load it cleanly. config-bound wrappers live in v4.ts.
//
// Addresses verified against docs.uniswap.org/contracts/v4/deployments (chain
// 1; the local anvil fork has the same ones). Command/action ids verified
// against v4-periphery Actions.sol and the Universal Router commands. The
// encoders are covered by scripts/v4-selfcheck.ts.

import {
  encodeAbiParameters,
  encodePacked,
  keccak256,
  parseAbiParameters,
  zeroAddress,
  type Address,
  type Hex,
} from "viem";

export const V4 = {
  poolManager: "0x000000000004444c5dc75cB358380D2e3dE08A90" as Address,
  stateView: "0x7ffe42c4a5deea5b0fec41c94c136cf115597227" as Address,
  quoter: "0x52f0e24d1c21c8a0cb1e5a5dd6198556bd9e1203" as Address,
  universalRouter: "0x66a9893cc07d91d95644aedd05d03f95e1dba8af" as Address,
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3" as Address,
};

const CMD_V4_SWAP = 0x10;
const ACT_SWAP_EXACT_IN_SINGLE = 0x06;
const ACT_SETTLE_ALL = 0x0c;
const ACT_TAKE_ALL = 0x0f;

export interface PoolKey {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

const POOL_KEY_ABI = parseAbiParameters(
  "(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)"
);

// Native ETH (address(0)) is currency0; the coin is currency1.
export function makePoolKey(
  coin: Address,
  fee: number,
  tickSpacing: number,
  hooks: Address
): PoolKey {
  return { currency0: zeroAddress, currency1: coin, fee, tickSpacing, hooks };
}

export function poolIdOf(key: PoolKey): Hex {
  return keccak256(encodeAbiParameters(POOL_KEY_ABI, [key]));
}

// CC per 1 ETH from sqrtPriceX96. Both currencies are 18 decimals, so no
// decimal shift. price = (sqrt/2^96)^2 = token1/token0 = CC per ETH.
export function ccPerEthFromSqrt(sqrtPriceX96: bigint): number {
  const s = Number(sqrtPriceX96) / 2 ** 96;
  return s * s;
}

const EXACT_IN_SINGLE_ABI = parseAbiParameters(
  "((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, bool zeroForOne, uint128 amountIn, uint128 amountOutMinimum, bytes hookData)"
);
const CURRENCY_AMOUNT_ABI = parseAbiParameters("address currency, uint256 amount");
const V4_SWAP_INPUT_ABI = parseAbiParameters("bytes actions, bytes[] params");

function encodeV4Swap(
  key: PoolKey,
  zeroForOne: boolean,
  amountIn: bigint,
  minAmountOut: bigint
): Hex {
  const inputCurrency = zeroForOne ? key.currency0 : key.currency1;
  const outputCurrency = zeroForOne ? key.currency1 : key.currency0;
  const actions = encodePacked(
    ["uint8", "uint8", "uint8"],
    [ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE_ALL, ACT_TAKE_ALL]
  );
  const swapParam = encodeAbiParameters(EXACT_IN_SINGLE_ABI, [
    { poolKey: key, zeroForOne, amountIn, amountOutMinimum: minAmountOut, hookData: "0x" },
  ] as any);
  const settleParam = encodeAbiParameters(CURRENCY_AMOUNT_ABI, [inputCurrency, amountIn]);
  const takeParam = encodeAbiParameters(CURRENCY_AMOUNT_ABI, [outputCurrency, minAmountOut]);
  return encodeAbiParameters(V4_SWAP_INPUT_ABI, [actions, [swapParam, settleParam, takeParam]]);
}

export interface SwapCall {
  commands: Hex;
  inputs: Hex[];
  value: bigint; // native ETH to forward (buy only)
}

// buy: exact ETH in -> CC out. Forwards msg.value = amountIn.
export function buildBuyFor(key: PoolKey, ethIn: bigint, minCcOut: bigint): SwapCall {
  return {
    commands: encodePacked(["uint8"], [CMD_V4_SWAP]),
    inputs: [encodeV4Swap(key, true, ethIn, minCcOut)],
    value: ethIn,
  };
}

// sell: exact CC in -> ETH out. Needs a prior Permit2 allowance (CC -> UR).
export function buildSellFor(key: PoolKey, ccIn: bigint, minEthOut: bigint): SwapCall {
  return {
    commands: encodePacked(["uint8"], [CMD_V4_SWAP]),
    inputs: [encodeV4Swap(key, false, ccIn, minEthOut)],
    value: 0n,
  };
}

export function minOut(amountOut: bigint, slippageBps: number): bigint {
  return (amountOut * BigInt(10000 - slippageBps)) / 10000n;
}
