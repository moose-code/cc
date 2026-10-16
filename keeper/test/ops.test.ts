// promise: the keeper stops at its daily budget, pauses a door that keeps failing, decrypts its keystore in memory,
// refuses the owner key and a live chain without a private relay, and encodes Seaport orders the adapter decodes
import { test } from "node:test";
import assert from "node:assert/strict";
import { createCipheriv, randomBytes, scryptSync } from "node:crypto";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { concat, decodeAbiParameters, keccak256, parseEther, type Address } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { Breaker, Ledger } from "../src/ledger.ts";
import { decryptKeystore } from "../src/keystore.ts";
import { loadConfig, OWNER, type Deployment } from "../src/config.ts";
import { encodeBasicOrder } from "../src/listings.ts";
import { startChecks } from "../src/main.ts";
import { setSink } from "../src/log.ts";

const rec = (chainId: number): Deployment => ({
  chainId,
  core: "0x00000000000000000000000000000000000000c0",
  controller: "0x00000000000000000000000000000000000000c1",
  seaportAdapter: "0x00000000000000000000000000000000000000a1",
  strategyAdapter: "0x00000000000000000000000000000000000000a2",
});

test("budget: a send fits while its cost is at most the net loss left today; payments refill it; a new day resets", () => {
  let now = Date.parse("2026-10-16T10:00:00Z");
  const dir = mkdtempSync(join(tmpdir(), "keeper-ledger-"));
  const l = new Ledger(dir, parseEther("0.01"), () => now);
  assert.equal(l.allows(parseEther("0.01")), true);
  l.record(parseEther("0.006"), 0n, "0x01");
  assert.equal(l.allows(parseEther("0.004")), true);
  assert.equal(l.allows(parseEther("0.004") + 1n), false);
  l.record(parseEther("0.004"), 0n, "0x02");
  assert.equal(l.remaining(), 0n);
  assert.equal(l.allows(1n), false, "exhausted");
  l.record(parseEther("0.001"), parseEther("0.003"), "0x03");
  assert.equal(l.remaining(), parseEther("0.002"), "a paid call refills the budget by its net gain");
  // the ledger is read back from its file after a restart
  const again = new Ledger(dir, parseEther("0.01"), () => now);
  assert.equal(again.remaining(), parseEther("0.002"));
  assert.match(readFileSync(join(dir, "ledger-2026-10-16.json"), "utf8"), /"txs":3/);
  now = Date.parse("2026-10-17T00:00:01Z");
  assert.equal(l.remaining(), parseEther("0.01"));
});

test("breaker: the threshold-th consecutive failure pauses the door; a success resets the count", () => {
  let now = 0;
  const b = new Breaker(3, 60, () => now);
  assert.equal(b.fail("buyback"), false);
  b.ok("buyback");
  assert.equal(b.fail("buyback"), false);
  assert.equal(b.fail("buyback"), false);
  assert.equal(b.fail("buyback"), true);
  assert.equal(b.paused("buyback"), true);
  assert.equal(b.paused("compose"), false);
  now = 60_001;
  assert.equal(b.paused("buyback"), false);
});

// a v3 keystore written the way cast writes it, from a key generated in memory for this test only
function keystore(key: `0x${string}`, password: string) {
  const salt = randomBytes(32);
  const iv = randomBytes(16);
  const dk = scryptSync(password, salt, 32, { N: 8192, r: 8, p: 1 });
  const c = createCipheriv("aes-128-ctr", dk.subarray(0, 16), iv);
  const ct = Buffer.concat([c.update(Buffer.from(key.slice(2), "hex")), c.final()]);
  const mac = keccak256(concat([new Uint8Array(dk.subarray(16, 32)), new Uint8Array(ct)])).slice(2);
  return JSON.stringify({
    version: 3,
    crypto: { cipher: "aes-128-ctr", cipherparams: { iv: iv.toString("hex") }, ciphertext: ct.toString("hex"), kdf: "scrypt", kdfparams: { dklen: 32, n: 8192, p: 1, r: 8, salt: salt.toString("hex") }, mac },
  });
}

test("keystore: decrypts a v3 scrypt keystore; a wrong password is refused", () => {
  const key = generatePrivateKey();
  const json = keystore(key, "pw");
  assert.equal(decryptKeystore(json, "pw"), key);
  assert.throws(() => decryptKeystore(json, "nope"), /wrong password/);
});

test("config: a live chain needs a private relay and two public fallbacks; impersonation is local only", () => {
  const live = { RECORD: "x", KEEPER_ADDRESS: "0x0000000000000000000000000000000000000001", DRY_RUN: "1" };
  const c = loadConfig({ ...live, RPC_URLS: "https://example.org/rpc" }, () => rec(1));
  assert.ok(c.rpcUrls.length >= 3, "the listed rpc plus the public fallbacks");
  assert.deepEqual(c.relayUrls, ["https://rpc.mevblocker.io", "https://rpc.flashbots.net/fast"]);
  assert.throws(() => loadConfig({ ...live, RPC_URLS: "https://example.org/rpc", RELAY_URLS: "" }, () => rec(1)), /private relay/);
  assert.throws(() => loadConfig({ RECORD: "x", RPC_URLS: "https://example.org/rpc", IMPERSONATE: "0x0000000000000000000000000000000000000001" }, () => rec(1)), /local anvil node only/);
  const local = loadConfig({ RECORD: "x", RPC_URLS: "http://127.0.0.1:8545", IMPERSONATE: "0x0000000000000000000000000000000000000001" }, () => rec(31337));
  assert.equal(local.signer.kind, "impersonate");
  assert.deepEqual(local.relayUrls, []);
  assert.equal(local.listingDelaySec, 120, "decision 133");
  assert.equal(local.doors.compose.maxBaseFee, 3_000_000_000n, "decision 134");
  assert.equal(local.doors.buyListing.maxBaseFee, 5_000_000_000n, "keeperMaxBaseFee");
  assert.throws(() => loadConfig({ RECORD: "x", RPC_URLS: "http://127.0.0.1:8545" }, () => rec(31337)), /KEYSTORE/);
});

function fakeClient(code: `0x${string}` | undefined, chainId = 31337) {
  return {
    getChainId: async () => chainId,
    getCode: async () => code,
    readContract: async () => true,
    getBalance: async () => parseEther("1"),
  } as any;
}

test("start: refuses the owner address and the Core owner; warns on an EIP-7702 delegated signer", async () => {
  const lines: string[] = [];
  setSink((l) => lines.push(l));
  const cfg = loadConfig({ RECORD: "x", RPC_URLS: "http://127.0.0.1:8545", IMPERSONATE: OWNER }, () => rec(31337));
  const fixed = { sniperSeconds: 1800n, factory: OWNER, escrow: OWNER, owner: "0x00000000000000000000000000000000000000ee" as Address };
  await assert.rejects(startChecks(fakeClient(undefined), cfg, fixed, { address: OWNER }), /refusing to run as the owner/);
  await assert.rejects(startChecks(fakeClient(undefined), cfg, fixed, { address: fixed.owner }), /refusing to run as the owner/);
  const me = privateKeyToAccount(generatePrivateKey()).address;
  await startChecks(fakeClient(("0xef0100" + "11".repeat(20)) as `0x${string}`), cfg, fixed, { address: me });
  assert.ok(lines.some((l) => l.includes("EIP-7702 delegated")));
  await assert.rejects(startChecks(fakeClient(undefined, 1), cfg, fixed, { address: me }), /the rpc is chain 1, the record is chain 31337/);
  setSink((l) => process.stdout.write(l + "\n"));
});

test("seaport: encodeBasicOrder is abi.encode(BasicOrderParameters)", () => {
  const p = {
    considerationToken: "0x0000000000000000000000000000000000000000",
    considerationIdentifier: "0",
    considerationAmount: "900",
    offerer: "0x00000000000000000000000000000000000000f1",
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
    totalOriginalAdditionalRecipients: "1",
    additionalRecipients: [{ amount: "100", recipient: "0x0000a26b00c1F0DF003000390027140000fAa719" }],
    signature: "0xabcd",
  };
  const enc = encodeBasicOrder(p);
  const [d] = decodeAbiParameters(
    [{ type: "tuple", components: [{ type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "address" }, { type: "address" }, { type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "uint8" }, { type: "uint256" }, { type: "uint256" }, { type: "bytes32" }, { type: "uint256" }, { type: "bytes32" }, { type: "bytes32" }, { type: "uint256" }, { type: "tuple[]", components: [{ type: "uint256" }, { type: "address" }] }, { type: "bytes" }] }],
    enc,
  ) as any;
  assert.equal(d[2], 900n);
  assert.equal(d[6], 42n);
  assert.equal(d[16][0][0], 100n);
  assert.equal(d[17], "0xabcd");
});
