// promise: the keeper reads the phase 2 treasury's conversionReady() tolerantly, so a module without the view (the
// StatementBalanceModule path) reads undefined and is treated as ready, while a treasury's false answer is kept.
import assert from "node:assert/strict";
import test from "node:test";
import { zeroAddress, type Address, type PublicClient } from "viem";
import { readConversionReady } from "../src/chain.ts";

const module = "0x00000000000000000000000000000000000000b0" as Address;

function client(answer: { status: "success"; result: boolean } | { status: "failure"; error: Error }) {
  const calls: { functionName: string; address: Address; blockNumber?: bigint }[] = [];
  const c = {
    multicall: async ({ contracts, allowFailure, blockNumber }: { contracts: readonly { functionName: string; address: Address }[]; allowFailure?: boolean; blockNumber?: bigint }) => {
      assert.equal(allowFailure, true);
      for (const call of contracts) calls.push({ functionName: call.functionName, address: call.address, blockNumber });
      return contracts.map(() => answer);
    },
  } as unknown as Pick<PublicClient, "multicall">;
  return { c, calls };
}

test("conversionReady: a treasury's answer is kept, pinned to the block", async () => {
  const yes = client({ status: "success", result: true });
  assert.equal(await readConversionReady(yes.c, module, 77n), true);
  assert.deepEqual(yes.calls, [{ functionName: "conversionReady", address: module, blockNumber: 77n }]);
  const no = client({ status: "success", result: false });
  assert.equal(await readConversionReady(no.c, module, 77n), false);
});

test("conversionReady: a module without the view reads undefined; no module reads nothing", async () => {
  const old = client({ status: "failure", error: new Error("execution reverted") });
  assert.equal(await readConversionReady(old.c, module, 77n), undefined);
  const none = client({ status: "success", result: true });
  assert.equal(await readConversionReady(none.c, zeroAddress, 77n), undefined);
  assert.equal(none.calls.length, 0);
});
