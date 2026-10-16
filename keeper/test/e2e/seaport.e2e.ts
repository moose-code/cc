// promise: on a chain id 1 fork the keeper sweeps a signed Seaport 1.6 basic order through SeaportBasicAdapter after
// the listing delay, the seller and the allowlisted fee recipient are paid, and a cancelled order is never sent
//
// Seaport's EIP-712 domain uses block.chainid, so an order signed for chain id 1 fills only on a chain id 1 node
// (docs/RUNBOOK.md section 7, commit 25cf843). the seller is a key generated in memory for the run and never written
// anywhere; the order reaches the keeper through SEAPORT_ORDERS, the file shape script/dev/opensea-listings.mjs writes.
// with OPENSEA_API_KEY in the shell the live OpenSea fetch is exercised too.
//
//   CHAIN_ID=1 STACK=master PORT=8609 script/dev/anvil.sh
//   CHAIN_ID=1 STACK=master RPC_URL=http://127.0.0.1:8609 script/deploy.sh local
//   RECORD=deployments/1.json node --test keeper/test/e2e/seaport.e2e.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createPublicClient, encodeFunctionData, http, numberToHex, parseAbi, parseEther, parseGwei, zeroAddress, type Address, type Hex, type PublicClient } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { coreAbi, creditsAbi, seaportAbi } from "@cc/engine/abis";
import { CREDIT_STRATEGY, CREDITS, SEAPORT } from "@cc/engine/addresses";
import { creditScores } from "@cc/engine/snapshot";
import { fetchListings, OPENSEA_FEE } from "@cc/engine/opensea";
import { build } from "../../src/main.ts";
import { encodeBasicOrder } from "../../src/listings.ts";
import { setSink } from "../../src/log.ts";

const ROOT = new URL("../../../", import.meta.url).pathname;
const REC_PATH = process.env.RECORD ?? join(ROOT, "deployments/1.json");
const rec = JSON.parse(readFileSync(REC_PATH, "utf8"));
const RPC: string = process.env.E2E_RPC_URL ?? rec.rpcUrl;
const CORE = rec.core as Address;
const OWNER = rec.owner as Address;
const KEEPER = "0x4444444444444444444444444444444444444444" as Address;
const FUNDER = "0x1111111111111111111111111111111111111111" as Address;
const client = createPublicClient({ transport: http(RPC, { timeout: 120_000 }) }) as PublicClient;

const abi = parseAbi([
  "function setRate(uint256 rate)",
  "function fund() payable",
  "function setApprovalForAll(address operator, bool approved)",
  "function transferFrom(address from, address to, uint256 id)",
  "function getCounter(address offerer) view returns (uint256)",
  "function cancel((address offerer, address zone, (uint8 itemType, address token, uint256 identifierOrCriteria, uint256 startAmount, uint256 endAmount)[] offer, (uint8 itemType, address token, uint256 identifierOrCriteria, uint256 startAmount, uint256 endAmount, address recipient)[] consideration, uint8 orderType, uint256 startTime, uint256 endTime, bytes32 zoneHash, uint256 salt, bytes32 conduitKey, uint256 counter)[] orders) returns (bool)",
  "function getOrderHash((address offerer, address zone, (uint8 itemType, address token, uint256 identifierOrCriteria, uint256 startAmount, uint256 endAmount)[] offer, (uint8 itemType, address token, uint256 identifierOrCriteria, uint256 startAmount, uint256 endAmount, address recipient)[] consideration, uint8 orderType, uint256 startTime, uint256 endTime, bytes32 zoneHash, uint256 salt, bytes32 conduitKey, uint256 counter) order) view returns (bytes32)",
  "function setSettings((uint16 dropPer100PointsBps, uint16 dropFloorBps, uint16 climbPerMinBps, uint16 ceilBps, uint16 idleLoosenBps, uint16 saleFloorBps, uint16 saleToBuybackBps, uint16 recoveryClimbPerMinBps, uint16 recoveryGapBps, uint32 peakHalfLife, uint16 buybackDelay, bool redeemOn, bool balanceBidOn, uint16 redeemSlippageBps, uint16 balanceBidMarginBps, uint16 redeemBurnBps, uint128 buybackSlice, uint64 keeperFee, uint48 keeperMaxBaseFee, uint64 rateCap, uint64 callerFee, uint48 callerMaxBaseFee, uint16 feeToRedeemBurnBps, uint24 payeePpm, uint32 pointsPerPage, uint96 swapFeeCc, uint16 saleToArtistBps, uint16 saleToOperatorBps, uint16 climbMultiplierCapBps, uint16 spendCapBps, uint32 bucketSeconds, uint32 balanceBidCapBps, uint32 idleStepSeconds, uint32 sniperSeconds, uint64 reserveWei, uint32 returnLockSeconds, bool valueModeOn) s)",
]);

const rpc = (method: string, params: unknown[] = []) => client.request({ method: method as any, params: params as any });
const hex = (v: bigint) => numberToHex(v);
async function call(from: Address, to: Address, functionName: string, args: unknown[] = [], value = 0n) {
  await rpc("anvil_impersonateAccount", [from]);
  const data = encodeFunctionData({ abi, functionName, args } as any);
  const hash = (await rpc("eth_sendTransaction", [{ from, to, data, value: hex(value), gas: hex(5_000_000n) }])) as Hex;
  const r = await client.waitForTransactionReceipt({ hash });
  assert.equal(r.status, "success", `${functionName} from ${from} reverted`);
}
const read = <T>(address: Address, a: any, functionName: string, args: unknown[] = []) =>
  client.readContract({ address, abi: a, functionName, args } as any) as Promise<T>;
async function warp(sec: number) {
  await rpc("evm_increaseTime", [sec]);
  await rpc("evm_mine", []);
}

async function strategyIds(n: number): Promise<bigint[]> {
  const src = readFileSync(join(ROOT, "test/utils/CreditIds.sol"), "utf8");
  const data = src.match(/hex"([0-9a-f]+)"/)![1];
  const ids: bigint[] = [];
  for (let i = 0; i + 8 <= data.length && ids.length < n; i += 8) {
    const id = BigInt("0x" + data.slice(i, i + 8));
    const o = await read<Address>(CREDITS, creditsAbi, "ownerOf", [id]).catch(() => zeroAddress);
    if (o.toLowerCase() === CREDIT_STRATEGY.toLowerCase()) ids.push(id);
  }
  return ids;
}

const ORDER_TYPES = {
  OrderComponents: [
    { name: "offerer", type: "address" },
    { name: "zone", type: "address" },
    { name: "offer", type: "OfferItem[]" },
    { name: "consideration", type: "ConsiderationItem[]" },
    { name: "orderType", type: "uint8" },
    { name: "startTime", type: "uint256" },
    { name: "endTime", type: "uint256" },
    { name: "zoneHash", type: "bytes32" },
    { name: "salt", type: "uint256" },
    { name: "conduitKey", type: "bytes32" },
    { name: "counter", type: "uint256" },
  ],
  OfferItem: [
    { name: "itemType", type: "uint8" },
    { name: "token", type: "address" },
    { name: "identifierOrCriteria", type: "uint256" },
    { name: "startAmount", type: "uint256" },
    { name: "endAmount", type: "uint256" },
  ],
  ConsiderationItem: [
    { name: "itemType", type: "uint8" },
    { name: "token", type: "address" },
    { name: "identifierOrCriteria", type: "uint256" },
    { name: "startAmount", type: "uint256" },
    { name: "endAmount", type: "uint256" },
    { name: "recipient", type: "address" },
  ],
} as const;

const ZERO32 = ("0x" + "00".repeat(32)) as Hex;

// a seller holding credit `id` lists it on Seaport 1.6 for `price` in total, 2.5 percent to the OpenSea fee collector
async function listOnSeaport(id: bigint, price: bigint) {
  const seller = privateKeyToAccount(generatePrivateKey());
  await rpc("anvil_setBalance", [seller.address, hex(parseEther("1"))]);
  await rpc("anvil_setBalance", [CREDIT_STRATEGY, hex((await client.getBalance({ address: CREDIT_STRATEGY })) + parseEther("1"))]);
  await call(CREDIT_STRATEGY, CREDITS, "transferFrom", [CREDIT_STRATEGY, seller.address, id]);
  await call(seller.address, CREDITS, "setApprovalForAll", [SEAPORT, true]);
  const fee = (price * 250n) / 10_000n;
  const now = (await client.getBlock()).timestamp;
  const order = {
    offerer: seller.address,
    zone: zeroAddress,
    offer: [{ itemType: 2, token: CREDITS, identifierOrCriteria: id, startAmount: 1n, endAmount: 1n }],
    consideration: [
      { itemType: 0, token: zeroAddress, identifierOrCriteria: 0n, startAmount: price - fee, endAmount: price - fee, recipient: seller.address },
      { itemType: 0, token: zeroAddress, identifierOrCriteria: 0n, startAmount: fee, endAmount: fee, recipient: OPENSEA_FEE as Address },
    ],
    orderType: 0,
    startTime: now - 60n,
    endTime: now + 30n * 86_400n,
    zoneHash: ZERO32,
    salt: BigInt(Date.now()),
    conduitKey: ZERO32,
    counter: await read<bigint>(SEAPORT, abi, "getCounter", [seller.address]),
  };
  const signature = await seller.signTypedData({
    domain: { name: "Seaport", version: "1.6", chainId: 1, verifyingContract: SEAPORT },
    types: ORDER_TYPES,
    primaryType: "OrderComponents",
    message: order,
  });
  const hash = await read<Hex>(SEAPORT, abi, "getOrderHash", [order]);
  const params = {
    considerationToken: zeroAddress,
    considerationIdentifier: "0",
    considerationAmount: (price - fee).toString(),
    offerer: seller.address,
    zone: zeroAddress,
    offerToken: CREDITS,
    offerIdentifier: id.toString(),
    offerAmount: "1",
    basicOrderType: "0",
    startTime: order.startTime.toString(),
    endTime: order.endTime.toString(),
    zoneHash: ZERO32,
    salt: order.salt.toString(),
    offererConduitKey: ZERO32,
    fulfillerConduitKey: ZERO32,
    totalOriginalAdditionalRecipients: "1",
    additionalRecipients: [{ amount: fee.toString(), recipient: OPENSEA_FEE }],
    signature,
  };
  return { seller, order, hash, entry: { id: id.toString(), price: price.toString(), hash, params }, fee };
}

// the owner raises the bid so a credit of `score` bids 1.5 times `price`, and funds the pot
async function bidAbove(price: bigint, id: bigint) {
  const [score] = await creditScores(client, [id]);
  const s = await read<any>(CORE, coreAbi, "settings");
  const rate = (price * 3n * 1_000_000n) / (2n * score);
  await call(OWNER, CORE, "setSettings", [{ ...s, rateCap: rate * 2n > s.rateCap ? rate * 2n : s.rateCap }]);
  await call(OWNER, CORE, "setRate", [rate]);
  await rpc("anvil_setBalance", [FUNDER, hex(parseEther("100"))]);
  await call(FUNDER, CORE, "fund", [], parseEther("20"));
  await rpc("anvil_setBalance", [KEEPER, hex(parseEther("10"))]);
}

async function keeper(ordersFile: string) {
  await rpc("anvil_setNextBlockBaseFeePerGas", [hex(parseGwei("1"))]);
  await rpc("evm_mine", []);
  return (
    await build({
      RECORD: REC_PATH,
      RPC_URLS: RPC,
      IMPERSONATE: KEEPER,
      STATE_DIR: mkdtempSync(join(tmpdir(), "keeper-sp-")),
      STRATEGY_IDS: "off",
      SEAPORT_ORDERS: ordersFile,
      DOORS: "buyListing",
      LISTING_DELAY_SEC: "120",
    } as any)
  ).keeper;
}

const lines: string[] = [];

test("seaport: a signed basic order under the bid is swept after the delay on the chain id 1 fork", async () => {
  assert.equal(await client.getChainId(), 1, "a chain id 1 node");
  setSink((l) => lines.push(l));
  const snap = await rpc("evm_snapshot");
  try {
    const [id] = await strategyIds(1);
    const price = parseEther("0.01");
    const l = await listOnSeaport(id, price);
    await bidAbove(price, id);
    const dir = mkdtempSync(join(tmpdir(), "keeper-orders-"));
    const file = join(dir, "orders.json");
    writeFileSync(file, JSON.stringify({ count: 1, orders: [l.entry] }));

    const k = await keeper(file);
    const first = await k.tick();
    assert.equal(first.outcomes.length, 0, "seen, not swept");
    assert.match(JSON.stringify(first.skips), /seen 0 s ago, delay 120 s/);
    await warp(121);
    const sellerBefore = await client.getBalance({ address: l.seller.address });
    const feeBefore = await client.getBalance({ address: OPENSEA_FEE as Address });
    const t = await k.tick();
    const sent = t.outcomes.filter((o) => o.outcome.kind === "sent");
    assert.equal(sent.length, 1, JSON.stringify(t.outcomes, (_, v) => (typeof v === "bigint" ? v.toString() : v)));
    const o = sent[0].outcome as any;
    assert.equal(o.status, "success");
    const tx = await client.getTransaction({ hash: o.hash });
    const params = encodeBasicOrder(l.entry.params);
    assert.equal(tx.input, encodeFunctionData({ abi: coreAbi, functionName: "buyListing", args: [rec.seaportAdapter, id, params] }), "buyListing(seaportAdapter, id, abi.encode(BasicOrderParameters))");
    assert.equal((await read<Address>(CREDITS, creditsAbi, "ownerOf", [id])).toLowerCase(), CORE.toLowerCase(), "the Core owns the credit");
    assert.equal((await client.getBalance({ address: l.seller.address })) - sellerBefore, price - l.fee, "the seller is paid");
    assert.equal((await client.getBalance({ address: OPENSEA_FEE as Address })) - feeBefore, l.fee, "the fee recipient is paid");
    const [, cancelled, filled] = await read<readonly [boolean, boolean, bigint, bigint]>(SEAPORT, seaportAbi, "getOrderStatus", [l.hash]);
    assert.equal(cancelled, false);
    assert.equal(filled, 1n, "the order is filled");
    assert.ok(o.received > o.spent, "the keeper is paid more than its gas");
    console.log(`  seaport sweep: ${o.hash} id ${id} price ${price} paid ${o.received} gas ${o.spent}`);
  } finally {
    await rpc("evm_revert", [snap]);
    setSink((l) => process.stdout.write(l + "\n"));
  }
});

test("seaport: a cancelled order is skipped before any simulation", async () => {
  setSink((l) => lines.push(l));
  const snap = await rpc("evm_snapshot");
  try {
    const [, id] = await strategyIds(2);
    const price = parseEther("0.01");
    const l = await listOnSeaport(id, price);
    await bidAbove(price, id);
    await call(l.seller.address, SEAPORT, "cancel", [[l.order]]);
    const file = join(mkdtempSync(join(tmpdir(), "keeper-orders-")), "orders.json");
    writeFileSync(file, JSON.stringify({ count: 1, orders: [l.entry] }));
    const k = await keeper(file);
    await warp(121);
    const t = await k.tick();
    assert.equal(t.outcomes.length, 0, "nothing sent");
    assert.match(JSON.stringify(t.skips), /order cancelled/);
  } finally {
    await rpc("evm_revert", [snap]);
    setSink((l) => process.stdout.write(l + "\n"));
  }
});

test("seaport: the live OpenSea fetch returns orders the adapter quotes", { skip: !process.env.OPENSEA_API_KEY && "OPENSEA_API_KEY is not set in the shell" }, async () => {
  const r = await fetchListings({ key: process.env.OPENSEA_API_KEY!, rpc: RPC, adapter: rec.seaportAdapter, pages: 1, sign: 5, horizon: 86_400 * 365 });
  console.log(`  opensea: fetched ${r.fetched}, fit ${r.fit}, signed ${r.orders.length}, dropped ${JSON.stringify(r.dropped)}`);
  for (const o of r.orders) {
    const q = await client.readContract({ address: rec.seaportAdapter, abi: parseAbi(["function price(uint256 id, bytes params) view returns (address, uint256, bytes)"]), functionName: "price", args: [BigInt(o.id), encodeBasicOrder(o.params)] });
    assert.equal(q[1], BigInt(o.price), "the adapter quotes the listed price");
  }
});

