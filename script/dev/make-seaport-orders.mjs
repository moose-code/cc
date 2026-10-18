// Builds signed Seaport 1.6 basic orders from fresh in-memory keys for `script/dev/e2e-real.sh` phase 4, priced 10
// percent under the Core's eth bid, and writes the SEAPORT_ORDERS file the keeper reads. A chain id 1 node only, since
// Seaport derives its EIP-712 domain from block.chainid. The seller keys are generated for the run and never written.
//
//   RECORD=deployments/1.json RPC=http://127.0.0.1:8620 OUT=/tmp/orders.json COUNT=2 node script/dev/make-seaport-orders.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { createPublicClient, encodeFunctionData, http, numberToHex, parseAbi, parseEther, zeroAddress } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { coreAbi, creditsAbi } from "@cc/engine/abis";
import { CREDIT_STRATEGY, CREDITS, SEAPORT } from "@cc/engine/addresses";

const REC_PATH = process.env.RECORD ?? "deployments/1.json";
const rec = JSON.parse(readFileSync(REC_PATH, "utf8"));
const RPC = process.env.RPC ?? rec.rpcUrl;
const OUT = process.env.OUT ?? "/tmp/seaport-orders.json";
const COUNT = Number(process.env.COUNT ?? "2");
const CORE = rec.core;
const OPENSEA_FEE = "0x0000a26b00c1F0DF003000390027140000fAa719";
const client = createPublicClient({ transport: http(RPC, { timeout: 120_000 }) });

const abi = parseAbi([
  "function setApprovalForAll(address operator, bool approved)",
  "function transferFrom(address from, address to, uint256 id)",
  "function getCounter(address offerer) view returns (uint256)",
]);
const rpc = (method, params = []) => client.request({ method, params });
const hex = (v) => numberToHex(v);
async function send(from, to, functionName, args = [], value = 0n) {
  await rpc("anvil_impersonateAccount", [from]);
  const data = encodeFunctionData({ abi, functionName, args });
  const h = await rpc("eth_sendTransaction", [{ from, to, data, value: hex(value), gas: hex(1_000_000n) }]);
  const r = await client.waitForTransactionReceipt({ hash: h });
  if (r.status !== "success") throw new Error(`${functionName} from ${from} reverted`);
}

async function strategyIds(n) {
  const src = readFileSync("test/utils/CreditIds.sol", "utf8");
  const data = src.match(/hex"([0-9a-f]+)"/)[1];
  const ids = [];
  for (let i = 0; i + 8 <= data.length && ids.length < n; i += 8) {
    const id = BigInt("0x" + data.slice(i, i + 8));
    const o = await client.readContract({ address: CREDITS, abi: creditsAbi, functionName: "ownerOf", args: [id] }).catch(() => zeroAddress);
    if (o.toLowerCase() === CREDIT_STRATEGY.toLowerCase()) ids.push(id);
  }
  return ids;
}

const ORDER_TYPES = {
  OrderComponents: [
    { name: "offerer", type: "address" }, { name: "zone", type: "address" }, { name: "offer", type: "OfferItem[]" },
    { name: "consideration", type: "ConsiderationItem[]" }, { name: "orderType", type: "uint8" },
    { name: "startTime", type: "uint256" }, { name: "endTime", type: "uint256" }, { name: "zoneHash", type: "bytes32" },
    { name: "salt", type: "uint256" }, { name: "conduitKey", type: "bytes32" }, { name: "counter", type: "uint256" },
  ],
  OfferItem: [
    { name: "itemType", type: "uint8" }, { name: "token", type: "address" }, { name: "identifierOrCriteria", type: "uint256" },
    { name: "startAmount", type: "uint256" }, { name: "endAmount", type: "uint256" },
  ],
  ConsiderationItem: [
    { name: "itemType", type: "uint8" }, { name: "token", type: "address" }, { name: "identifierOrCriteria", type: "uint256" },
    { name: "startAmount", type: "uint256" }, { name: "endAmount", type: "uint256" }, { name: "recipient", type: "address" },
  ],
};
const ZERO32 = "0x" + "00".repeat(32);

async function listOne(id) {
  const bid = await client.readContract({ address: CORE, abi: coreAbi, functionName: "bidOf", args: [id] });
  if (bid === 0n) throw new Error(`bidOf(${id}) is zero; prime the bid first`);
  const price = (bid * 90n) / 100n; // 10 percent under the eth bid
  const seller = privateKeyToAccount(generatePrivateKey());
  await rpc("anvil_setBalance", [seller.address, hex(parseEther("1"))]);
  await rpc("anvil_setBalance", [CREDIT_STRATEGY, hex((await client.getBalance({ address: CREDIT_STRATEGY })) + parseEther("1"))]);
  await send(CREDIT_STRATEGY, CREDITS, "transferFrom", [CREDIT_STRATEGY, seller.address, id]);
  await send(seller.address, CREDITS, "setApprovalForAll", [SEAPORT, true]);
  const fee = (price * 250n) / 10_000n;
  const now = (await client.getBlock()).timestamp;
  const order = {
    offerer: seller.address,
    zone: zeroAddress,
    offer: [{ itemType: 2, token: CREDITS, identifierOrCriteria: id, startAmount: 1n, endAmount: 1n }],
    consideration: [
      { itemType: 0, token: zeroAddress, identifierOrCriteria: 0n, startAmount: price - fee, endAmount: price - fee, recipient: seller.address },
      { itemType: 0, token: zeroAddress, identifierOrCriteria: 0n, startAmount: fee, endAmount: fee, recipient: OPENSEA_FEE },
    ],
    orderType: 0,
    startTime: now - 60n,
    endTime: now + 30n * 86_400n,
    zoneHash: ZERO32,
    salt: BigInt(Date.now()) + id,
    conduitKey: ZERO32,
    counter: await client.readContract({ address: SEAPORT, abi, functionName: "getCounter", args: [seller.address] }),
  };
  const signature = await seller.signTypedData({
    domain: { name: "Seaport", version: "1.6", chainId: 1, verifyingContract: SEAPORT },
    types: ORDER_TYPES,
    primaryType: "OrderComponents",
    message: order,
  });
  return {
    id: id.toString(),
    price: price.toString(),
    params: {
      considerationToken: zeroAddress, considerationIdentifier: "0", considerationAmount: (price - fee).toString(),
      offerer: seller.address, zone: zeroAddress, offerToken: CREDITS, offerIdentifier: id.toString(), offerAmount: "1",
      basicOrderType: "0", startTime: order.startTime.toString(), endTime: order.endTime.toString(), zoneHash: ZERO32,
      salt: order.salt.toString(), offererConduitKey: ZERO32, fulfillerConduitKey: ZERO32,
      totalOriginalAdditionalRecipients: "1", additionalRecipients: [{ amount: fee.toString(), recipient: OPENSEA_FEE }],
      signature,
    },
  };
}

const ids = await strategyIds(COUNT);
if (ids.length < COUNT) throw new Error(`only ${ids.length} strategy credits available, need ${COUNT}`);
const orders = [];
for (const id of ids) orders.push(await listOne(id));
writeFileSync(OUT, JSON.stringify({ count: orders.length, orders }));
console.log(`SEAPORT_ORDERS ${OUT}`);
for (const o of orders) console.log(`ORDER id ${o.id} price ${o.price}`);
