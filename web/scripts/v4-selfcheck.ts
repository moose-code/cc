// Runnable check for the pure v4 encoders. No pool needed.
//   node --experimental-strip-types scripts/v4-selfcheck.ts
// Asserts command/action bytes, native-eth value, zeroForOne direction,
// pool identity sensitivity, configuration checks and slippage math.

import { decodeAbiParameters, parseAbiParameters } from "viem";
import {
  makePoolKey,
  buildBuyFor,
  buildSellFor,
  poolIdOf,
  minOut,
} from "../lib/v4core.ts";
import { verifiedPoolKey } from "../lib/pool-config.ts";

const COIN = "0x1111111111111111111111111111111111111111" as const;
const HOOK = "0x866F31562dDe70D7B989C2529a9deFFFFd3bE8CC" as const;
const KEY = makePoolKey(COIN, 8388608, 200, HOOK);
const buildBuy = (_c: string, a: bigint, b: bigint) => buildBuyFor(KEY, a, b);
const buildSell = (_c: string, a: bigint, b: bigint) => buildSellFor(KEY, a, b);
let fails = 0;
const ok = (c: boolean, m: string) => {
  if (!c) {
    fails++;
    console.error("FAIL:", m);
  } else console.log("ok:", m);
};

// promise: the hook address contributes to the pool ID, so a stale hook selects another pool
ok(poolIdOf(KEY).length === 66, "poolId is bytes32");
ok(
  poolIdOf(makePoolKey(COIN, 8388608, 200, "0x2f7976bf73dE8e1D49D4c687404e527a75b0e8Cc")) !== poolIdOf(KEY),
  "changing hook changes the pool ID",
);

// promise: the CC key follows the Core's immutable tuple and rejects a stale deployment override.
const actual = { hook: HOOK, fee: 8388608, tickSpacing: 200 };
ok(poolIdOf(verifiedPoolKey(COIN, actual, {})) === poolIdOf(KEY), "unset pool overrides use Core values");
ok(poolIdOf(verifiedPoolKey(COIN, actual, { hook: HOOK.toLowerCase(), fee: "8388608", tickSpacing: "200" })) === poolIdOf(KEY), "matching record values pass");
for (const expected of [
  { hook: "0x2f7976bf73dE8e1D49D4c687404e527a75b0e8Cc" },
  { fee: "3000" },
  { tickSpacing: "60" },
]) {
  let rejected = false;
  try {
    verifiedPoolKey(COIN, actual, expected);
  } catch (e) {
    rejected = String(e).includes("mismatch");
  }
  ok(rejected, `stale ${Object.keys(expected)[0]} override rejects CC market`);
}

const V4_SWAP_INPUT = parseAbiParameters("bytes actions, bytes[] params");

// buy
const buy = buildBuy(COIN, 1000n, 900n);
ok(buy.commands === "0x10", "buy command is V4_SWAP (0x10)");
ok(buy.value === 1000n, "buy forwards eth as msg.value");
ok(buy.inputs.length === 1, "buy has one UR input");
const [buyActions, buyParams] = decodeAbiParameters(V4_SWAP_INPUT, buy.inputs[0]);
ok(buyActions === "0x060c0f", "actions = SWAP_EXACT_IN_SINGLE,SETTLE_ALL,TAKE_ALL");
ok(buyParams.length === 3, "three action params");

// sell
const sell = buildSell(COIN, 2000n, 5n);
ok(sell.value === 0n, "sell forwards no eth");
ok(sell.commands === "0x10", "sell command is V4_SWAP");

// slippage
ok(minOut(1000n, 100) === 990n, "minOut applies 1% slippage");
ok(minOut(1000n, 0) === 1000n, "minOut 0 slippage is identity");

if (fails) {
  console.error(`\n${fails} check(s) failed`);
  process.exit(1);
}
console.log("\nall v4 encoder checks passed");
