// promise: hashless and zero-price Seaport orders cannot block the keeper from ranking a valid order
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Sources } from "../src/listings.ts";
import { PendingStore } from "../src/ledger.ts";
import { listingCooldown } from "../src/main.ts";
import { setSink } from "../src/log.ts";
import { CREDIT_STRATEGY } from "@cc/engine/addresses";

const offerer = "0x00000000000000000000000000000000000000f1";
const params = {
  considerationToken: "0x0000000000000000000000000000000000000000",
  considerationIdentifier: "0",
  considerationAmount: "900",
  offerer,
  zone: "0x0000000000000000000000000000000000000000",
  offerToken: "0x97630aA70AB14ed9883B41dAfccBc11349723043",
  offerIdentifier: "42",
  offerAmount: "1",
  basicOrderType: "0",
  startTime: "1",
  endTime: "2",
  zoneHash: "0x" + "00".repeat(32),
  salt: "5",
  offererConduitKey: "0x" + "00".repeat(32),
  fulfillerConduitKey: "0x" + "00".repeat(32),
  totalOriginalAdditionalRecipients: "0",
  additionalRecipients: [],
  signature: "0xabcd",
};

test("seaport: hashless and zero-price orders are skipped while a valid order is evaluated", async () => {
  const file = join(mkdtempSync(join(tmpdir(), "keeper-orders-")), "orders.json");
  const hash = "0x" + "11".repeat(32);
  writeFileSync(
    file,
    JSON.stringify({
      orders: [
        { id: "41", price: "1000", params },
        { id: "42", price: "1000", params, hash },
        { id: "43", price: "0", params, hash: "0x" + "22".repeat(32) },
      ],
    }),
  );
  const cfg: any = {
    record: { core: "0x00000000000000000000000000000000000000c0", seaportAdapter: "0x00000000000000000000000000000000000000a1" },
    strategy: { mode: "off" },
    opensea: { file, refreshSec: 60, pages: 1, sign: 0 },
  };
  const read: string[] = [];
  const client: any = {
    multicall: async ({ contracts }: { contracts: { functionName: string }[] }) =>
      contracts.map((c) => {
        read.push(c.functionName);
        const result =
          c.functionName === "bidOf" ? 0n : c.functionName === "price" ? ["0x0", 1000n, "0x"] : c.functionName === "ownerOf" ? offerer : [true, false, 0n, 0n];
        return { status: "success", result };
      }),
  };
  const lines: any[] = [];
  setSink((l) => lines.push(JSON.parse(l)));
  try {
    const s = new Sources(client, cfg, () => 1_000_000_000);
    (s as any).scores = new Map([[41n, 2000n], [42n, 2000n], [43n, 2000n]]);
    const out = await s.candidates({ ethRate: 1_000_000n } as any, 1n);
    assert.deepEqual(out.map((l) => [l.id, l.valid]), [[42n, true]]);
    assert.deepEqual(read, ["bidOf", "price", "ownerOf", "getOrderStatus"]);
    const warns = lines.filter((l) => l.level === "warn");
    assert.equal(warns.length, 2);
    assert.match(warns[0].msg, /no hash/);
    assert.equal(warns[0].id, "41");
    assert.match(warns[1].msg, /no positive price/);
    assert.equal(warns[1].id, "43");
  } finally {
    setSink((l) => process.stdout.write(l + "\n"));
  }
});

// promise: one malformed signed order cannot discard a valid cached order or stop the keeper's listing tick
test("seaport: malformed signed order is isolated from a valid order", async () => {
  const file = join(mkdtempSync(join(tmpdir(), "keeper-orders-")), "orders.json");
  const hash = "0x" + "11".repeat(32);
  writeFileSync(file, JSON.stringify({ orders: [
    { id: "bad", price: "wat", params: null, hash },
    { id: "44", price: "1000", params, hash: "0xbad" },
    { id: "42", price: "1000", params, hash },
  ] }));
  const cfg: any = {
    record: { core: "0x00000000000000000000000000000000000000c0", seaportAdapter: "0x00000000000000000000000000000000000000a1" },
    strategy: { mode: "off" }, opensea: { file, refreshSec: 60, pages: 1, sign: 0 },
  };
  const client: any = { multicall: async ({ contracts }: any) => contracts.map((c: any) => ({ status: "success", result:
    c.functionName === "bidOf" ? 2000n : c.functionName === "price" ? ["0x0", 1000n, "0x"] : c.functionName === "ownerOf" ? offerer : [true, false, 0n, 0n] })) };
  const lines: any[] = [];
  setSink((l) => lines.push(JSON.parse(l)));
  try {
    const source = new Sources(client, cfg, () => 1_000_000_000);
    (source as any).scores = new Map([[42n, 2000n]]);
    const out = await source.candidates({ ethRate: 1_000_000n } as any, 1n);
    assert.deepEqual(out.map((l) => l.id), [42n]);
    assert.deepEqual(lines.filter((l) => l.msg === "malformed seaport order skipped").map((l) => l.id), ["bad", "44"]);
  } finally {
    setSink((l) => process.stdout.write(l + "\n"));
  }
});

// promise: after a keeper restart, a reverted listing waits one hour while another listing remains eligible
test("seaport: a durable reverted listing wait survives restart and yields the next candidate", async () => {
  let now = 1_000_000_000;
  const dir = mkdtempSync(join(tmpdir(), "keeper-listing-wait-"));
  const cfg: any = {
    record: { core: "0x00000000000000000000000000000000000000c0", seaportAdapter: "0x00000000000000000000000000000000000000a1" },
    strategy: { mode: "off" }, opensea: { refreshSec: 60 },
  };
  const client: any = { multicall: async ({ contracts }: any) => contracts.map((c: any) => ({ status: "success", result:
    c.functionName === "bidOf" ? 2000n : c.functionName === "price" ? ["0x0", 1000n, "0x"] : c.functionName === "ownerOf" ? offerer : [true, false, 0n, 0n] })) };
  const outcome = { kind: "sent", hash: ("0x" + "11".repeat(32)) as `0x${string}`, status: "reverted", spent: 1n, received: 0n, listingKey: "seaport:42" } as const;
  const cooldown = listingCooldown(outcome);
  assert.ok(cooldown);
  new PendingStore(dir, () => now).recordListingRevert(cooldown.key, outcome.hash);
  const source = new Sources(client, cfg, () => now, new PendingStore(dir));
  (source as any).scores = new Map([[42n, 2000n], [43n, 2000n]]);
  (source as any).seaport = [42n, 43n].map((id) => ({
    venue: "seaport", adapter: cfg.record.seaportAdapter, id, price: 1000n,
    params: "0x", hash: "0x" + "11".repeat(32), offerer,
  }));
  assert.equal(cooldown.seconds, 3_600);
  assert.deepEqual((await source.candidates({ ethRate: 1_000_000n } as any, 1n)).map((l) => l.id), [43n]);
  now += 3_599_999;
  assert.deepEqual((await source.candidates({ ethRate: 1_000_000n } as any, 2n)).map((l) => l.id), [43n]);
  now += 1;
  assert.deepEqual((await source.candidates({ ethRate: 1_000_000n } as any, 2n)).map((l) => l.id), [42n, 43n]);
});

// promise: stale top-ranked listings cannot hide a valid 41st listing from the keeper indefinitely.
test("a valid 41st listing is checked on the next block after 40 stale listings", async () => {
  const cfg: any = {
    record: { core: "0x00000000000000000000000000000000000000c0", strategyAdapter: "0x00000000000000000000000000000000000000a1" },
    strategy: { mode: "off" },
    opensea: { refreshSec: 60 },
  };
  const checked: bigint[] = [];
  const client: any = {
    multicall: async ({ contracts }: { contracts: { functionName: string; args: bigint[] }[] }) =>
      contracts.map((c) => {
        if (c.functionName === "bidOf") checked.push(c.args[0]);
        if (c.functionName === "price" && c.args[0] < 41n) return { status: "failure" };
        const result = c.functionName === "bidOf" ? 2_000n : c.functionName === "price" ? ["0x0", 1_000n, "0x"] : CREDIT_STRATEGY;
        return { status: "success", result };
      }),
  };
  const s = new Sources(client, cfg, () => 1_000_000_000);
  const watched = Array.from({ length: 41 }, (_, i) => ({
    venue: "strategy", adapter: cfg.record.strategyAdapter, id: BigInt(i + 1), price: 1_000n, params: "0x",
  }));
  (s as any).strategy = watched;
  (s as any).scores = new Map(watched.map((w) => [w.id, 2_000n]));
  const first = await s.candidates({ ethRate: 1_000_000n } as any, 1n);
  assert.equal(first.length, 40);
  assert.ok(first.every((l) => !l.valid));
  assert.ok(!checked.includes(41n));
  (s as any).strategy = [...watched]; // refresh does not reset the scan window
  const second = await s.candidates({ ethRate: 1_000_000n } as any, 2n);
  assert.ok(second.some((l) => l.id === 41n && l.valid));
  assert.equal(checked.length, 80, "at most 40 full reads per block");
});


// promise: immutable scores are shared across venues and survive a restart under the same chain/contract identity.
test("Credit score cache survives restart and rejects another chain", async () => {
  const dir = mkdtempSync(join(tmpdir(), "keeper-score-cache-"));
  const cfg: any = { stateDir: dir, record: { chainId: 1 } };
  let reads = 0;
  const client: any = { multicall: async ({ contracts }: any) => {
    reads++;
    return contracts.map((c: any) => c.functionName === "seedOf" ? "0x" + "11".repeat(21) : c.functionName === "timestampOf" ? 1n : 2000n);
  } };
  const source = new Sources(client, cfg);
  await (source as any).scoresOf([42n, 42n]);
  assert.equal(reads, 2);
  const path = join(dir, "credit-scores.json");
  assert.equal(statSync(path).mode & 0o777, 0o600);
  assert.deepEqual(JSON.parse(readFileSync(path, "utf8")).scores, [["42", "2000"]]);
  const restarted = new Sources(client, cfg);
  await (restarted as any).scoresOf([42n]);
  assert.equal(reads, 2);
  const other = new Sources(client, { ...cfg, record: { chainId: 2 } });
  await (other as any).scoresOf([42n]);
  assert.equal(reads, 4);
});

// promise: a failed immutable read is never cached as zero or allowed to replace an existing score.
test("Credit score cache preserves good values on RPC failure", async () => {
  const dir = mkdtempSync(join(tmpdir(), "keeper-score-failure-"));
  const cfg: any = { stateDir: dir, record: { chainId: 1 } };
  let fail = false;
  const client: any = { multicall: async ({ contracts }: any) => {
    if (fail) throw new Error("fixture RPC unavailable");
    return contracts.map((c: any) => c.functionName === "seedOf" ? "0x" + "11".repeat(21) : c.functionName === "timestampOf" ? 1n : 2000n);
  } };
  const source = new Sources(client, cfg);
  await (source as any).scoresOf([42n]);
  fail = true;
  await assert.rejects((source as any).scoresOf([43n]), /RPC unavailable/);
  assert.equal((source as any).scores.get(42n), 2000n);
  assert.equal((source as any).scores.has(43n), false);
  assert.deepEqual(JSON.parse(readFileSync(join(dir, "credit-scores.json"), "utf8")).scores, [["42", "2000"]]);
});

// promise: one slow full-market refresh does not block ticks, duplicate discovery, or discard the last completed candidate set.
test("OpenSea full scan runs once in the background and retains cached candidates on failure", { timeout: 2000 }, async () => {
  const original = globalThis.fetch;
  let calls = 0;
  let rejectFetch: ((e: Error) => void) | undefined;
  globalThis.fetch = (() => {
    calls++;
    return new Promise((_resolve, reject) => { rejectFetch = reject; });
  }) as typeof fetch;
  const cfg: any = {
    record: { chainId: 1, core: "0x00000000000000000000000000000000000000c0", seaportAdapter: "0x00000000000000000000000000000000000000a1" },
    strategy: { mode: "off" }, rpcUrls: ["https://rpc.invalid"],
    opensea: { key: "fixture", refreshSec: 300, sign: 1 },
  };
  const client: any = { multicall: async ({ contracts }: any) => contracts.map((c: any) => ({ status: "success", result:
    c.functionName === "bidOf" ? 2000n : c.functionName === "price" ? ["0x0", 1000n, "0x"] : c.functionName === "ownerOf" ? offerer : [true, false, 0n, 0n] })) };
  let now = 1_000_000_000;
  const source = new Sources(client, cfg, () => now);
  (source as any).scores.set(42n, 2000n);
  (source as any).seaport = [{ venue: "seaport", adapter: cfg.record.seaportAdapter, id: 42n, price: 1000n, params: "0x", offerer, hash: "0x" + "11".repeat(32) }];
  try {
    assert.deepEqual((await source.candidates({ ethRate: 1_000_000n } as any, 1n)).map(l => l.id), [42n]);
    await new Promise(resolve => setImmediate(resolve));
    assert.ok((source as any).seaportRefresh);
    assert.equal(calls, 1);
    assert.deepEqual((await source.candidates({ ethRate: 1_000_000n } as any, 2n)).map(l => l.id), [42n]);
    assert.equal(calls, 1);
    rejectFetch!(Object.assign(new Error("fixture API rate limit"), { retryAt: now + 600_000 }));
    await (source as any).seaportRefresh;
    assert.equal((source as any).seaport.length, 1);
    assert.equal((source as any).seaportRefresh, undefined);
    now += 301_000;
    await source.candidates({ ethRate: 1_000_000n } as any, 3n);
    assert.equal(calls, 1);
  } finally {
    rejectFetch?.(new Error("fixture cleanup"));
    await (source as any).seaportRefresh;
    globalThis.fetch = original;
  }
});
