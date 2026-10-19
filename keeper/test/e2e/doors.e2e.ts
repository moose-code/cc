// promise: on the local stack (script/dev/local.sh, STACK=master) one keeper tick makes exactly the decided call of each
// door, through the real Core, and the chain state after it is the door's effect
//
// needs the node of deployments/31337.json running. each test seeds its door's state through anvil, runs one tick of
// the in process keeper with only that door on, asserts the transaction it sent and the state after, and reverts the
// node to the snapshot it started from. the keeper sends as the record's keeper account, impersonated by anvil.
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createPublicClient,
  decodeEventLog,
  encodeFunctionData,
  http,
  keccak256,
  encodeAbiParameters,
  numberToHex,
  parseAbi,
  parseEther,
  parseGwei,
  zeroAddress,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { controllerAbi, coreAbi, creditStrategyAbi, creditsAbi, engineEventsAbi, escrowAbi } from "@cc/engine/abis";
import { CREDIT_STRATEGY, CREDITS } from "@cc/engine/addresses";
import { creditScores } from "@cc/engine/snapshot";
import { build, type TickResult } from "../../src/main.ts";
import { setSink } from "../../src/log.ts";

const ROOT = new URL("../../../", import.meta.url).pathname;
const REC_PATH = process.env.RECORD ?? join(ROOT, "deployments/31337.json");
const rec = JSON.parse(readFileSync(REC_PATH, "utf8"));
const RPC: string = process.env.E2E_RPC_URL ?? rec.rpcUrl;
const CORE = rec.core as Address;
const KEEPER = rec.accounts.keeper as Address;
const OWNER = rec.owner as Address;
const A1 = rec.accounts.a1 as Address;
const client = createPublicClient({ transport: http(RPC, { timeout: 120_000 }) }) as PublicClient;

const ownerAbi = parseAbi([
  "function setRate(uint256 rate)",
  "function fund() payable",
  "function sellForEth(uint256[] ids, uint256 minOut)",
  "function setApprovalForAll(address operator, bool approved)",
  "function transferFrom(address from, address to, uint256 id)",
  "function HOOK() view returns (address)",
  "function totalOwed(address token) view returns (uint256)",
]);
const settingsAbi = parseAbi([
  "function setSettings((uint16 dropPer100PointsBps, uint16 dropFloorBps, uint16 climbPerMinBps, uint16 ceilBps, uint16 idleLoosenBps, uint16 saleFloorBps, uint16 saleToBuybackBps, uint16 recoveryClimbPerMinBps, uint16 recoveryGapBps, uint32 peakHalfLife, uint16 buybackDelay, bool redeemOn, bool balanceBidOn, uint16 redeemSlippageBps, uint16 balanceBidMarginBps, uint16 redeemBurnBps, uint128 buybackSlice, uint64 keeperFee, uint48 keeperMaxBaseFee, uint64 rateCap, uint64 callerFee, uint48 callerMaxBaseFee, uint16 feeToRedeemBurnBps, uint24 payeePpm, uint32 pointsPerPage, uint96 swapFeeCc, uint16 saleToArtistBps, uint16 saleToOperatorBps, uint16 climbMultiplierCapBps, uint16 spendCapBps, uint32 bucketSeconds, uint32 balanceBidCapBps, uint32 idleStepSeconds, uint32 sniperSeconds, uint64 reserveWei, uint32 returnLockSeconds, bool valueModeOn, uint16 buyToArtistBps, uint16 balanceDiscountBps) s)",
]);

// ------------------------------------------------------------------ anvil helpers

const rpc = (method: string, params: unknown[] = []) => client.request({ method: method as any, params: params as any });
const hex = (v: bigint) => numberToHex(v);
async function send(from: Address, to: Address, data: Hex, value = 0n) {
  await rpc("anvil_impersonateAccount", [from]);
  const hash = (await rpc("eth_sendTransaction", [{ from, to, data, value: hex(value), gas: hex(15_000_000n) }])) as Hex;
  const r = await client.waitForTransactionReceipt({ hash });
  assert.equal(r.status, "success", `seed call from ${from} reverted`);
  return r;
}
const call = (from: Address, to: Address, abi: any, functionName: string, args: unknown[] = [], value = 0n) =>
  send(from, to, encodeFunctionData({ abi, functionName, args } as any), value);
const read = <T>(address: Address, abi: any, functionName: string, args: unknown[] = []) =>
  client.readContract({ address, abi, functionName, args } as any) as Promise<T>;
async function warp(sec: number) {
  await rpc("evm_increaseTime", [sec]);
  await rpc("evm_mine", []);
}
async function topUp(a: Address, eth: bigint) {
  await rpc("anvil_setBalance", [a, hex((await client.getBalance({ address: a })) + eth)]);
}
const word = (slot: bigint, address: Address) => client.getStorageAt({ address, slot: hex(slot) }).then((w) => BigInt(w ?? "0x0"));
const setWord = (address: Address, slot: bigint | Hex, v: bigint) =>
  rpc("anvil_setStorageAt", [address, typeof slot === "bigint" ? numberToHex(slot, { size: 32 }) : slot, numberToHex(v, { size: 32 })]);

// ------------------------------------------------------------------ the keeper

function env(over: Record<string, string>) {
  return {
    RECORD: REC_PATH,
    RPC_URLS: RPC,
    IMPERSONATE: KEEPER,
    STATE_DIR: mkdtempSync(join(tmpdir(), "keeper-e2e-")),
    STRATEGY_IDS: "off",
    ...over,
  };
}

// one keeper for a test; its staleness memory lives across its ticks
async function keeperFor(over: Record<string, string>) {
  await rpc("anvil_setNextBlockBaseFeePerGas", [hex(parseGwei("1"))]);
  await rpc("evm_mine", []);
  return (await build(env(over) as any)).keeper;
}

// the one transaction a tick sent, decoded against the expected call
async function assertSent(t: TickResult, functionName: string, args: unknown[]) {
  const sent = t.outcomes.filter((o) => o.outcome.kind === "sent");
  assert.equal(sent.length, 1, `one transaction sent, outcomes: ${JSON.stringify(t.outcomes, (_, v) => (typeof v === "bigint" ? v.toString() : v))}`);
  const o = sent[0].outcome as Extract<TickResult["outcomes"][number]["outcome"], { kind: "sent" }>;
  assert.equal(o.status, "success");
  const tx = await client.getTransaction({ hash: o.hash });
  assert.equal(tx.from.toLowerCase(), KEEPER.toLowerCase(), "sent by the keeper");
  assert.equal(tx.to?.toLowerCase(), CORE.toLowerCase(), "to the Core");
  assert.equal(tx.input, encodeFunctionData({ abi: coreAbi, functionName, args } as any), `the call is ${functionName}`);
  const receipt = await client.getTransactionReceipt({ hash: o.hash });
  const events = receipt.logs.flatMap((l) => {
    try {
      return [decodeEventLog({ abi: engineEventsAbi, data: l.data, topics: l.topics }) as { eventName: string; args: any }];
    } catch {
      return [];
    }
  });
  return { o, receipt, events };
}

let snap: Hex;
const lines: string[] = [];
before(async () => {
  assert.equal(await client.getChainId(), rec.chainId, "the record's node is up");
  setSink((l) => lines.push(l));
});
after(() => setSink((l) => process.stdout.write(l + "\n")));

async function isolated(fn: () => Promise<void>) {
  snap = (await rpc("evm_snapshot")) as Hex;
  lines.length = 0;
  try {
    await fn();
  } catch (e) {
    // the keeper's log of the failed test
    process.stderr.write(lines.filter((l) => !l.includes('"msg":"keeper start"')).slice(-25).join("\n") + "\n");
    throw e;
  } finally {
    await rpc("evm_revert", [snap]);
  }
}

// ------------------------------------------------------------------ book

test("book: after the window, with income pending and the payee share not latched, the tick sends book() and latches it", () =>
  isolated(async () => {
    // payeeOn is byte 20 of slot 22 (test/CoreLayout.t.sol); the scenario latched it, the seed clears it
    const w = await word(22n, CORE);
    await setWord(CORE, 22n, w & ~(0xffn << 160n));
    assert.equal(await read(CORE, coreAbi, "payeeOn"), false);
    // fee income arrives from the hook, the only sender besides the escrow the Core accepts
    const hook = await read<Address>(CORE, ownerAbi, "HOOK");
    await topUp(hook, parseEther("1"));
    await send(hook, CORE, "0x", parseEther("0.2"));
    const k = await keeperFor({ DOORS: "book" });
    const t = await k.tick();
    const { events } = await assertSent(t, "book", []);
    assert.equal(await read(CORE, coreAbi, "payeeOn"), true, "the book latched the payee share");
    assert.ok(events.some((e) => e.eventName === "FeesAdded"), "FeesAdded");
    const second = await k.tick();
    assert.equal(second.outcomes.length, 0, "a latched payee share is never booked again by the keeper");
    console.log(`  book: ${JSON.stringify(t.calls.map((c) => c.key))}`);
  }));

// ------------------------------------------------------------------ buyback

test("buyback: once the delay has passed with a slice above 2 * maxPay, the tick sends buyback() and is paid", () =>
  isolated(async () => {
    // ethToBuyback is slot 7; the seed raises it to 0.5 eth with the eth behind it
    const pot = await read<bigint>(CORE, coreAbi, "ethToBuyback");
    if (pot < parseEther("0.5")) {
      await setWord(CORE, 7n, parseEther("0.5"));
      await topUp(CORE, parseEther("0.5") - pot);
    }
    await rpc("anvil_mine", [hex(30n)]);
    const before = await read<bigint>(CORE, coreAbi, "ethToBuyback");
    const k = await keeperFor({ DOORS: "buyback" });
    const t = await k.tick();
    const { o, receipt, events } = await assertSent(t, "buyback", []);
    assert.equal(await read<bigint>(CORE, coreAbi, "lastBuybackBlock"), receipt.blockNumber, "lastBuybackBlock is the tick's block");
    const ev = events.find((e) => e.eventName === "Buyback")!;
    assert.equal(ev.args.caller.toLowerCase(), KEEPER.toLowerCase());
    assert.ok(ev.args.paid > 0n && o.received === ev.args.paid, "the keeper received the Buyback payment");
    assert.ok(o.received > o.spent, "paid more than its gas");
    assert.ok((await read<bigint>(CORE, coreAbi, "ethToBuyback")) < before, "the slice left the buyback pot");
    const again = await k.tick();
    assert.match(JSON.stringify(again.skips), /TooSoon/, "the next block is inside the delay");
  }));

// ------------------------------------------------------------------ compose

// the first `n` credits the CreditStrategy holds among the ids of test/utils/CreditIds.sol
async function strategyIds(n: number): Promise<bigint[]> {
  const src = readFileSync(join(ROOT, "test/utils/CreditIds.sol"), "utf8");
  const data = src.match(/hex"([0-9a-f]+)"/)![1];
  const ids: bigint[] = [];
  for (let i = 0; i + 8 <= data.length && ids.length < n; i += 8) {
    const id = BigInt("0x" + data.slice(i, i + 8));
    const owner = await read<Address>(CREDITS, creditsAbi, "ownerOf", [id]).catch(() => zeroAddress);
    if (owner.toLowerCase() === CREDIT_STRATEGY.toLowerCase()) ids.push(id);
  }
  return ids;
}

// fills the pile to 80 with strategy credits sold into the bid by a1, then passes the credit sale window
async function readyPage() {
  await call(A1, CORE, ownerAbi, "fund", [], parseEther("40"));
  const size = await read<bigint>(CORE, coreAbi, "pileSize");
  const need = size >= 80n ? 0 : 80 - Number(size);
  if (need > 0) {
    const ids = await strategyIds(need);
    assert.equal(ids.length, need, "enough strategy credits on the fork");
    await topUp(CREDIT_STRATEGY, parseEther("1"));
    for (const id of ids) await call(CREDIT_STRATEGY, CREDITS, ownerAbi, "transferFrom", [CREDIT_STRATEGY, A1, id]);
    await call(A1, CREDITS, ownerAbi, "setApprovalForAll", [CORE, true]);
    await call(A1, CORE, ownerAbi, "sellForEth", [ids, 0n]);
  }
  const controller = await read<Address>(CORE, coreAbi, "controller");
  const window = await read<number>(controller, controllerAbi, "creditWindow");
  await warp(Number(window) + 60);
  const [ready] = await read<readonly [boolean, readonly bigint[], number]>(controller, controllerAbi, "nextPage");
  assert.equal(ready, true, "nextPage is ready");
}

test("compose: with a ready page the tick sends compose() and is paid the caller payment (decision 138)", () =>
  isolated(async () => {
    await readyPage();
    const held = (await read<readonly bigint[]>(CORE, coreAbi, "heldStatements")).length;
    const pile = await read<bigint>(CORE, coreAbi, "pileSize");
    const k = await keeperFor({ DOORS: "compose" });
    const t = await k.tick();
    const { o, events } = await assertSent(t, "compose", []);
    assert.equal((await read<readonly bigint[]>(CORE, coreAbi, "heldStatements")).length, held + 1, "one more held statement");
    assert.equal(await read<bigint>(CORE, coreAbi, "pileSize"), pile - 80n, "80 credits left the pile");
    const ev = events.find((e) => e.eventName === "Composed")!;
    assert.equal(ev.args.caller.toLowerCase(), KEEPER.toLowerCase(), "the keeper is the composer");
    assert.ok(o.received > o.spent, `the caller payment ${o.received} covers the gas ${o.spent}`);
  }));

// ------------------------------------------------------------------ buyListing

test("buyListing: a CreditStrategy listing under the bid is swept only after the 2 minute delay, then lands in the pile", () =>
  isolated(async () => {
    const [id] = await strategyIds(1);
    const price = await read<bigint>(CREDIT_STRATEGY, creditStrategyAbi, "nftForSale", [id]);
    const [score] = await creditScores(client, [id]);
    // the owner raises the bid so this listing sits under it: rate = 1.5 * price * RATE_SCORE / score
    const s = await read<any>(CORE, coreAbi, "settings");
    const rate = (price * 3n * 1_000_000n) / (2n * score);
    await call(OWNER, CORE, settingsAbi, "setSettings", [{ ...s, rateCap: rate * 2n }]);
    await call(OWNER, CORE, ownerAbi, "setRate", [rate]);
    await call(A1, CORE, ownerAbi, "fund", [], parseEther("50"));
    const k = await keeperFor({ DOORS: "buyListing", STRATEGY_IDS: id.toString(), LISTING_DELAY_SEC: "120" });
    const first = await k.tick();
    assert.equal(first.outcomes.length, 0, "seen, not swept");
    assert.match(JSON.stringify(first.skips), /seen 0 s ago, delay 120 s/);
    await warp(60);
    const mid = await k.tick();
    assert.equal(mid.outcomes.length, 0, "still inside the delay");
    await warp(61);
    const t = await k.tick();
    const adapter = rec.strategyAdapter as Address;
    const { o, events } = await assertSent(t, "buyListing", [adapter, id, "0x"]);
    assert.equal((await read<Address>(CREDITS, creditsAbi, "ownerOf", [id])).toLowerCase(), CORE.toLowerCase(), "the Core owns the credit");
    const [inPile] = await read<readonly [boolean, bigint, bigint]>(CORE, coreAbi, "creditInfo", [id]);
    assert.equal(inPile, true, "in the pile");
    const ev = events.find((e) => e.eventName === "ListingBought")!;
    assert.equal(ev.args.cost, price, "the Core paid the listing price");
    assert.equal(ev.args.paid, o.received, "the keeper received ListingBought.paid");
    assert.ok(o.received > o.spent);
  }));

// ------------------------------------------------------------------ collectEscrow

// the storage slot of a mapping value, keys in declaration order
const mslot = (keys: Address[], base: bigint) =>
  keys.reduce<Hex>((slot, k) => keccak256(encodeAbiParameters([{ type: "address" }, { type: "bytes32" }], [k, slot])), numberToHex(base, { size: 32 }));

test("collectEscrow: a Core credit in the fee escrow is collected into the pot", () =>
  isolated(async () => {
    const escrow = await read<Address>(CORE, coreAbi, "ESCROW");
    const amount = parseEther("0.02");
    // the seed writes balances[core][address(0)] and totalOwed[address(0)] of the escrow, found by probing its slots,
    // and gives the escrow the eth behind them: the state a partial buyback fill refund leaves
    let found = false;
    for (let b = 0n; b < 16n && !found; b++) {
      const slot = mslot([CORE, zeroAddress], b);
      await setWord(escrow, slot, amount);
      if ((await read<bigint>(escrow, escrowAbi, "balances", [CORE, zeroAddress])) === amount) found = true;
      else await setWord(escrow, slot, 0n);
    }
    assert.ok(found, "found the escrow balances slot");
    const owed = await read<bigint>(escrow, ownerAbi, "totalOwed", [zeroAddress]);
    for (let b = 0n; b < 16n; b++) {
      const slot = mslot([zeroAddress], b);
      const was = BigInt((await client.getStorageAt({ address: escrow, slot })) ?? "0x0");
      await setWord(escrow, slot, was + amount);
      if ((await read<bigint>(escrow, ownerAbi, "totalOwed", [zeroAddress])) === owed + amount) break;
      await setWord(escrow, slot, was);
    }
    await topUp(escrow, amount);
    const pot = await read<bigint>(CORE, coreAbi, "ethPot");
    const k = await keeperFor({ DOORS: "collectEscrow" });
    const t = await k.tick();
    const { events } = await assertSent(t, "collectEscrow", []);
    assert.equal(await read<bigint>(escrow, escrowAbi, "balances", [CORE, zeroAddress]), 0n, "the escrow credit is claimed");
    const ev = events.find((e) => e.eventName === "EscrowCollected");
    assert.ok((await read<bigint>(CORE, coreAbi, "ethPot")) >= pot + amount, "the pot gained the claim");
    assert.ok(ev === undefined || ev.args.amount === amount);
  }));

// ------------------------------------------------------------------ redeemStatement

test("redeemStatement: a held statement at its floor is redeemed into the balance module and the keeper is paid", () =>
  isolated(async () => {
    assert.notEqual(rec.balanceModule, null, "the post phase sets a balance module");
    let held = await read<readonly bigint[]>(CORE, coreAbi, "heldStatements");
    if (held.length === 0) {
      await readyPage();
      await call(A1, CORE, coreAbi, "compose", []);
      held = await read<readonly bigint[]>(CORE, coreAbi, "heldStatements");
    }
    const controller = await read<Address>(CORE, coreAbi, "controller");
    let floors: bigint[] = [];
    for (let i = 0; i < 30 && floors.length === 0; i++) {
      await warp(7 * 86_400);
      const r = await Promise.all(held.map((sid) => read<boolean>(controller, controllerAbi, "atFloor", [sid])));
      floors = held.filter((_, j) => r[j]);
    }
    assert.ok(floors.length > 0, "a held statement reached its floor");
    const k = await keeperFor({ DOORS: "redeemStatement" });
    const t = await k.tick();
    const sid = t.calls[0].args[0] as bigint;
    assert.ok(floors.includes(sid));
    const { o, events } = await assertSent(t, "redeemStatement", [sid]);
    assert.ok(!(await read<readonly bigint[]>(CORE, coreAbi, "heldStatements")).includes(sid), "no longer held");
    assert.ok(events.some((e) => e.eventName === "StatementRedeemed"), "StatementRedeemed");
    assert.ok(o.received > 0n, "the caller payment");
  }));

// ------------------------------------------------------------------ priority and one transaction per tick

test("priority: with a buyback and a compose both due the tick sends only the buyback", () =>
  isolated(async () => {
    await readyPage();
    if ((await read<bigint>(CORE, coreAbi, "ethToBuyback")) < parseEther("0.5")) {
      await setWord(CORE, 7n, parseEther("0.5"));
      await topUp(CORE, parseEther("0.5"));
    }
    await rpc("anvil_mine", [hex(30n)]);
    const k = await keeperFor({});
    const t = await k.tick();
    assert.deepEqual(t.calls.map((c) => c.door).slice(0, 2), ["buyback", "compose"]);
    await assertSent(t, "buyback", []);
    const t2 = await k.tick();
    await assertSent(t2, "compose", []);
  }));
