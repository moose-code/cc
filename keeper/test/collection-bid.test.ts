// promise: fetchCollectionBid takes the best unexpired flat collection offer per item and drops what it cannot read:
// trait offers, non ETH/WETH, a missing or zero item count (never taken as one item), an expired or unreadable end
// time, and a malformed body (SEC-03 of the phase 3 audit)
import assert from "node:assert/strict";
import test from "node:test";
import { fetchCollectionBid } from "@cc/engine/opensea";

const future = String(Math.floor(Date.now() / 1000) + 3_600);
const past = String(Math.floor(Date.now() / 1000) - 60);
const offer = (value: string, over: Record<string, unknown> = {}) => ({
  order_hash: "0x" + "ab".repeat(32),
  price: { currency: "WETH", decimals: 18, value },
  criteria: { collection: { slug: "demo" }, trait: null },
  protocol_data: { parameters: { endTime: future, consideration: [{ startAmount: "1" }] } },
  ...over,
});
const serve = (body: unknown) => {
  globalThis.fetch = (async () => new Response(JSON.stringify(body), { status: 200 })) as typeof fetch;
};

test("fetchCollectionBid: the best readable flat offer per item", async () => {
  serve({ offers: [
    offer("90000000000000000", { protocol_data: { parameters: { endTime: future, consideration: [{ startAmount: "10" }] } } }),
    offer("8700000000000000"),
    offer("20000000000000000", { criteria: { collection: { slug: "demo" }, trait: { type: "x", value: "y" } } }),
    offer("30000000000000000", { price: { currency: "USDC", decimals: 6, value: "30000000" } }),
  ] });
  const r = await fetchCollectionBid({ key: "k", slug: "demo" });
  assert.equal(r?.bidWei, 9_000_000_000_000_000n, "a ten item 0.09 offer is 0.009 per item and beats 0.0087; trait and USDC offers are skipped");
});

test("fetchCollectionBid: an unreadable item count, an expired offer and a malformed body are dropped", async () => {
  serve({ offers: [offer("90000000000000000", { protocol_data: { parameters: { endTime: future, consideration: [{ startAmount: "garbage" }] } } })] });
  assert.equal(await fetchCollectionBid({ key: "k", slug: "demo" }), undefined, "a count that cannot be read is not one item");
  serve({ offers: [offer("90000000000000000", { protocol_data: { parameters: { endTime: future, consideration: [] } } })] });
  assert.equal(await fetchCollectionBid({ key: "k", slug: "demo" }), undefined, "a missing count is not one item");
  serve({ offers: [offer("90000000000000000", { protocol_data: { parameters: { endTime: past, consideration: [{ startAmount: "1" }] } } })] });
  assert.equal(await fetchCollectionBid({ key: "k", slug: "demo" }), undefined, "an expired offer is not a bid");
  serve({ offers: [offer("90000000000000000", { protocol_data: { parameters: { consideration: [{ startAmount: "1" }] } } })] });
  assert.equal(await fetchCollectionBid({ key: "k", slug: "demo" }), undefined, "an offer without an end time is not a bid");
  serve({ nope: true });
  assert.equal(await fetchCollectionBid({ key: "k", slug: "demo" }), undefined, "a malformed body answers nothing, the caller keeps its last observation");
  assert.equal(await fetchCollectionBid({ slug: "demo" }), undefined, "no key, no call");
});
