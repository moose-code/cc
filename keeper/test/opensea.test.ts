// promise: OpenSea refreshes end within their request budget and a malformed listing leaves other signed orders usable
import { test } from "node:test";
import assert from "node:assert/strict";
import { fetchListings, CREDITS, SEAPORT_16 } from "@cc/engine/opensea";

const offerer = "0x00000000000000000000000000000000000000f1";
const zero = "0x0000000000000000000000000000000000000000";
const hash = "0x" + "11".repeat(32);
const basic = {
  considerationToken: zero, considerationIdentifier: "0", considerationAmount: "900", offerer,
  zone: zero, offerToken: CREDITS, offerIdentifier: "42", offerAmount: "1", basicOrderType: "0",
  startTime: "1", endTime: "9999999999", zoneHash: "0x" + "00".repeat(32), salt: "5",
  offererConduitKey: "0x" + "00".repeat(32), fulfillerConduitKey: "0x" + "00".repeat(32),
  totalOriginalAdditionalRecipients: "0", additionalRecipients: [], signature: "0xabcd",
};

test("OpenSea: a malformed page entry is dropped while a valid order is signed", async () => {
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (url: string | URL) => {
    const path = new URL(url).pathname;
    const body = path.includes("/contract/") ? { collection: "credits" }
      : path.endsWith("/best") ? { listings: [
        { protocol_address: SEAPORT_16, protocol_data: { parameters: { offer: null } } },
        { protocol_address: SEAPORT_16, order_hash: hash, protocol_data: { parameters: {
          offer: [{ itemType: 2, token: CREDITS, startAmount: "1", endAmount: "1", identifierOrCriteria: "42" }],
          consideration: [{ itemType: 0, token: zero, startAmount: "900", endAmount: "900", recipient: offerer }],
          orderType: 0, offerer, startTime: "1", endTime: "9999999999",
        } } },
      ] } : { fulfillment_data: { transaction: { function: "fulfillBasicOrder_efficient_6GL6yc", input_data: { parameters: basic } } } };
    return new Response(JSON.stringify(body), { status: 200 });
  }) as typeof fetch;
  try {
    const r = await fetchListings({ key: "test", pages: 1, sign: 1 });
    assert.equal(r.fetched, 2);
    assert.equal(r.dropped["malformed listing"], 1);
    assert.deepEqual(r.orders.map((o) => o.id), ["42"]);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("OpenSea: a stalled request is aborted by the whole-refresh timeout", async () => {
  const realFetch = globalThis.fetch;
  const keepAlive = setInterval(() => {}, 1_000);
  globalThis.fetch = ((_url: unknown, init: RequestInit) => new Promise((_resolve, reject) => {
    init.signal?.addEventListener("abort", () => reject(init.signal?.reason), { once: true });
  })) as typeof fetch;
  try {
    await assert.rejects(fetchListings({ key: "test", timeoutMs: 10 }), /timeout|Timeout/i);
  } finally {
    clearInterval(keepAlive);
    globalThis.fetch = realFetch;
  }
});

test("OpenSea: a malformed fulfillment does not discard another signed order", async () => {
  const realFetch = globalThis.fetch;
  const badHash = "0x" + "22".repeat(32);
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    const path = new URL(url).pathname;
    const body = path.includes("/contract/") ? { collection: "credits" }
      : path.endsWith("/best") ? { listings: ["42", "43"].map((id, i) => ({
        protocol_address: SEAPORT_16, order_hash: i ? badHash : hash, protocol_data: { parameters: {
          offer: [{ itemType: 2, token: CREDITS, startAmount: "1", endAmount: "1", identifierOrCriteria: id }],
          consideration: [{ itemType: 0, token: zero, startAmount: "900", endAmount: "900", recipient: offerer }],
          orderType: 0, offerer, startTime: "1", endTime: "9999999999",
        } },
      })) }
      : { fulfillment_data: { transaction: { function: "fulfillBasicOrder_efficient_6GL6yc", input_data: {
        parameters: JSON.parse(String(init?.body)).listing.hash === badHash ? { ...basic, additionalRecipients: null } : basic,
      } } } };
    return new Response(JSON.stringify(body), { status: 200 });
  }) as typeof fetch;
  try {
    const r = await fetchListings({ key: "test", pages: 1, sign: 2 });
    assert.equal(r.dropped["malformed fulfillment"], 1);
    assert.deepEqual(r.orders.map((o) => o.id), ["42"]);
  } finally {
    globalThis.fetch = realFetch;
  }
});
