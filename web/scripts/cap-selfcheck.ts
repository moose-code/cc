import assert from "node:assert/strict";
import { decodeErrorResult, decodeFunctionResult, decodeEventLog, encodeAbiParameters, encodeErrorResult, encodeEventTopics, getAbiItem } from "viem";
import { coreAbi, engineEventsAbi } from "../lib/abis.ts";
import { CANCELLED, txError } from "@cc/engine/errors";
import { ETH_ANCHOR_SLOT, ethAnchorWords, replayEth, replayBalance, type EthReplay } from "../lib/sell.ts";

// promise: every Settings field decodes in contract order without losing width at the maximum.
const settings = getAbiItem({ abi: coreAbi, name: "settings" });
const fields = settings.outputs[0].components;
assert.equal(fields.length, 34);
assert.deepEqual(fields.slice(28).map(({ name, type }) => [name, type]), [
  ["climbMultiplierCapBps", "uint16"], ["spendCapBps", "uint16"], ["bucketSeconds", "uint32"],
  ["balanceBidCapBps", "uint32"], ["idleStepSeconds", "uint32"], ["sniperSeconds", "uint32"],
]);
const maxValues = fields.map(({ type }) => type === "bool" ? true : (1n << BigInt(type.slice(4))) - 1n);
const data = encodeAbiParameters([{ type: "tuple", components: fields }], [maxValues] as any);
const decoded = decodeFunctionResult({ abi: coreAbi, functionName: "settings", data });
fields.forEach(({ name, type }, i) => assert.equal(BigInt(decoded[name]), type === "bool" ? 1n : maxValues[i]));
const event = decodeEventLog({ abi: engineEventsAbi, data, topics: encodeEventTopics({ abi: engineEventsAbi, eventName: "SettingsSet" }) });
assert.equal(event.eventName, "SettingsSet");
if (event.eventName === "SettingsSet") assert.deepEqual(event.args.settings, decoded);

// promise: packed anchor reads and non-default bucket lengths quote the active bucket's drop floor.
assert.equal(ETH_ANCHOR_SLOT, 28n);
const max64 = (1n << 64n) - 1n;
assert.deepEqual(ethAnchorWords(1000n, (1234n << 64n) | max64, max64, 1n), { start: 1000n, bucket: max64, nowBucket: max64 });
const anchor = ethAnchorWords(1005n, (1234n << 64n) | 7n, 90n, 12n);
const quote: EthReplay = { ...anchor, price: 1000n, peak: 1000n, pot: 10000n, dropPerCreditBps: 100n, dropFloorBps: 9900n, ceilBps: 10000n, rateCap: 10000n, refScore: 1000n };
assert.equal(quote.nowBucket, 7n);
// The active bucket keeps its 994 floor; a new bucket would lower it to 990.
assert.equal(replayEth([1000n, 1000n], quote), 1000n + 994n);
assert.equal(replayEth([1000n, 1000n], { ...quote, nowBucket: 8n }), 1000n + 990n);

// promise: a raised balance cap does not raise the floor above par minus the margin.
assert.equal(replayBalance([10n, 10n], { rate: 100000n, unit: 100n, refScore: 10n, dropPerCreditBps: 10000n, dropFloorBps: 0n, floorBps: 9000n }), 10000n + 900n);

// promise: the cap error names the next action for decoded and selector-only transaction failures.
const capError = encodeErrorResult({ abi: coreAbi, errorName: "SpendCapReached", args: [100n, 1n, 100n] });
const errorData = decodeErrorResult({ abi: coreAbi, data: capError });
assert.equal(errorData.errorName, "SpendCapReached");
assert.equal(txError({ cause: { data: errorData } }), "eth purchase budget exhausted, try again in the next bucket");
assert.equal(txError({ shortMessage: `reverted with the following signature: ${capError.slice(0, 10)}` }), "eth purchase budget exhausted, try again in the next bucket");
assert.equal(txError({ shortMessage: "user rejected the request" }), CANCELLED);
console.log("cap selfcheck ok");
