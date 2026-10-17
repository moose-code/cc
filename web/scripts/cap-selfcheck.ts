import assert from "node:assert/strict";
import { decodeErrorResult, decodeFunctionResult, decodeEventLog, encodeAbiParameters, encodeErrorResult, encodeEventTopics, getAbiItem } from "viem";
import { coreAbi, engineEventsAbi } from "../lib/abis.ts";
import { CANCELLED, txError } from "@cc/engine/errors";
import { ETH_ANCHOR_SLOT, ethAnchorWords, replayEth, replayBalance, replayValue, type EthReplay } from "../lib/sell.ts";

// promise: every Settings field decodes in contract order without losing width at the maximum.
const settings = getAbiItem({ abi: coreAbi, name: "settings" });
const fields = settings.outputs[0].components;
assert.equal(fields.length, 39);
assert.deepEqual(fields.slice(28).map(({ name, type }) => [name, type]), [
  ["climbMultiplierCapBps", "uint16"], ["spendCapBps", "uint16"], ["bucketSeconds", "uint32"],
  ["balanceBidCapBps", "uint32"], ["idleStepSeconds", "uint32"], ["sniperSeconds", "uint32"],
  ["reserveWei", "uint64"], ["returnLockSeconds", "uint32"], ["valueModeOn", "bool"],
  ["buyToArtistBps", "uint16"], ["balanceDiscountBps", "uint16"],
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
const quote: EthReplay = { ...anchor, price: 1000n, peak: 1000n, pot: 10000n, dropPer100PointsBps: 100n, dropFloorBps: 9900n, ceilBps: 10000n, rateCap: 10000n, scorePer100Points: 1000n };
assert.equal(quote.nowBucket, 7n);
// The active bucket keeps its 994 floor; a new bucket would lower it to 990.
assert.equal(replayEth([1000n, 1000n], quote), 1000n + 994n);
assert.equal(replayEth([1000n, 1000n], { ...quote, nowBucket: 8n }), 1000n + 990n);

// promise: the balance bid is posted and flat: every credit of a batch pays score * unit * rate / 10000 (decision 164).
assert.equal(replayBalance([10n, 10n], { rate: 9000n, unit: 100n, scorePer100Points: 10n, dropPer100PointsBps: 10000n, dropFloorBps: 0n, floorBps: 9000n }), 900n + 900n);

// promise: a value mode eth sale pays the shared instance times the buy value per credit, dropping the instance to its floor.
{
  const v = { rate: 10000n, value: 100n, pot: 10n ** 18n, rateCap: 10n ** 18n, scorePer100Points: 10n, dropPer100PointsBps: 10000n, dropFloorBps: 0n, floorBps: 9000n };
  // the first credit at 10000 bps pays 100 * 100 wei, the drop lands on the 9000 floor, the second pays 9000 bps of it
  assert.equal(replayValue([10n, 10n], v), 10000n + 9000n);
  assert.equal(replayValue([10n], { ...v, rateCap: 500n }), 500n, "rateCap bounds a huge value");
  assert.equal(replayValue([10n, 10n], { ...v, pot: 12000n }), 10000n + 2000n, "the room bounds the batch");
}

// promise: the return lock error names the wait for decoded and selector-only transaction failures.
{
  const lockData = encodeErrorResult({ abi: coreAbi, errorName: "ReturnLocked", args: [7n, 86400n] });
  assert.equal(lockData.slice(0, 10), "0x8dd81991");
  assert.match(txError({ shortMessage: "reverted", data: { errorName: "ReturnLocked" } }), /return lock/);
  assert.match(txError({ shortMessage: "reverted with the following signature: 0x8dd81991" }), /return lock/);
}

// promise: the value mode quote error says the eth routes wait for the quote, decoded and selector-only.
{
  const quoteData = encodeErrorResult({ abi: coreAbi, errorName: "NoQuote" });
  assert.equal(quoteData, "0xc3186163");
  assert.match(txError({ shortMessage: "reverted", data: { errorName: "NoQuote" } }), /quote is unavailable/);
  assert.match(txError({ shortMessage: "reverted with the following signature: 0xc3186163" }), /quote is unavailable/);
}

// promise: the cap error names the next action for decoded and selector-only transaction failures.
const capError = encodeErrorResult({ abi: coreAbi, errorName: "SpendCapReached", args: [100n, 1n, 100n] });
const errorData = decodeErrorResult({ abi: coreAbi, data: capError });
assert.equal(errorData.errorName, "SpendCapReached");
assert.equal(txError({ cause: { data: errorData } }), "eth purchase budget exhausted, try again in the next bucket");
assert.equal(txError({ shortMessage: `reverted with the following signature: ${capError.slice(0, 10)}` }), "eth purchase budget exhausted, try again in the next bucket");
assert.equal(txError({ shortMessage: "user rejected the request" }), CANCELLED);
console.log("cap selfcheck ok");
