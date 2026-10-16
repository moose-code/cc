// The engine snapshot: one pinned multicall over the views of docs/INTEGRATION.md
// section 2. web/ polls it for every page, keeper/ reads it once per block.

import { zeroAddress, type Address, type PublicClient } from "viem";
import { controllerAbi, coreAbi, moduleAbi, multicallAbi, scoreAbi, seedAbi } from "./abis.ts";
import { CREDIT_SCORE, CREDITS } from "./addresses.ts";

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
    ethRate,
    ethPrice,
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
  ] = await client.multicall({
    ...mc,
    blockNumber,
    allowFailure: false,
    contracts: [
      { ...c, functionName: "ethRate" },
      { ...c, functionName: "ethPrice" },
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
    ] as const,
  });
  // ethPot plus the share of the unbooked fee income that the next Core._book adds (Core._income, _split)
  const pending = pendingIncome(coreEth, ethPot, ethToBuyback, ethRedeemBurn, payeeOn, settings.payeePpm, settings.feeToRedeemBurnBps);
  const potWithPending = ethPot + pending.toPot;
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
  return {
    ethRate,
    ethPrice,
    floorRate,
    ethPot,
    potWithPending,
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
