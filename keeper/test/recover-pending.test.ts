// promise: a pending keeper transaction is cleared only after a finalized canonical same-nonce self-cancel accounts its gas
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Ledger, PendingStore, utcDay } from "../src/ledger.ts";
import { checkRecoveryRpcUrls, recoverPending } from "../src/recover-pending.ts";

const signer = "0x00000000000000000000000000000000000000f1";
const other = "0x00000000000000000000000000000000000000f2";
const originalHash = `0x${"11".repeat(32)}` as const;
const cancelHash = `0x${"22".repeat(32)}` as const;
const blockHash = `0x${"33".repeat(32)}` as const;
const oldBlockHash = `0x${"44".repeat(32)}` as const;
const spent = 21_000n * 2_000_000_000n;

function setup() {
  const dir = mkdtempSync(join(tmpdir(), "keeper-recover-"));
  const pending = new PendingStore(dir);
  pending.save({ hash: originalHash, nonce: 7, chainId: 31337, address: signer, door: "buyListing", before: 1_000_000n });
  const ledger = new Ledger(dir, 1_000_000_000_000_000n);
  const tx = { hash: cancelHash, nonce: 7, from: signer, to: signer, value: 0n, input: "0x", type: "eip1559", chainId: 31337, blockHash, blockNumber: 10n };
  const receipt = { transactionHash: cancelHash, status: "success", from: signer, to: signer, blockNumber: 10n, blockHash, gasUsed: 21_000n, effectiveGasPrice: 2_000_000_000n };
  let originalReceipt: unknown = null;
  let originalReadError = false;
  let finalizedNumber = 20n;
  let canonicalHash: string = blockHash;
  let nonce = 8;
  let chainId = 31337;
  let code: `0x${string}` | undefined = undefined;
  const requests: string[] = [];
  const client: any = {
    getChainId: async () => chainId,
    getTransaction: async () => tx,
    getTransactionReceipt: async () => receipt,
    getBlock: async ({ blockTag, blockNumber }: { blockTag?: string; blockNumber?: bigint }) =>
      blockTag === "finalized" ? { number: finalizedNumber } : { hash: blockNumber === 10n ? canonicalHash : oldBlockHash },
    getTransactionCount: async () => nonce,
    getCode: async () => code,
    request: async ({ method }: { method: string }) => {
      requests.push(method);
      if (originalReadError) throw new Error("RPC unavailable");
      return originalReceipt;
    },
  };
  return {
    dir, pending, ledger, tx, receipt, client, requests,
    setOriginalReceipt: (x: unknown) => { originalReceipt = x; },
    failOriginalRead: () => { originalReadError = true; },
    setFinalizedNumber: (x: bigint) => { finalizedNumber = x; },
    setCanonicalHash: (x: string) => { canonicalHash = x; },
    setNonce: (x: number) => { nonce = x; },
    setChainId: (x: number) => { chainId = x; },
    setCode: (x: `0x${string}`) => { code = x; },
  };
}

test("recovery: finalized same-nonce self-cancel records gas then clears pending", async () => {
  const s = setup();
  const out = await recoverPending(s.client, s.pending, s.ledger, { chainId: 31337, address: signer }, cancelHash);
  assert.deepEqual(out, { hash: cancelHash, status: "success", spent });
  assert.equal(s.ledger.snapshot().spent, spent);
  assert.equal(s.ledger.snapshot().received, 0n);
  assert.equal(s.ledger.snapshot().txs, 1);
  assert.equal(new PendingStore(s.dir).current, undefined);
  assert.deepEqual(s.requests, ["eth_getTransactionReceipt"], "recovery made only the original receipt raw RPC call");
});

// promise: a conflicting, noncanonical, unfinalized, or unreadable replacement leaves the pending marker and budget intact
test("recovery: hostile replacement and RPC cases fail closed", async (t) => {
  const cases: [string, (s: ReturnType<typeof setup>) => void][] = [
    ["wrong RPC chain", (s) => s.setChainId(1)],
    ["wrong nonce", (s) => { s.tx.nonce = 8; }],
    ["wrong sender", (s) => { s.tx.from = other; }],
    ["wrong recipient", (s) => { s.tx.to = other; }],
    ["nonzero value", (s) => { s.tx.value = 1n; }],
    ["nonempty input", (s) => { s.tx.input = "0x1234"; }],
    ["transaction and receipt block mismatch", (s) => { s.tx.blockHash = oldBlockHash; }],
    ["authorization-list replacement", (s) => { (s.tx as any).type = "eip7702"; (s.tx as any).authorizationList = []; }],
    ["blob-fee replacement", (s) => { s.tx.type = "eip4844"; }],
    ["successful delegated signer", (s) => s.setCode(`0xef0100${"aa".repeat(20)}`)],
    ["not finalized", (s) => s.setFinalizedNumber(9n)],
    ["not canonical", (s) => s.setCanonicalHash(oldBlockHash)],
    ["finalized nonce unchanged", (s) => s.setNonce(7)],
    ["original canonical receipt", (s) => s.setOriginalReceipt({ blockNumber: "0x9", blockHash: oldBlockHash })],
    ["original RPC failure", (s) => s.failOriginalRead()],
  ];
  for (const [name, mutate] of cases) await t.test(name, async () => {
    const s = setup();
    mutate(s);
    await assert.rejects(recoverPending(s.client, s.pending, s.ledger, { chainId: 31337, address: signer }, cancelHash));
    assert.equal(new PendingStore(s.dir).current?.hash, originalHash);
    assert.equal(s.ledger.snapshot().txs, 0);
  });
});

test("recovery: a reverted finalized self-cancel still consumes the nonce and records gas", async () => {
  const s = setup();
  s.receipt.status = "reverted";
  s.setCode(`0xef0100${"aa".repeat(20)}`);
  const out = await recoverPending(s.client, s.pending, s.ledger, { chainId: 31337, address: signer }, cancelHash);
  assert.equal(out.status, "reverted");
  assert.equal(out.spent, spent);
  assert.equal(s.ledger.snapshot().spent, spent);
  assert.equal(new PendingStore(s.dir).current, undefined);
});

test("recovery: a failed marker clear retries without double-counting cancel gas", async () => {
  const s = setup();
  const clear = s.pending.clear.bind(s.pending);
  s.pending.clear = () => { throw new Error("disk I/O failed"); };
  await assert.rejects(recoverPending(s.client, s.pending, s.ledger, { chainId: 31337, address: signer }, cancelHash));
  assert.equal(s.ledger.snapshot().txs, 1);
  assert.equal(new PendingStore(s.dir).current?.ledgerDay, utcDay(Date.now()));
  s.pending.clear = clear;
  await recoverPending(s.client, s.pending, s.ledger, { chainId: 31337, address: signer }, cancelHash);
  assert.equal(s.ledger.snapshot().txs, 1);
  assert.equal(new PendingStore(s.dir).current, undefined);
});

test("recovery: a damaged ledger leaves the pending marker untouched", async () => {
  const s = setup();
  writeFileSync(join(s.dir, `ledger-${utcDay(Date.now())}.json`), "broken");
  await assert.rejects(recoverPending(s.client, s.pending, s.ledger, { chainId: 31337, address: signer }, cancelHash));
  assert.equal(new PendingStore(s.dir).current?.hash, originalHash);
});

test("recovery: mainnet administrative RPC rejects a local chain-id-1 fork", () => {
  assert.throws(() => checkRecoveryRpcUrls(1, ["http://127.0.0.1:8545"]), /outside loopback/);
  assert.throws(() => checkRecoveryRpcUrls(1, ["https://mainnet.example", "http://localhost:8545"]), /outside loopback/);
  assert.throws(() => checkRecoveryRpcUrls(1, ["https://127.0.0.2/rpc"]), /outside loopback/);
  assert.doesNotThrow(() => checkRecoveryRpcUrls(1, ["https://mainnet.example"]));
  assert.doesNotThrow(() => checkRecoveryRpcUrls(31337, ["http://127.0.0.1:8545"]));
});
