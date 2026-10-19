// The engine snapshot: one pinned multicall over the views of docs/INTEGRATION.md
// section 2. web/ polls it for every page, keeper/ reads it once per block.

import { zeroAddress, type Address, type PublicClient } from "viem";
import { controllerAbi, coreAbi, moduleAbi, multicallAbi, scoreAbi, seedAbi, statementsAbi } from "./abis.ts";
import { CREDIT_SCORE, CREDITS, STATEMENTS } from "./addresses.ts";

// the client surface the snapshot reads through; a wagmi public client and a viem public client both satisfy it
export type ReadClient = Pick<PublicClient, "multicall" | "getBlockNumber">;

export const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;
export const mc = { multicallAddress: MULTICALL3, batchSize: 16_384 } as const;

// Runs `read` with the latest block number so every RPC of one quote sees the same state. A node that refuses the
// pinned read (pruned or not yet synced at that block) gets one unpinned retry, reported as pinned: false.
export async function atBlock<T>(
  client: Pick<PublicClient, "getBlockNumber">,
  read: (blockNumber?: bigint) => Promise<T>,
): Promise<{ value: T; pinned: boolean; blockNumber?: bigint }> {
  let n: bigint | undefined;
  try {
    n = await client.getBlockNumber();
    return { value: await read(n), pinned: true, blockNumber: n };
  } catch {
    return { value: await read(), pinned: false };
  }
}

// The fee income the Core holds above its tracked pots and the parts the next Core._book books (Core._income, _split).
export function pendingIncome(
  coreEth: bigint,
  ethPot: bigint,
  ethToBuyback: bigint,
  ethRedeemBurn: bigint,
  payeeOn: boolean,
  payeePpm: number,
  feeToRedeemBurnBps: number,
) {
  const booked = ethPot + ethToBuyback + ethRedeemBurn;
  const income = coreEth > booked ? coreEth - booked : 0n;
  const toPayee = payeeOn ? (income * BigInt(payeePpm)) / 1_000_000n : 0n;
  const toRedeemBurn = ((income - toPayee) * BigInt(feeToRedeemBurnBps)) / 10000n;
  return { income, toPayee, toRedeemBurn, toPot: income - toPayee - toRedeemBurn };
}

// blockNumber is the block every read of the snapshot was pinned to, undefined when the node refused pinned reads
export async function readSnapshot(client: ReadClient, coreAddr: Address) {
  const { value, pinned, blockNumber } = await atBlock(client, (n) => snapshotAt(client, coreAddr, n));
  return { ...value, pinned, blockNumber };
}

async function snapshotAt(client: ReadClient, coreAddr: Address, blockNumber?: bigint) {
  const c = { address: coreAddr, abi: coreAbi } as const;
  const [
    floorRate,
    ethPot,
    ethToBuyback,
    ethRedeemBurn,
    payee,
    pileSize,
    held,
    settings,
    paused,
    retired,
    chosenComposeOn,
    minCcToChoose,
    controller,
    coin,
    balanceModule,
    balanceToken,
    payeeOn,
    coreEth,
    balanceRate,
    artist,
    creditCostToPotBps,
  ] = await client.multicall({
    ...mc,
    blockNumber,
    allowFailure: false,
    contracts: [
      { ...c, functionName: "floorRate" },
      { ...c, functionName: "ethPot" },
      { ...c, functionName: "ethToBuyback" },
      { ...c, functionName: "ethRedeemBurn" },
      { ...c, functionName: "payee" },
      { ...c, functionName: "pileSize" },
      { ...c, functionName: "heldStatements" },
      { ...c, functionName: "settings" },
      { ...c, functionName: "paused" },
      { ...c, functionName: "retired" },
      { ...c, functionName: "chosenComposeOn" },
      { ...c, functionName: "minCcToChoose" },
      { ...c, functionName: "controller" },
      { ...c, functionName: "COIN" },
      { ...c, functionName: "balanceModule" },
      { ...c, functionName: "balanceToken" },
      { ...c, functionName: "payeeOn" },
      { address: MULTICALL3, abi: multicallAbi, functionName: "getEthBalance", args: [coreAddr] },
      { ...c, functionName: "balanceRate" },
      { ...c, functionName: "artist" },
      { ...c, functionName: "creditCostToPotBps" },
    ] as const,
  });
  // the pot scaled climb multiplier (decision 128), a tolerant read so a pre-128 Core without the view does not blank
  // the whole snapshot. defaults to 1x (10_000 bps) when the Core does not answer
  // and the reserve (the eth the pot keeps for processing), a tolerant read that defaults to 0 for a Core without it
  // In value mode an unusable protected quote makes the Core return zero for the ETH bid and price. A failed Core
  // read also yields zero for these snapshot fields while leaving other fields available.
  const [climbMultiplierRes, reserveRes, ethRateRes, ethPriceRes] = await client.multicall({
    ...mc,
    blockNumber,
    allowFailure: true,
    contracts: [
      { ...c, functionName: "climbMultiplier" },
      { ...c, functionName: "reserve" },
      { ...c, functionName: "ethRate" },
      { ...c, functionName: "ethPrice" },
    ] as const,
  });
  const climbMultiplier = climbMultiplierRes.status === "success" ? (climbMultiplierRes.result as bigint) : 10_000n;
  const reserve = reserveRes.status === "success" ? (reserveRes.result as bigint) : 0n;
  const ethRate = ethRateRes.status === "success" ? (ethRateRes.result as bigint) : 0n;
  const ethPrice = ethPriceRes.status === "success" ? (ethPriceRes.result as bigint) : 0n;
  const valueModeOn = (settings as { valueModeOn?: boolean }).valueModeOn === true;
  // ethPot plus the share of the unbooked fee income that the next Core._book adds (Core._income, _split)
  const pending = pendingIncome(coreEth, ethPot, ethToBuyback, ethRedeemBurn, payeeOn, settings.payeePpm, settings.feeToRedeemBurnBps);
  const potWithPending = ethPot + pending.toPot;
  // the most the bids may spend: the pot with the pending share less the reserve, the clamp of Core.ethRate
  const potRoom = potWithPending > reserve ? potWithPending - reserve : 0n;
  // the balance token is held by the module, not the Core: the pot of the bid is the module's available() holding
  // A failing module read leaves both undefined and the rest of the snapshot intact; consumers show the balance side
  // as unavailable (the Core treats a failing module as a closed balance bid).
  const [availableRes, unitRes] = balanceModule !== zeroAddress
    ? await client.multicall({
        ...mc,
        blockNumber,
        allowFailure: true,
        contracts: [
          { address: balanceModule, abi: moduleAbi, functionName: "available" },
          { address: balanceModule, abi: moduleAbi, functionName: "unitPerPoint" },
        ] as const,
      })
    : [{ status: "success", result: 0n }, { status: "success", result: 0n }];
  const balanceAvailable = availableRes.status === "success" && unitRes.status === "success" ? (availableRes.result as bigint) : undefined;
  const balanceUnit = availableRes.status === "success" && unitRes.status === "success" ? (unitRes.result as bigint) : undefined;
  const k = { address: controller, abi: controllerAbi } as const;
  const [creditSaleOn, creditWindow, pointRate, page] = await client.multicall({
    ...mc,
    blockNumber,
    allowFailure: false,
    contracts: [
      { ...k, functionName: "creditSaleOn" },
      { ...k, functionName: "creditWindow" },
      { ...k, functionName: "pointRate" },
      { ...k, functionName: "nextPage" },
    ] as const,
  });
  // Price curve parameters and the statement supply. A failing read leaves the field undefined and the rest of the
  // snapshot intact; consumers hide the figure that needs it.
  const [markupRes, startCapRes, decayRes, anchorRes, startRes, floorRes, creditStartRes, supplyRes] = await client.multicall({
    ...mc,
    blockNumber,
    allowFailure: true,
    contracts: [
      { ...k, functionName: "markupBps" },
      { ...k, functionName: "startCapBps" },
      { ...k, functionName: "decayHours" },
      { ...k, functionName: "anchorBps" },
      { ...k, functionName: "startBps" },
      { ...k, functionName: "floorMultBps" },
      { ...k, functionName: "creditStartBps" },
      { address: STATEMENTS, abi: statementsAbi, functionName: "supply" },
    ] as const,
  });
  // the protected price (decision 148): the controller's reference of the balance token against the pool spot, both
  // wei per 1e18 base units, the reference's age and the quote settings, and the value of one point at the buy and sale
  // prices. a controller without them leaves the fields undefined
  const [refRes, refTimeRes, spotRes, quoteRes, buyRes, sellRes] = await client.multicall({
    ...mc,
    blockNumber,
    allowFailure: true,
    contracts: [
      { ...k, functionName: "referencePrice" },
      { ...k, functionName: "referenceTime" },
      { ...k, functionName: "spotPrice" },
      { ...k, functionName: "quote" },
      { ...k, functionName: "valuePerPoint", args: [false] },
      { ...k, functionName: "valuePerPoint", args: [true] },
    ] as const,
  });
  const ok = <T,>(r: { status: string; result?: unknown }): T | undefined => (r.status === "success" ? (r.result as T) : undefined);
  const spot = ok<readonly [bigint, boolean]>(spotRes);
  const q = ok<readonly [number, number, number, number, number, bigint]>(quoteRes);
  const vBuy = ok<readonly [bigint, boolean]>(buyRes);
  const vSell = ok<readonly [bigint, boolean]>(sellRes);
  const value = {
    on: valueModeOn,
    referencePrice: ok<bigint>(refRes),
    referenceTime: ok<number>(refTimeRes),
    spot: spot && spot[1] ? spot[0] : undefined,
    quote: q && { referenceRateBpsPerHour: q[0], referenceStepBps: q[1], tolBps: q[2], referenceMaxStale: q[3], referenceMinSeconds: q[4], minLiquidity: q[5] },
    // usable is the controller's own answer: the reference fresh, the pool deep enough, a spot and a unit read
    usable: vBuy !== undefined && vBuy[1],
    perPointBuy: vBuy && vBuy[1] ? vBuy[0] : undefined,
    perPointSell: vSell && vSell[1] ? vSell[0] : undefined,
  };
  const noQuote = valueModeOn && !value.usable;
  const num = (r: { status: string; result?: unknown }) => {
    const v = ok<bigint | number>(r);
    return v === undefined ? undefined : Number(v);
  };
  const statementSupply = ok<bigint>(supplyRes);
  return {
    // In value mode an unusable protected quote sets noQuote; the Core ETH bid reads zero.
    ethRate,
    ethPrice,
    noQuote,
    value,
    floorRate,
    climbMultiplier,
    ethPot,
    potWithPending,
    // the eth the pot keeps for processing (Core.reserve): the larger of reserveWei and 1.5 times the queued compose and
    // redeem caller payments. the bids read potRoom, the caller payments pay from the whole pot
    reserve,
    potRoom,
    // the unbooked fee income the Core holds above its pots, before the payee and redeem burn shares
    pendingIncome: pending.income,
    coreEth,
    ethToBuyback,
    ethRedeemBurn,
    balanceAvailable,
    balanceRate,
    balanceUnit,
    payee,
    payeeOn,
    artist,
    pileSize,
    held: held.map(Number),
    settings,
    paused,
    retired,
    chosenComposeOn,
    minCcToChoose,
    controller,
    coin,
    balanceModule,
    balanceToken,
    // the balance side exists once the Core has a module
    balanceOn: balanceModule !== zeroAddress,
    creditSaleOn,
    creditWindow: Number(creditWindow),
    pointRate,
    page: { ready: page[0], ids: page[1].map(Number), format: page[2] },
    // Credit sale proceeds (Core.sellCreditTo): after the artist and operator cuts, min(cost * creditCostToPotBps / 10000,
    // rest) goes to the pot and the remainder to the buyback.
    creditCostToPotBps,
    // Statement price curve (ControllerV1._ask). The asking price is reference * bps / 10000. bps falls in a straight
    // line from `statementStartBps` at age 0 to settings.saleFloorBps at `statementDecayHours` hours, then rests.
    // `statementStartBps` = anchorBps * markupBps / 10000, at most statementStartCapBps; it moves with sales.
    statementStartBps: num(startRes),
    statementDecayHours: num(decayRes),
    statementMarkupBps: num(markupRes),
    statementStartCapBps: num(startCapRes),
    anchorBps: num(anchorRes), // running sale level in bps of the reference (10000 = no premium)
    // Credit price curve (ControllerV1.creditPrice). floor = max(cost, valueOf(score)) * creditFloorBps / 10000, where
    // creditFloorBps is the controller's floorMultBps(): (10000 + creditSpreadBps) of the Core's balanceBidCapBps;
    // start = floor * creditStartBps / 10000. The price falls linearly from start at acquisition to floor at
    // creditWindow seconds, then rests at the floor.
    creditFloorBps: num(floorRes),
    creditStartBps: num(creditStartRes),
    // Id the next compose mints: Statements.supply() + 1 (Core.compose asserts the new id equals supply()).
    nextStatementId: statementSupply === undefined ? undefined : Number(statementSupply) + 1,
  };
}

export type Snapshot = Awaited<ReturnType<typeof readSnapshot>>;

// the score of each credit id, read the way the Core reads it (CreditScore.scoreOf(seedOf, timestampOf))
export async function creditScores(client: Pick<PublicClient, "multicall">, ids: bigint[], blockNumber?: bigint): Promise<bigint[]> {
  if (ids.length === 0) return [];
  const seeds = await client.multicall({
    ...mc,
    blockNumber,
    allowFailure: false,
    contracts: ids.flatMap((id) => [
      { address: CREDITS, abi: seedAbi, functionName: "seedOf", args: [id] },
      { address: CREDITS, abi: seedAbi, functionName: "timestampOf", args: [id] },
    ] as const),
  });
  return client.multicall({
    ...mc,
    blockNumber,
    allowFailure: false,
    contracts: ids.map((_, i) => ({ address: CREDIT_SCORE, abi: scoreAbi, functionName: "scoreOf", args: [seeds[2 * i] as `0x${string}`, seeds[2 * i + 1] as bigint] }) as const),
  });
}
