import { test } from "node:test";
import assert from "node:assert/strict";
import { startOpenSeaStream } from "../src/opensea-stream.ts";
import { CREDITS } from "@cc/engine/addresses";

class FakeSocket {
  static instances: FakeSocket[] = [];
  static fail = false;
  sent: any[][] = [];
  closed = false;
  listeners = new Map<string, ((value: any) => void)[]>();
  constructor(_url: string) {
    if (FakeSocket.fail) throw new Error("private URL must never escape");
    FakeSocket.instances.push(this);
  }
  addEventListener(event: string, callback: (value: any) => void) {
    this.listeners.set(event, [...(this.listeners.get(event) ?? []), callback]);
  }
  emit(event: string, value: any = {}) { for (const cb of this.listeners.get(event) ?? []) cb(value); }
  frame(frame: any[]) { this.emit("message", { data: JSON.stringify(frame) }); }
  send(data: string) { this.sent.push(JSON.parse(data)); }
  close() { this.closed = true; this.emit("close"); }
  join() { this.emit("open"); this.frame(["1", "1", "collection:credits", "phx_reply", { status: "ok" }]); }
}
const hash = "0x" + "ab".repeat(32);
const payload = (event = "item_listed") => ({ event_type: event, payload: {
  collection: { slug: "credits" }, chain: "ethereum", item: { nft_id: `ethereum/${CREDITS}/42`, chain: { name: "ethereum" } }, order_hash: hash,
} });
function setup(t: any, callbacks: any = {}) {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const original = globalThis.WebSocket;
  FakeSocket.instances = [];
  FakeSocket.fail = false;
  globalThis.WebSocket = FakeSocket as any;
  const changes: any[] = [], statuses: boolean[] = [];
  let gaps = 0;
  const stream = startOpenSeaStream({ key: "fixture-only", onChange: v => { changes.push(v); }, onGap: () => { gaps++; }, onStatus: v => { statuses.push(v); }, ...callbacks });
  t.after(() => { stream.stop(); globalThis.WebSocket = original; });
  return { stream, changes, statuses, gaps: () => gaps };
}

// promise: a successful collection join resolves readiness and emits only canonical-refresh hints.
test("joins only required events and validates Credits identity", async t => {
  const s = setup(t), ws = FakeSocket.instances[0];
  ws.join();
  assert.equal(await s.stream.ready, true);
  assert.deepEqual(ws.sent[0].slice(0, 4), ["1", "1", "collection:credits", "phx_join"]);
  assert.deepEqual(ws.sent[0][4].event_types, ["item_listed", "item_sold", "item_transferred", "item_cancelled", "order_invalidate", "order_revalidate"]);
  for (const event of ws.sent[0][4].event_types) ws.frame(["1", null, "collection:credits", event, payload(event)]);
  assert.equal(s.changes.length, 6);
  assert.deepEqual(s.changes[0], { event: "item_listed", hash, id: 42n });
  const idOnly = payload("item_transferred"); delete (idOnly.payload as any).order_hash;
  ws.frame(["1", null, "collection:credits", "item_transferred", idOnly]);
  assert.deepEqual(s.changes.at(-1), { event: "item_transferred", id: 42n });
  const hashOnly = payload("order_invalidate"); delete (hashOnly.payload as any).item;
  ws.frame(["1", null, "collection:credits", "order_invalidate", hashOnly]);
  assert.deepEqual(s.changes.at(-1), { event: "order_invalidate", hash });
  assert.deepEqual(s.statuses, [true]);
  assert.equal(s.gaps(), 1);
});

// promise: foreign, malformed, oversized and unjoined frames cannot change cached listings.
test("rejects malformed and foreign event identities", t => {
  const s = setup(t), ws = FakeSocket.instances[0];
  ws.frame(["1", null, "collection:credits", "item_listed", payload()]);
  assert.equal(s.changes.length, 0);
  ws.join();
  const foreign = [
    { event_type: "item_listed", payload: { ...payload().payload, collection: { slug: "other" } } },
    { event_type: "item_listed", payload: { ...payload().payload, chain: "polygon" } },
    { event_type: "item_listed", payload: { ...payload().payload, item: { nft_id: "ethereum/0x0000000000000000000000000000000000000000/42" } } },
  ];
  for (const p of foreign) ws.frame(["1", null, "collection:credits", "item_listed", p]);
  ws.frame(["1", null, "collection:other", "item_listed", payload()]);
  ws.frame(["2", null, "collection:credits", "item_listed", payload()]);
  ws.frame(["1", null, "collection:credits", "item_received_bid", payload("item_received_bid")]);
  assert.equal(s.gaps(), 1);
  const invalid = [
    { ...payload(), event_type: "item_sold" },
    { event_type: "item_listed", payload: { ...payload().payload, item: { nft_id: `ethereum/${CREDITS}/${1n << 256n}` } } },
    { event_type: "item_listed", payload: { ...payload().payload, order_hash: "bad" } },
    { event_type: "item_listed", payload: { collection: { slug: "credits" }, order_hash: hash } },
    { event_type: "item_listed" },
  ];
  for (const p of invalid) {
    const before = s.gaps();
    ws.frame(["1", null, "collection:credits", "item_listed", p]);
    assert.equal(s.gaps(), before + 1);
  }
  const before = s.gaps();
  ws.emit("message", { data: "{" });
  ws.emit("message", { data: new Uint8Array(1) });
  ws.frame(["1", null, "collection:credits"]);
  ws.emit("message", { data: "{}" });
  assert.equal(s.gaps(), before + 4);
  assert.equal(s.changes.length, 0);
  ws.emit("message", { data: "x".repeat(1_048_577) });
  assert.equal(ws.closed, true);
  assert.deepEqual(s.statuses, [true, false]);
});

// promise: missing heartbeat acknowledgement detects a gap, reconnects and requests reconciliation.
test("heartbeat acknowledgement and reconnect lifecycle are bounded", async t => {
  const s = setup(t), first = FakeSocket.instances[0];
  first.join();
  assert.equal(await s.stream.ready, true);
  t.mock.timers.tick(30_000);
  assert.deepEqual(first.sent.at(-1), [null, "2", "phoenix", "heartbeat", {}]);
  first.frame([null, "2", "phoenix", "phx_reply", { status: "ok" }]);
  t.mock.timers.tick(30_000);
  assert.equal(first.closed, false);
  assert.deepEqual(first.sent.at(-1), [null, "3", "phoenix", "heartbeat", {}]);
  t.mock.timers.tick(30_000);
  assert.equal(first.closed, true);
  assert.equal(s.gaps(), 2);
  t.mock.timers.tick(1_000);
  const second = FakeSocket.instances[1];
  second.join();
  first.frame(["1", null, "collection:credits", "item_listed", payload()]);
  assert.equal(s.changes.length, 0);
  assert.equal(s.gaps(), 3);
  s.stream.stop(); s.stream.stop();
  t.mock.timers.tick(300_000);
  assert.equal(FakeSocket.instances.length, 2);
  assert.equal(second.closed, true);
});

// promise: failed joins use capped backoff and initial readiness never waits longer than ten seconds.
test("failure backoff, join deadline and stop settle without exposing errors", async t => {
  const s = setup(t);
  for (const wait of [1_000, 2_000, 5_000, 10_000, 30_000, 30_000]) {
    FakeSocket.instances.at(-1)!.emit("error", { error: new Error("private URL") });
    const before = FakeSocket.instances.length;
    t.mock.timers.tick(wait - 1);
    assert.equal(FakeSocket.instances.length, before);
    t.mock.timers.tick(1);
    assert.equal(FakeSocket.instances.length, before + 1);
  }
  assert.equal(await s.stream.ready, false);
  assert.equal(s.statuses.every(v => v === false), true);
  s.stream.stop();
  t.mock.timers.tick(100_000);
  assert.equal(FakeSocket.instances.length, 7);
});

// promise: callbacks cannot break the transport, and an early stop leaves no pending readiness or connection.
test("isolates callbacks and settles early stop", async t => {
  const s = setup(t, { onChange: () => Promise.reject(new Error("callback")), onGap: () => { throw new Error("callback"); } });
  const ws = FakeSocket.instances[0]; ws.join();
  ws.frame(["1", null, "collection:credits", "item_listed", payload()]);
  await Promise.resolve();
  ws.frame(["1", null, "collection:credits", "item_transferred", payload("item_transferred")]);
  assert.equal(ws.closed, false);
  s.stream.stop();
  t.mock.timers.tick(100_000);
  assert.equal(FakeSocket.instances.length, 1);
});

// promise: a never-opened connection times out and stopping before the first join resolves readiness false.
test("connect timeout and early stop", async t => {
  const s = setup(t), first = FakeSocket.instances[0];
  t.mock.timers.tick(10_000);
  assert.equal(await s.stream.ready, false);
  assert.equal(first.closed, true);
  s.stream.stop();
  const early = startOpenSeaStream({ key: "fixture-only", onChange() {}, onGap() {}, onStatus() {} });
  early.stop();
  assert.equal(await early.ready, false);
});

// promise: callback-triggered stop cannot be followed by a joined status or a newly scheduled connection.
test("synchronous stop during join and constructor failure stay isolated", async t => {
  const s = setup(t, { onGap: () => s.stream.stop() });
  FakeSocket.instances[0].join();
  assert.equal(await s.stream.ready, true);
  assert.deepEqual(s.statuses, [false]);
  t.mock.timers.tick(100_000);
  assert.equal(FakeSocket.instances.length, 1);
  FakeSocket.fail = true;
  const statuses: boolean[] = [];
  const failed = startOpenSeaStream({ key: "fixture-only", onChange() {}, onGap() {}, onStatus: v => { statuses.push(v); } });
  t.mock.timers.tick(10_000);
  assert.equal(await failed.ready, false);
  failed.stop();
  assert.equal(statuses.length > 0 && statuses.every(v => v === false), true);
});

// promise: a failed change callback requests reconciliation only while its originating connection is current.
test("change callback failure requests a gap and stale failure is fenced", async t => {
  let reject: (reason?: unknown) => void = () => {};
  let mode = "sync";
  const s = setup(t, { onChange: () => {
    if (mode === "sync") throw new Error("callback");
    if (mode === "async") return Promise.reject(new Error("callback"));
    return new Promise<void>((_, fail) => { reject = fail; });
  } });
  const ws = FakeSocket.instances[0]; ws.join();
  ws.frame(["1", null, "collection:credits", "item_listed", payload()]);
  assert.equal(s.gaps(), 2);
  mode = "async";
  ws.frame(["1", null, "collection:credits", "item_listed", payload()]);
  await Promise.resolve();
  assert.equal(s.gaps(), 3);
  mode = "pending";
  ws.frame(["1", null, "collection:credits", "item_listed", payload()]);
  ws.emit("close");
  t.mock.timers.tick(1_000);
  FakeSocket.instances[1].join();
  const before = s.gaps();
  reject(new Error("stale callback"));
  await Promise.resolve();
  assert.equal(s.gaps(), before);
});

// promise: stopping synchronously from a disconnected status prevents every subsequent callback and reconnect.
test("disconnect status callback stop fences the following gap", t => {
  const s = setup(t, { onStatus: (joined: boolean) => { if (!joined) s.stream.stop(); } });
  FakeSocket.instances[0].join();
  assert.equal(s.gaps(), 1);
  FakeSocket.instances[0].emit("error");
  assert.equal(s.gaps(), 1);
  t.mock.timers.tick(100_000);
  assert.equal(FakeSocket.instances.length, 1);
});

// promise: only a public, single-item native-ETH listing carries an advisory price; bad hints never lose the event.
test("native ETH listing price hints only prioritize canonical reads", t => {
  const s = setup(t), ws = FakeSocket.instances[0]; ws.join();
  const valid = { ...payload().payload, base_price: "1234", payment_token: {
    address: "0x0000000000000000000000000000000000000000", decimals: 18,
  }, quantity: 1, is_private: false };
  for (const quantity of [1, "1"]) {
    ws.frame(["1", null, "collection:credits", "item_listed", { event_type: "item_listed", payload: { ...valid, quantity } }]);
    assert.deepEqual(s.changes.at(-1), { event: "item_listed", hash, id: 42n, price: 1234n });
  }
  const invalid = [
    { base_price: "0" }, { base_price: "-1" }, { base_price: "1.5" }, { base_price: "bad" },
    { base_price: (1n << 256n).toString() }, { base_price: undefined }, { base_price: 1234 },
    { payment_token: { address: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", decimals: 18, symbol: "ETH" } },
    { payment_token: { symbol: "ETH", decimals: 18 } }, { payment_token: null },
    { payment_token: { ...valid.payment_token, decimals: "18" } },
    { payment_token: { ...valid.payment_token, decimals: 6 } },
    { quantity: 2 }, { quantity: "01" }, { quantity: undefined }, { is_private: true }, { is_private: undefined },
  ];
  for (const patch of invalid) {
    const before = s.changes.length;
    ws.frame(["1", null, "collection:credits", "item_listed", { event_type: "item_listed", payload: { ...valid, ...patch } }]);
    assert.equal(s.changes.length, before + 1);
    assert.equal(Object.hasOwn(s.changes.at(-1), "price"), false);
  }
  ws.frame(["1", null, "collection:credits", "order_revalidate", { event_type: "order_revalidate", payload: valid }]);
  assert.equal(Object.hasOwn(s.changes.at(-1), "price"), false);
  const before = s.changes.length;
  ws.frame(["1", null, "collection:credits", "item_listed", { event_type: "item_listed", payload: { ...valid, collection: { slug: "foreign" } } }]);
  assert.equal(s.changes.length, before);
  assert.equal(s.gaps(), 1);
});
