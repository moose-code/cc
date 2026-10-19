// promise: the snapshot preserves the zero ETH bid the Core returns for an unusable protected quote.
import assert from "node:assert/strict";
import test from "node:test";
import { zeroAddress, type PublicClient } from "viem";
import { readSnapshot } from "@cc/engine/snapshot";

const core = "0x1111111111111111111111111111111111111111";
const controller = "0x2222222222222222222222222222222222222222";
const coin = "0x3333333333333333333333333333333333333333";
const bid = 4_900_000_000_000_000n;

function client(usable: boolean, valueModeOn: boolean) {
  return {
    getBlockNumber: async () => 100n,
    multicall: async ({ contracts, allowFailure }: { contracts: readonly { functionName: string; args?: readonly unknown[] }[]; allowFailure?: boolean }) => {
      const result = (call: { functionName: string; args?: readonly unknown[] }) => {
        switch (call.functionName) {
          case "settings": return { valueModeOn, payeePpm: 0, feeToRedeemBurnBps: 0 };
          case "controller": return controller;
          case "COIN": return coin;
          case "balanceModule": case "balanceToken": case "payee": case "artist": return zeroAddress;
          case "heldStatements": return [];
          case "nextPage": return [false, [], 0];
          case "creditSaleOn": case "paused": case "retired": case "chosenComposeOn": case "payeeOn": return false;
          case "ethRate": case "ethPrice": return valueModeOn && !usable ? 0n : bid;
          case "valuePerPoint": return [10n, usable];
          case "spotPrice": return [10n, true];
          case "quote": return [0, 0, 0, 0, 0, 0n];
          default: return 0n;
        }
      };
      return contracts.map((call) => allowFailure ? { status: "success", result: result(call) } : result(call));
    },
  } as unknown as Pick<PublicClient, "getBlockNumber" | "multicall">;
}

test("snapshot flags a lapsed quote and preserves the Core's zero bid", async () => {
  const lapsed = await readSnapshot(client(false, true), core);
  assert.equal(lapsed.noQuote, true);
  assert.equal(lapsed.ethRate, 0n);
  assert.equal(lapsed.ethPrice, 0n);
  assert.equal(lapsed.value.usable, false);

  const restored = await readSnapshot(client(true, true), core);
  assert.equal(restored.noQuote, false);
  assert.equal(restored.ethRate, bid);

  const modeOff = await readSnapshot(client(false, false), core);
  assert.equal(modeOff.noQuote, false);
  assert.equal(modeOff.ethRate, bid);
});
