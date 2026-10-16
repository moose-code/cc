// The keeper's chain access: the read client over the rpc list (logging when a fallback answers), and the state of one
// block for the decisions: the shared snapshot plus the keeper's own reads, all pinned to the snapshot's block.

import { createPublicClient, fallback, http, zeroAddress, type Address, type PublicClient } from "viem";
import { readSnapshot, mc, type Snapshot } from "@cc/engine/snapshot";
import { controllerAbi, coreAbi, escrowAbi, factoryAbi } from "@cc/engine/abis";
import type { Config } from "./config.ts";
import type { State } from "./decide.ts";
import { log } from "./log.ts";

export function readClient(cfg: Config): PublicClient {
  const transport = fallback(
    cfg.rpcUrls.map((u) => http(u, { timeout: 20_000, retryCount: 1 })),
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
  sniperSeconds: bigint;
  factory: Address;
  escrow: Address;
  owner: Address;
}

// the immutables and the owner, read once at start
export async function readFixed(client: PublicClient, core: Address): Promise<Fixed> {
  const c = { address: core, abi: coreAbi } as const;
  const [sniperSeconds, factory, escrow, owner] = await client.multicall({
    ...mc,
    allowFailure: false,
    contracts: [
      { ...c, functionName: "SNIPER_SECONDS" },
      { ...c, functionName: "FACTORY" },
      { ...c, functionName: "ESCROW" },
      { ...c, functionName: "owner" },
    ] as const,
  });
  return { sniperSeconds, factory, escrow, owner };
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
      ] as const,
    }),
  ]);
  const [lastBuybackBlock, escrowBalance, info] = extra;
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
    },
    ethPot: snap.ethPot,
    potWithPending: snap.potWithPending,
    pendingIncome: snap.pendingIncome,
    ethToBuyback: snap.ethToBuyback,
    payeeOn: snap.payeeOn,
    paused: snap.paused,
    retired: snap.retired,
    lastBuybackBlock,
    sniperSeconds: fixed.sniperSeconds,
    launchedAt: BigInt(info.launchedAt),
    escrowBalance,
    pageReady: snap.page.ready,
    balanceModule: snap.balanceModule,
    atFloor: held.filter((_, i) => floors[i]?.status === "success" && floors[i].result === true),
  };
  return { state, snap };
}
