import type { Address } from "viem";
import { makePoolKey, type PoolKey } from "./v4core.ts";

type PoolSettings = { hook: Address; fee: number; tickSpacing: number };
type ExpectedPool = { hook?: string; fee?: string; tickSpacing?: string };

// Core fixes the CC pool tuple at deployment. Explicit web settings are checks,
// never a replacement for the values read from that Core.
export function verifiedPoolKey(coin: Address, actual: PoolSettings, expected: ExpectedPool): PoolKey {
  if (expected.hook !== undefined && expected.hook !== "") {
    if (!/^0x[0-9a-fA-F]{40}$/.test(expected.hook) || expected.hook.toLowerCase() !== actual.hook.toLowerCase())
      throw new Error(`CC pool hook mismatch: configured ${expected.hook}, Core ${actual.hook}`);
  }
  for (const [name, configured, onchain] of [
    ["fee", expected.fee, actual.fee],
    ["tick spacing", expected.tickSpacing, actual.tickSpacing],
  ] as const) {
    if (configured !== undefined && configured !== "" && (!/^\d+$/.test(configured) || Number(configured) !== onchain))
      throw new Error(`CC pool ${name} mismatch: configured ${configured}, Core ${onchain}`);
  }
  return makePoolKey(coin, actual.fee, actual.tickSpacing, actual.hook);
}
