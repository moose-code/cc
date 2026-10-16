// The keeper's chain access: the read client over the rpc list (logging when a fallback answers), and the state of one
// block for the decisions: the shared snapshot plus the keeper's own reads, all pinned to the snapshot's block.

import { createPublicClient, fallback, http, zeroAddress, type Address, type PublicClient } from "viem";
import { readSnapshot, mc, type Snapshot } from "@cc/engine/snapshot";
import { controllerAbi, coreAbi, escrowAbi, factoryAbi } from "@cc/engine/abis";
import type { Config } from "./config.ts";
import type { State } from "./decide.ts";
import { log } from "./log.ts";

// RPC_TIMEOUT_MS: per request read timeout, default 20 s; a local fork with a cold upstream needs more
function rpcTimeoutMs(): number {
  const v = Number(process.env.RPC_TIMEOUT_MS ?? 20_000);
  return Number.isFinite(v) && v > 0 ? v : 20_000;
}

export function readClient(cfg: Config): PublicClient {
  const transport = fallback(
    cfg.rpcUrls.map((u) => http(u, { timeout: rpcTimeoutMs(), retryCount: 1 })),
    { retryCount: 1 },
  );
  // cacheTime 0: every tick reads the head afresh. viem caches the block number for its polling interval by default,
  // and a tick right after a receipt would decide on the block before it and repeat the call it just made
  const client = createPublicClient({ transport, batch: { multicall: false }, cacheTime: 0 });
  const primary = cfg.rpcUrls[0];
  let lastNote = 0;
  (client.transport as any).onResponse?.(({ transport, status, method }: any) => {
    const url: string | undefined = transport?.value?.url ?? transport?.config?.url;
    if (status === "success" && url && url !== primary && Date.now() - lastNote > 60_000) {
      lastNote = Date.now();
      log("warn", "rpc fallback answered", { host: new URL(url).host, method });
    }
  });
  return client as PublicClient;
}

export interface Fixed {
  factory: Address;
  escrow: Address;
  owner: Address;
}

// the immutables and the owner, read once at start
export async function readFixed(client: PublicClient, core: Address): Promise<Fixed> {
  const c = { address: core, abi: coreAbi } as const;
  const [factory, escrow, owner] = await client.multicall({
    ...mc,
    allowFailure: false,
    contracts: [
      { ...c, functionName: "FACTORY" },
      { ...c, functionName: "ESCROW" },
      { ...c, functionName: "owner" },
    ] as const,
  });
  return { factory, escrow, owner };
}

export interface Read {
  state: State;
  snap: Snapshot;
}

export async function readState(client: PublicClient, core: Address, fixed: Fixed): Promise<Read> {
  const snap = await readSnapshot(client, core);
  if (!snap.pinned || snap.blockNumber === undefined) throw new Error("the node refused a pinned read");
  const blockNumber = snap.blockNumber;
  const [block, extra] = await Promise.all([
    client.getBlock({ blockNumber }),
    client.multicall({
      ...mc,
      blockNumber,
      allowFailure: false,
      contracts: [
        { address: core, abi: coreAbi, functionName: "lastBuybackBlock" },
        { address: fixed.escrow, abi: escrowAbi, functionName: "balances", args: [core, zeroAddress] },
        { address: fixed.factory, abi: factoryAbi, functionName: "deploymentInfo", args: [snap.coin] },
        { address: core, abi: coreAbi, functionName: "spendState" },
      ] as const,
    }),
  ]);
  const [lastBuybackBlock, escrowBalance, info, spendState] = extra;
  // controller.atFloor per held statement, read only when a redemption could be decided
  const held = snap.held.map(BigInt);
  const floors = held.length
    ? await client.multicall({
        ...mc,
        blockNumber,
        allowFailure: true,
        contracts: held.map((sid) => ({ address: snap.controller, abi: controllerAbi, functionName: "atFloor", args: [sid] }) as const),
      })
    : [];
  const st = snap.settings;
  const state: State = {
    core,
    blockNumber,
    timestamp: block.timestamp,
    baseFee: block.baseFeePerGas ?? 0n,
    settings: {
      buybackSlice: st.buybackSlice,
      buybackDelay: st.buybackDelay,
      keeperFee: st.keeperFee,
      keeperMaxBaseFee: BigInt(st.keeperMaxBaseFee),
      callerFee: st.callerFee,
      callerMaxBaseFee: BigInt(st.callerMaxBaseFee),
      redeemOn: st.redeemOn,
      spendCapBps: st.spendCapBps,
      bucketSeconds: st.bucketSeconds,
    },
    spend: { bucket: spendState[0], budget: spendState[1], spent: spendState[2] },
    ethPot: snap.ethPot,
    potWithPending: snap.potWithPending,
    pendingIncome: snap.pendingIncome,
    ethToBuyback: snap.ethToBuyback,
    payeeOn: snap.payeeOn,
    paused: snap.paused,
    retired: snap.retired,
    lastBuybackBlock,
    sniperSeconds: BigInt(st.sniperSeconds),
    launchedAt: BigInt(info.launchedAt),
    escrowBalance,
    pageReady: snap.page.ready,
    balanceModule: snap.balanceModule,
    atFloor: held.filter((_, i) => floors[i]?.status === "success" && floors[i].result === true),
  };
  return { state, snap };
}
