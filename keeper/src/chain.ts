// The keeper's chain access: the read client over the rpc list (logging when a fallback answers), and the state of one
// block for the decisions: the shared snapshot plus the keeper's own reads, all pinned to the snapshot's block.

import { createPublicClient, fallback, http, zeroAddress, type Address, type PublicClient } from "viem";
import { readSnapshot, mc, type Snapshot } from "@cc/engine/snapshot";
import { controllerAbi, coreAbi, erc20Abi, escrowAbi, factoryAbi, standingBidAbi, treasuryAbi } from "@cc/engine/abis";
import type { Config, SplitConfig } from "./config.ts";
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

// the module's conversionReady() at the block: true or false from a phase 2 treasury, undefined when no module is
// bound or the module does not answer the view (an older module). exported for the test of the fallback
export async function readConversionReady(
  client: Pick<PublicClient, "multicall">,
  balanceModule: Address,
  blockNumber?: bigint,
): Promise<boolean | undefined> {
  if (balanceModule === zeroAddress) return undefined;
  const [res] = await client.multicall({
    ...mc,
    blockNumber,
    allowFailure: true,
    contracts: [{ address: balanceModule, abi: treasuryAbi, functionName: "conversionReady" }] as const,
  });
  return res.status === "success" ? (res.result as boolean) : undefined;
}

// the standing bid reads of the phase 2 treasury at the block, for the refreshBidReference door and the tick log
export interface StandingBidRead {
  // the treasury's redemptionPolicy(), undefined when zero or when the module has no such view
  policy?: Address;
  // the policy's VERSION(), undefined when it answers none (the first policy answers "pro-rata-v1", the standing bid
  // policy "standing-bid-v1")
  version?: string;
  // the policy's refreshDue(), undefined when it does not answer (another policy)
  refreshDue?: boolean;
  ccRedemptionEnabled?: boolean;
  // undefined on a treasury built before the bid budget (older ABI)
  bidBudgetAvailable?: bigint;
}

// the treasury's policy, switch and budget, then the policy's version and refreshDue, each read tolerant: a treasury
// without the budget, a module without a policy view or a policy without VERSION leave that field undefined, and the
// decision skips the door with a reason. nothing is read while no module is bound, and the policy is not read while the
// treasury names none. exported for the test of the fallbacks
export async function readStandingBid(
  client: Pick<PublicClient, "multicall">,
  balanceModule: Address,
  blockNumber?: bigint,
): Promise<StandingBidRead> {
  if (balanceModule === zeroAddress) return {};
  const t = { address: balanceModule, abi: treasuryAbi } as const;
  const [policyRes, enabledRes, budgetRes] = await client.multicall({
    ...mc,
    blockNumber,
    allowFailure: true,
    contracts: [
      { ...t, functionName: "redemptionPolicy" },
      { ...t, functionName: "ccRedemptionEnabled" },
      { ...t, functionName: "bidBudgetAvailable" },
    ] as const,
  });
  const out: StandingBidRead = {
    ccRedemptionEnabled: enabledRes.status === "success" ? (enabledRes.result as boolean) : undefined,
    bidBudgetAvailable: budgetRes.status === "success" ? (budgetRes.result as bigint) : undefined,
  };
  const policy = policyRes.status === "success" ? (policyRes.result as Address) : undefined;
  if (!policy || policy === zeroAddress) return out;
  out.policy = policy;
  const pc = { address: policy, abi: standingBidAbi } as const;
  const [versionRes, dueRes] = await client.multicall({
    ...mc,
    blockNumber,
    allowFailure: true,
    contracts: [
      { ...pc, functionName: "VERSION" },
      { ...pc, functionName: "refreshDue" },
    ] as const,
  });
  out.version = versionRes.status === "success" ? (versionRes.result as string) : undefined;
  out.refreshDue = dueRes.status === "success" ? (dueRes.result as boolean) : undefined;
  return out;
}

// the artist and operator split's holdings at the block, for the distributeSplit door: its ETH balance, and its balance
// of the Core's balance token when the BALANCE leg is on (minBalance set) and a token is bound. read tolerant: a failed
// read leaves the value undefined, which the decision skips with a reason, so a node fault never stalls the other
// doors. exported for the test of the fallback
export async function readSplitBalances(
  client: Pick<PublicClient, "getBalance" | "multicall">,
  split: Pick<SplitConfig, "address" | "minBalance">,
  balanceToken: Address,
  blockNumber?: bigint,
): Promise<{ eth?: bigint; balance?: bigint }> {
  const ethRead = client.getBalance({ address: split.address, blockNumber }).catch(() => undefined);
  const balanceRead =
    split.minBalance !== undefined && balanceToken !== zeroAddress
      ? client
          .multicall({
            ...mc,
            blockNumber,
            allowFailure: true,
            contracts: [{ address: balanceToken, abi: erc20Abi, functionName: "balanceOf", args: [split.address] }] as const,
          })
          .then(([r]) => (r.status === "success" ? (r.result as bigint) : undefined))
          .catch(() => undefined)
      : Promise.resolve(undefined);
  const [eth, balance] = await Promise.all([ethRead, balanceRead]);
  return { eth, balance };
}

export async function readState(client: PublicClient, core: Address, fixed: Fixed, split?: SplitConfig): Promise<Read> {
  const snap = await readSnapshot(client, core);
  if (!snap.pinned || snap.blockNumber === undefined) throw new Error("the node refused a pinned read");
  const blockNumber = snap.blockNumber;
  // the factory reverts NotFound for a coin it has not launched: launchedAt is 0 until the launch is recorded
  const infoRead = client
    .readContract({ address: fixed.factory, abi: factoryAbi, functionName: "deploymentInfo", args: [snap.coin], blockNumber })
    .catch(() => undefined);
  const [block, extra, info] = await Promise.all([
    client.getBlock({ blockNumber }),
    client.multicall({
      ...mc,
      blockNumber,
      allowFailure: false,
      contracts: [
        { address: core, abi: coreAbi, functionName: "lastBuybackBlock" },
        { address: fixed.escrow, abi: escrowAbi, functionName: "balances", args: [core, zeroAddress] },
        { address: core, abi: coreAbi, functionName: "spendState" },
      ] as const,
    }),
    infoRead,
  ]);
  const [lastBuybackBlock, escrowBalance, spendState] = extra;
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
  // the phase 2 treasury's conversionReady(), read tolerant: a module without the view (StatementBalanceModule) leaves
  // it undefined, which the decision treats as ready
  const [conversionReady, splitBalances, bid] = await Promise.all([
    readConversionReady(client, snap.balanceModule, blockNumber),
    split ? readSplitBalances(client, split, snap.balanceToken, blockNumber) : Promise.resolve(undefined),
    readStandingBid(client, snap.balanceModule, blockNumber),
  ]);
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
      buyToArtistBps: st.buyToArtistBps,
    },
    spend: { bucket: spendState[0], budget: spendState[1], spent: spendState[2] },
    ethPot: snap.ethPot,
    potWithPending: snap.potWithPending,
    reserve: snap.reserve,
    potRoom: snap.potRoom,
    pendingIncome: snap.pendingIncome,
    lastBookAt: 0n,
    ethToBuyback: snap.ethToBuyback,
    payeeOn: snap.payeeOn,
    paused: snap.paused,
    retired: snap.retired,
    lastBuybackBlock,
    sniperSeconds: BigInt(st.sniperSeconds),
    launchedAt: BigInt(info?.launchedAt ?? 0),
    escrowBalance,
    pageReady: snap.page.ready,
    balanceModule: snap.balanceModule,
    conversionReady,
    statementRedeemDelaySeconds: snap.statementRedeemDelaySeconds,
    atFloor: held.filter((_, i) => floors[i]?.status === "success" && floors[i].result === true),
    controller: snap.controller,
    valueModeOn: snap.value.on,
    noQuote: snap.noQuote,
    referencePrice: snap.value.referencePrice ?? 0n,
    referenceTime: BigInt(snap.value.referenceTime ?? 0),
    referenceMaxStale: BigInt(snap.value.quote?.referenceMaxStale ?? 0),
    referenceMinSeconds: BigInt(snap.value.quote?.referenceMinSeconds ?? 0),
    referenceRateBpsPerHour: BigInt(snap.value.quote?.referenceRateBpsPerHour ?? 0),
    referenceStepBps: BigInt(snap.value.quote?.referenceStepBps ?? 0),
    spot: snap.value.spot ?? 0n,
    balanceToken: snap.balanceToken,
    splitEth: splitBalances?.eth,
    splitBalance: splitBalances?.balance,
    bidPolicy: bid.policy,
    bidPolicyVersion: bid.version,
    bidRefreshDue: bid.refreshDue,
    ccRedemptionEnabled: bid.ccRedemptionEnabled,
    bidBudgetAvailable: bid.bidBudgetAvailable,
  };
  return { state, snap };
}
