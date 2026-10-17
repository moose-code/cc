// promise: the keeper on real hook income. with no fund(), fee income arrives only through the hook (the skim a real
// pool swap pushes to the Core). the real keeper binary, run as the record's keeper, then: decides no refreshReference
// while the mode is off, books after the latch rule once the window is over and income is pending, buys a strategy
// listing the tick it dips under the Core-computed bid, buybacks once the slice fits, and composes when a page is ready.
//
// needs the node of deployments/31337.json running (script/dev/e2e.sh KEEP=1, or script/dev/local.sh). each test seeds
// its door's state, runs ticks of the in process keeper with only that door on, asserts the transaction and the state
// after, and reverts the node to the snapshot it started from. the keeper sends as the record's keeper, impersonated.
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createPublicClient,
  encodeFunctionData,
  http,
  numberToHex,
  parseAbi,
  parseEther,
  parseGwei,
  zeroAddress,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { coreAbi, controllerAbi, creditStrategyAbi, creditsAbi } from "@cc/engine/abis";
import { CREDIT_STRATEGY, CREDITS } from "@cc/engine/addresses";
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
  "function fund() payable",
  "function book()",
  "function sellForEth(uint256[] ids, uint256 minOut)",
  "function setApprovalForAll(address operator, bool approved)",
  "function transferFrom(address from, address to, uint256 id)",
  "function HOOK() view returns (address)",
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
const setWord = (address: Address, slot: bigint, v: bigint) =>
  rpc("anvil_setStorageAt", [address, numberToHex(slot, { size: 32 }), numberToHex(v, { size: 32 })]);

// the skim a real pool swap pushes to the Core: the hook is the only sender the Core accepts besides the escrow. no fund()
async function hookIncome(eth: bigint) {
  const hook = await read<Address>(CORE, ownerAbi, "HOOK");
  await topUp(hook, eth + parseEther("1"));
  await send(hook, CORE, "0x", eth);
}

// clears the payee latch (payeeOn is byte 20 of slot 22, test/CoreLayout.t.sol), so the latch rule applies
async function clearPayee() {
  const w = await word(22n, CORE);
  await setWord(CORE, 22n, w & ~(0xffn << 160n));
  assert.equal(await read(CORE, coreAbi, "payeeOn"), false);
}

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

// ------------------------------------------------------------------ the keeper

function env(over: Record<string, string>) {
  return {
    RECORD: REC_PATH,
    RPC_URLS: RPC,
    IMPERSONATE: KEEPER,
    STATE_DIR: mkdtempSync(join(tmpdir(), "keeper-launch-e2e-")),
    STRATEGY_IDS: "off",
    ...over,
  };
}

async function keeperFor(over: Record<string, string>) {
  await rpc("anvil_setNextBlockBaseFeePerGas", [hex(parseGwei("1"))]);
  await rpc("evm_mine", []);
  return (await build(env(over) as any)).keeper;
}

async function assertSent(t: TickResult, door: string) {
  const sent = t.outcomes.filter((o) => o.outcome.kind === "sent");
  assert.equal(sent.length, 1, `one transaction sent, outcomes: ${JSON.stringify(t.outcomes, (_, v) => (typeof v === "bigint" ? v.toString() : v))}`);
  assert.equal(sent[0].door, door, `the sent door is ${door}`);
  const o = sent[0].outcome as Extract<TickResult["outcomes"][number]["outcome"], { kind: "sent" }>;
  assert.equal(o.status, "success");
  const tx = await client.getTransaction({ hash: o.hash });
  assert.equal(tx.from.toLowerCase(), KEEPER.toLowerCase(), "sent by the keeper");
  assert.equal(tx.to?.toLowerCase(), CORE.toLowerCase(), "to the Core");
  return o;
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
    process.stderr.write(lines.filter((l) => !l.includes('"msg":"keeper start"')).slice(-25).join("\n") + "\n");
    throw e;
  } finally {
    await rpc("evm_revert", [snap]);
  }
}

// ------------------------------------------------------------------ mode off: no refreshReference

test("mode off: the keeper decides no refreshReference, the reference pool key is unset", () =>
  isolated(async () => {
    // value mode is off at launch (no balance pool key set), so the controller holds no reference to refresh
    const k = await keeperFor({ DOORS: "refreshReference" });
    const t = await k.tick();
    assert.equal(t.calls.length, 0, "no refreshReference decided with the mode off");
    assert.match(JSON.stringify(t.skips), /pool key is not set|referenceMaxStale is 0/, "the skip names the unusable reference");
  }));

// ------------------------------------------------------------------ book after the latch rule, on hook income only

test("book latch: with the window over and hook income pending, the tick books and latches the payee share", () =>
  isolated(async () => {
    await clearPayee();
    const potBefore = await read<bigint>(CORE, coreAbi, "ethPot");
    await hookIncome(parseEther("3")); // the skim of a real buy, no fund(): it waits above the pots until a book
    assert.equal(await read<bigint>(CORE, coreAbi, "ethPot"), potBefore, "the hook income waits above the pot until a book");
    await warp(4000); // past the anti sniper window, so a book latches
    const k = await keeperFor({ DOORS: "book" });
    const t = await k.tick();
    await assertSent(t, "book");
    assert.equal(await read<boolean>(CORE, coreAbi, "payeeOn"), true, "the book latched the payee share");
    assert.ok((await read<bigint>(CORE, coreAbi, "ethPot")) > potBefore, "the hook income booked into the pot");
    // the eth bid is now computed by the Core from the booked income, with no setRate
    assert.ok((await read<bigint>(CORE, coreAbi, "ethRate")) > 0n, "the bid is nonzero from the booked hook income");
    const second = await k.tick();
    assert.equal(second.outcomes.length, 0, "a latched payee share is not booked again by the keeper");
  }));

// ------------------------------------------------------------------ buyback once the slice fits

test("buyback: once the delay has passed with a slice above 2 * maxPay, the tick sends buyback()", () =>
  isolated(async () => {
    // the buyback pot the 25 percent sale split fills (ethToBuyback is slot 7), with the eth behind it
    const pot = await read<bigint>(CORE, coreAbi, "ethToBuyback");
    if (pot < parseEther("0.5")) {
      await setWord(CORE, 7n, parseEther("0.5"));
      await topUp(CORE, parseEther("0.5") - pot);
    }
    await rpc("anvil_mine", [hex(30n)]);
    const before = await read<bigint>(CORE, coreAbi, "ethToBuyback");
    const k = await keeperFor({ DOORS: "buyback" });
    const t = await k.tick();
    const o = await assertSent(t, "buyback");
    assert.ok(o.received > o.spent, "the keeper was paid more than its gas");
    assert.ok((await read<bigint>(CORE, coreAbi, "ethToBuyback")) < before, "the slice left the buyback pot");
  }));

// ------------------------------------------------------------------ compose when a page is ready, pile filled from the bid

test("compose: a page filled from the Core bid (hook income, no fund) composes", () =>
  isolated(async () => {
    await clearPayee();
    await hookIncome(parseEther("60")); // the skim stream a day of buys pushes, no fund()
    await call(KEEPER, CORE, ownerAbi, "book", []); // book the income at the opening bid so the pile fills are cheap
    const size = await read<bigint>(CORE, coreAbi, "pileSize");
    const need = size >= 80n ? 0 : 80 - Number(size);
    if (need > 0) {
      const ids = await strategyIds(need);
      assert.equal(ids.length, need, "enough strategy credits on the fork");
      await topUp(CREDIT_STRATEGY, parseEther("1"));
      for (const id of ids) await call(CREDIT_STRATEGY, CREDITS, ownerAbi, "transferFrom", [CREDIT_STRATEGY, A1, id]);
      await call(A1, CREDITS, ownerAbi, "setApprovalForAll", [CORE, true]);
      // chunks of 20: an 80 credit batch sell exceeds the 15M gas the dev send sets, so fill in blocks that fit
      for (let i = 0; i < ids.length; i += 20) {
        await call(A1, CORE, ownerAbi, "sellForEth", [ids.slice(i, i + 20), 0n]);
      }
    }
    const controller = await read<Address>(CORE, coreAbi, "controller");
    const window = await read<number>(controller, controllerAbi, "creditWindow");
    await warp(Number(window) + 60);
    const [ready] = await read<readonly [boolean, readonly bigint[], number]>(controller, controllerAbi, "nextPage");
    assert.equal(ready, true, "nextPage is ready");
    const held = (await read<readonly bigint[]>(CORE, coreAbi, "heldStatements")).length;
    const k = await keeperFor({ DOORS: "compose" });
    const t = await k.tick();
    const o = await assertSent(t, "compose");
    assert.equal((await read<readonly bigint[]>(CORE, coreAbi, "heldStatements")).length, held + 1, "one more held statement");
    assert.ok(o.received > o.spent, "the caller payment covers the gas");
  }));

// ------------------------------------------------------------------ buyListing the tick it dips under the Core bid

test("buyListing: the bid climbs from booked hook income until a strategy listing dips under it, then it is swept", () =>
  isolated(async () => {
    const id = 35377n; // the strategy listing the launch day reaches as the bid climbs (test/utils/Fixture.sol LISTED_A)
    assert.equal(
      (await read<Address>(CREDITS, creditsAbi, "ownerOf", [id]).catch(() => zeroAddress)).toLowerCase(),
      CREDIT_STRATEGY.toLowerCase(),
      "the listing is still on the strategy at this fork block",
    );
    const price = await read<bigint>(CREDIT_STRATEGY, creditStrategyAbi, "nftForSale", [id]);
    assert.ok(price > 0n, "the strategy lists the credit");
    // hook income only (no fund), booked, then the bid climbs toward its cap over the hours
    await clearPayee();
    await hookIncome(price * 40n);
    await warp(4000);
    await call(KEEPER, CORE, ownerAbi, "book", []);
    await warp(4 * 3600); // the bid climbs toward the rate cap from the booked income, no setRate
    const ethBid = await read<bigint>(CORE, coreAbi, "bidOf", [id]);
    assert.ok(ethBid >= price, `the Core bid ${ethBid} dipped under the listing price ${price} as it climbed`);
    const k = await keeperFor({ DOORS: "buyListing", STRATEGY_IDS: id.toString(), LISTING_DELAY_SEC: "120" });
    const first = await k.tick();
    assert.equal(first.outcomes.length, 0, "seen, not swept before the delay");
    assert.match(JSON.stringify(first.skips), /seen 0 s ago, delay 120 s/);
    await warp(121);
    const t = await k.tick();
    const o = await assertSent(t, "buyListing");
    assert.equal((await read<Address>(CREDITS, creditsAbi, "ownerOf", [id])).toLowerCase(), CORE.toLowerCase(), "the Core owns the swept credit");
    const [inPile] = await read<readonly [boolean, bigint, bigint]>(CORE, coreAbi, "creditInfo", [id]);
    assert.equal(inPile, true, "the swept credit is in the pile");
    assert.ok(o.received > o.spent, "the keeper was paid at least its gas");
  }));
