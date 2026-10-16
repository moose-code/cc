// Cross-check of lib/climb.ts against the Core: ethRate() read with a later block timestamp (blockOverrides) vs the forecast.
//   node --experimental-strip-types scripts/climb-xcheck.ts   (reads NEXT_PUBLIC_RPC_URL, NEXT_PUBLIC_CORE from .env.local)
import { createPublicClient, http, numberToHex, parseAbi } from "viem";
import { readFileSync } from "node:fs";
import { bidAt, priceAt, type ClimbState } from "../lib/climb.ts";
import { coreAbi } from "../lib/abis.ts";
const env = Object.fromEntries(readFileSync(new URL("../.env.local", import.meta.url), "utf8").split("\n").filter((l) => l.includes("=")).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));
const core = env.NEXT_PUBLIC_CORE as `0x${string}`;
const c = createPublicClient({ transport: http(env.NEXT_PUBLIC_RPC_URL) });
const word = (i: bigint) => c.getStorageAt({ address: core, slot: numberToHex(27n + i, { size: 32 }) });
const blk = await c.getBlock();
const bn = blk.number;
const rd = (fn: any, args?: any[]) => c.readContract({ address: core, abi: coreAbi, functionName: fn, args, blockNumber: bn } as any) as Promise<any>;
const [st, r, t, lf, pot, w0, w2, w3] = await Promise.all([rd("settings"), rd("rateAtCheckpoint"), rd("checkpointTime"), rd("lastFillTime"), rd("ethPot"), word(0n), word(2n), word(3n)]);
const s = st as any;
const mul = await rd("climbMultiplier").catch(() => 10_000n);
const state: ClimbState = { r, t: Number(t), anchorTime: Number(lf), lastFillRate: BigInt(w0!), peakRate: BigInt(w3!), peakTime: Number((BigInt(w2!) >> 64n) & ((1n << 64n) - 1n)), ceilBps: s.ceilBps, idleLoosenBps: s.idleLoosenBps, idleStepSeconds: s.idleStepSeconds, climbMultiplierBps: Number(mul), rateCap: BigInt(s.rateCap), peakHalfLife: s.peakHalfLife, climbPerMinBps: s.climbPerMinBps, recoveryClimbPerMinBps: s.recoveryClimbPerMinBps, recoveryGapBps: s.recoveryGapBps, ethPot: pot, pending: 0n };
console.log("state", { r, t, lf, pot, lastFill: state.lastFillRate, peak: state.peakRate, peakTime: state.peakTime, blk: blk.timestamp });
const id = 1n;
for (const dt of [0, 60, 600, 3600, 6 * 3600, 24 * 3600, 5 * 86400]) {
  const ts = blk.timestamp + BigInt(dt);
  let live: bigint | string;
  try {
    live = await c.readContract({ address: core, abi: coreAbi, functionName: "ethRate", blockNumber: bn, blockOverrides: { time: ts } } as any) as bigint;
  } catch (e: any) { live = "ERR " + String(e.shortMessage ?? e.message).slice(0, 80); }
  const mine = Math.floor(Math.min(priceAt(state, Number(ts)), Number(pot)));
  console.log(dt, "live", live.toString(), "mine", mine, typeof live === "bigint" ? (Number(live) / mine - 1).toExponential(2) : "");
}
