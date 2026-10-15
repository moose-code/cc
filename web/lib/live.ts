"use client";

// On-chain reads shared by every page: viem multicalls over the views of
// docs/INTEGRATION.md section 2. Hooks read nothing and return empty data while
// no engine is configured.

import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { numberToHex, parseAbi, zeroAddress, type Address } from "viem";
import { core, credits, engineDeployed, statements } from "./config";
import { controllerAbi, coreAbi, creditsAbi, statementsAbi } from "./abis";
import { replayEth, replayBalance } from "./sell";

type Client = NonNullable<ReturnType<typeof usePublicClient>>;

export const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;
const mc = { multicallAddress: MULTICALL3, batchSize: 16_384 } as const;
const PILE_PAGE = 200n; // ponytail: first 200 pile credits only, page with pilePage(startAfter) if the pile grows past it

// Chain time: the latest block's timestamp, run forward by the wall seconds
// since that block was first seen. Every countdown and "ago" label reads this,
// so a chain whose clock is ahead of the browser's (local anvil after time
// warps) shows the times the contracts use. Wall clock until the first block is read.
let blockSeen: { n: bigint; ts: number; at: number } | undefined;

// The one head poll of the app: the latest block, read every 12 s. The scan
// keys off it. react-query skips the interval while the tab is hidden, and
// staleTime keeps focus refetches inside the 12 s window from sending.
export function useHead() {
  const client = usePublicClient();
  return useQuery({
    queryKey: ["head"],
    enabled: Boolean(client),
    refetchInterval: 12000,
    staleTime: 12000,
    queryFn: async () => {
      const b = await client!.getBlock();
      if (blockSeen?.n !== b.number) blockSeen = { n: b.number, ts: Number(b.timestamp), at: Date.now() };
      return blockSeen;
    },
  });
}

export function useNow(ms = 1000): number {
  const { data: blk } = useHead();
  const at = () => (blk ? blk.ts + (Date.now() - blk.at) / 1000 : Date.now() / 1000);
  const [now, setNow] = useState(() => Math.floor(at()));
  useEffect(() => {
    setNow(Math.floor(at()));
    const t = setInterval(() => setNow(Math.floor(at())), ms);
    return () => clearInterval(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ms, blk]);
  return now;
}

// ---- engine snapshot ------------------------------------------------------------

// Runs `read` with the latest block number so every RPC of one quote sees the same state. A node that refuses the
// pinned read (pruned or not yet synced at that block) gets one unpinned retry, reported as pinned: false.
async function atBlock<T>(client: Client, read: (blockNumber?: bigint) => Promise<T>): Promise<{ value: T; pinned: boolean }> {
  try {
    return { value: await read(await client.getBlockNumber()), pinned: true };
  } catch {
    return { value: await read(), pinned: false };
  }
}

export async function readSnapshot(client: Client, coreAddr: Address) {
  const { value, pinned } = await atBlock(client, (blockNumber) => snapshotAt(client, coreAddr, blockNumber));
  return { ...value, pinned };
}

async function snapshotAt(client: Client, coreAddr: Address, blockNumber?: bigint) {
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
    creditCostToPotBps,
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
      { ...c, functionName: "creditCostToPotBps" },
    ] as const,
  });
  // ethPot plus the share of the unbooked fee income that the next Core._book adds (Core._income, _split)
  const income = coreEth > ethPot + ethToBuyback + ethRedeemBurn ? coreEth - (ethPot + ethToBuyback + ethRedeemBurn) : 0n;
  const toPayee = payeeOn ? (income * BigInt(settings.payeePpm)) / 1_000_000n : 0n;
  const toRedeemBurn = ((income - toPayee) * BigInt(settings.feeToRedeemBurnBps)) / 10000n;
  const potWithPending = ethPot + income - toPayee - toRedeemBurn;
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
  const [creditSaleOn, creditWindow, pointRate, page, markupBps, startCapBps, decayHours, anchorBps, startBps, creditFloorBps, creditStartBps, statementSupply] = await client.multicall({
    ...mc,
    blockNumber,
    allowFailure: false,
    contracts: [
      { ...k, functionName: "creditSaleOn" },
      { ...k, functionName: "creditWindow" },
      { ...k, functionName: "pointRate" },
      { ...k, functionName: "nextPage" },
      { ...k, functionName: "markupBps" },
      { ...k, functionName: "startCapBps" },
      { ...k, functionName: "decayHours" },
      { ...k, functionName: "anchorBps" },
      { ...k, functionName: "startBps" },
      { ...k, functionName: "creditFloorBps" },
      { ...k, functionName: "creditStartBps" },
      { address: statements, abi: statementsAbi, functionName: "supply" },
    ] as const,
  });
  return {
    ethRate,
    ethPrice,
    floorRate,
    ethPot,
    potWithPending,
    ethToBuyback,
    ethRedeemBurn,
    balanceAvailable,
    balanceRate,
    balanceUnit,
    payee,
    payeeOn,
    artist,
    // Credit sale proceeds (Core.sellCreditTo): after the artist and operator cuts, min(cost * creditCostToPotBps / 10000,
    // rest) goes to the pot and the remainder to the buyback.
    creditCostToPotBps,
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
    // Statement price curve (ControllerV1._ask). The asking price is reference * bps / 10000. bps falls in a straight
    // line from `statementStartBps` at age 0 to settings.saleFloorBps at `statementDecayHours` hours, then rests.
    // `statementStartBps` = anchorBps * markupBps / 10000, at most statementStartCapBps; it moves with sales.
    statementStartBps: Number(startBps),
    statementDecayHours: decayHours,
    statementMarkupBps: markupBps,
    statementStartCapBps: startCapBps,
    anchorBps, // running sale level in bps of the reference (10000 = no premium)
    // Credit price curve (ControllerV1.creditPrice). floor = max(cost, valueOf(score)) * creditFloorBps / 10000;
    // start = floor * creditStartBps / 10000. The price falls linearly from start at acquisition to floor at
    // creditWindow seconds, then rests at the floor.
    creditFloorBps,
    creditStartBps,
    // Id the next compose mints: Statements.supply() + 1 (Core.compose asserts the new id equals supply()).
    nextStatementId: Number(statementSupply) + 1,
  };
}

export type Snapshot = Awaited<ReturnType<typeof readSnapshot>>;

// undefined until loaded.
export function useSnapshot() {
  const client = usePublicClient();
  return useQuery<Snapshot | undefined>({
    queryKey: ["snapshot", core],
    enabled: engineDeployed && Boolean(client),
    refetchInterval: 15000,
    queryFn: () => readSnapshot(client!, core!),
  });
}

// ---- credits --------------------------------------------------------------------

export interface PileCredit {
  id: number;
  inPile: boolean;
  cost: bigint; // wei the engine paid
  acquiredAt: number; // unix seconds
  price: bigint; // sale price now, 0 while the sale is off; what buyCredit takes
  past: boolean; // past its sale window: compose takes only these
}

const val = <T,>(r: { status: string; result?: unknown }, d: T): T => (r.status === "success" ? (r.result as T) : d);

async function readCredits(client: Client, s: Snapshot, ids: bigint[]): Promise<PileCredit[]> {
  if (ids.length === 0) return [];
  const info = await client.multicall({
    ...mc,
    allowFailure: false,
    contracts: ids.map((id) => ({ address: core!, abi: coreAbi, functionName: "creditInfo", args: [id] }) as const),
  });
  const k = { address: s.controller, abi: controllerAbi } as const;
  const per = s.creditSaleOn ? 2 : 1;
  const res = await client.multicall({
    ...mc,
    allowFailure: true,
    contracts: ids.flatMap((id, i) => [
      { ...k, functionName: "pastWindow", args: [info[i][2]] } as const,
      ...(s.creditSaleOn ? ([{ ...k, functionName: "creditPrice", args: [id] }] as const) : []),
    ]),
  });
  return ids.map((id, i) => ({
    id: Number(id),
    inPile: info[i][0],
    cost: info[i][1],
    acquiredAt: Number(info[i][2]),
    past: val(res[i * per], true),
    price: s.creditSaleOn ? val(res[i * per + 1], 0n) : 0n,
  }));
}

export function usePile() {
  const client = usePublicClient();
  const { data: s } = useSnapshot();
  const q = useQuery<PileCredit[]>({
    queryKey: ["pile", s?.pileSize.toString(), s?.creditSaleOn, s?.controller],
    enabled: Boolean(s),
    refetchInterval: 15000,
    queryFn: async () => {
      const ids = await client!.readContract({ address: core!, abi: coreAbi, functionName: "pilePage", args: [0n, PILE_PAGE] });
      return readCredits(client!, s!, [...ids]);
    },
  });
  return { ...q, data: q.data ?? [] };
}

// One credit, in the pile or not. undefined until loaded.
export function useCredit(id: number) {
  const client = usePublicClient();
  const { data: s } = useSnapshot();
  return useQuery<PileCredit | undefined>({
    queryKey: ["credit", id, s?.controller, s?.creditSaleOn],
    enabled: Boolean(s),
    refetchInterval: 15000,
    queryFn: async () => (await readCredits(client!, s!, [BigInt(id)]))[0],
  });
}

// Current owner of a credit (undefined once burned) and of a statement. Read once per id per snapshot
// change; ownership moves with the engine's own txs, which change the snapshot (pileSize, held, nextStatementId).
function useOwnerOf(kind: "credit" | "statement", id: number) {
  const client = usePublicClient();
  const { data: s } = useSnapshot();
  return useQuery<Address | undefined>({
    queryKey: ["owner-of", kind, id, s?.pileSize.toString(), s?.nextStatementId],
    enabled: Boolean(client) && engineDeployed && Boolean(s),
    queryFn: async () => {
      const address = kind === "credit" ? credits : statements;
      return client!
        .readContract({ address, abi: kind === "credit" ? creditsAbi : statementsAbi, functionName: "ownerOf", args: [BigInt(id)] })
        .catch(() => undefined);
    },
  });
}
export const useCreditOwner = (id: number) => useOwnerOf("credit", id);
export const useStatementOwner = (id: number) => useOwnerOf("statement", id);

// ---- statements -----------------------------------------------------------------

export interface HeldStatement {
  sid: number;
  cost: bigint;
  composedAt: number;
  age: number; // seconds, paused time excluded
  rating: bigint;
  composer: Address;
  price: bigint; // asking price now; what buy takes
  reference: bigint;
  atFloor: boolean;
  value: bigint; // controller valueOf(rating); read only once the balance side exists
}

// The statements the Core holds.
export function useStatements() {
  const client = usePublicClient();
  const { data: s } = useSnapshot();
  const q = useQuery<HeldStatement[]>({
    queryKey: ["statements", s?.held.join(","), s?.controller, s?.balanceOn],
    enabled: Boolean(s),
    refetchInterval: 15000,
    queryFn: async () => {
      const c = { address: core!, abi: coreAbi } as const;
      const k = { address: s!.controller, abi: controllerAbi } as const;
      const res = await client!.multicall({
        ...mc,
        allowFailure: true,
        contracts: s!.held.flatMap((sid) => {
          const a = [BigInt(sid)] as const;
          return [
            { ...c, functionName: "statementInfo", args: a },
            { ...c, functionName: "statementAge", args: a },
            { ...c, functionName: "ratingOf", args: a },
            { ...c, functionName: "composerOf", args: a },
            { ...k, functionName: "priceOf", args: a },
            { ...k, functionName: "referenceOf", args: a },
            { ...k, functionName: "atFloor", args: a },
          ] as const;
        }),
      });
      const rating = (i: number) => val<bigint>(res[i * 7 + 2], 0n);
      const values = s!.balanceOn
        ? await client!.multicall({
            ...mc,
            allowFailure: true,
            contracts: s!.held.map((_, i) => ({ ...k, functionName: "valueOf", args: [rating(i)] }) as const),
          })
        : [];
      return s!.held.map((sid, i) => {
        const r = (j: number) => res[i * 7 + j];
        const info = val<readonly [boolean, bigint, bigint]>(r(0), [false, 0n, 0n]);
        return {
          sid,
          cost: info[1],
          composedAt: Number(info[2]),
          age: Number(val(r(1), 0n)),
          rating: rating(i),
          composer: val<Address>(r(3), zeroAddress),
          price: val(r(4), 0n),
          reference: val(r(5), 0n),
          atFloor: val(r(6), false),
          value: values[i] ? val(values[i], 0n) : 0n,
        };
      });
    },
  });
  return { ...q, data: q.data ?? [] };
}

// ---- sell quotes ----------------------------------------------------------------

// State.anchor starts at slot 27 (test/CoreLayout.t.sol, src/lib/CoreLib.sol):
// lastFillRate, minuteStartRate, minuteBucket (uint64) + peakTime, peakRate.
const ANCHOR_SLOT = 27n;
const CREDIT_SCORE = "0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7" as const;
const scoreAbi = parseAbi([
  "function scoreOf(bytes21 seed, uint64 paidAt) view returns (uint256)",
  "function traitsOf(bytes21 seed, uint64 paidAt) view returns (uint256 mask, uint256 active, uint256 occupied, uint256 eights, uint256 band)",
]);
const multicallAbi = parseAbi(["function getEthBalance(address a) view returns (uint256)"]);
const moduleAbi = parseAbi(["function unitPerPoint() view returns (uint256)", "function available() view returns (uint256)"]);
const seedAbi = parseAbi(["function seedOf(uint256 id) view returns (bytes21)", "function timestampOf(uint256 id) view returns (uint64)"]);

// Eth Core.sellForEth pays for n credits sold in one call at chain time `now`
// (CoreLib.drop and CoreLib.climb replayed in sell.ts). Reads ethPrice,
// floorRate, the pot with the unbooked fee share the first book adds (Core._book,
// _split), the settings and the minute anchor. Every read is pinned to one block (atBlock); `pinned` is false when
// the node refused the pinned reads and the quote came from unpinned ones.
export interface SellQuote {
  amount: bigint;
  pinned: boolean;
}

export async function sellQuote(client: Client, ids: bigint[], now: number): Promise<SellQuote> {
  const { value, pinned } = await atBlock(client, (blockNumber) => sellQuoteAt(client, ids, now, blockNumber));
  return { amount: value, pinned };
}

async function sellQuoteAt(client: Client, ids: bigint[], now: number, blockNumber?: bigint): Promise<bigint> {
  const c = { address: core!, abi: coreAbi } as const;
  const word = (i: bigint) => client.getStorageAt({ address: core!, slot: numberToHex(ANCHOR_SLOT + i, { size: 32 }), blockNumber });
  const [[price, peak, ethPot, toBuyback, redeemBurn, payeeOn, st, held], startWord, bucketWord, scores] = await Promise.all([
    client.multicall({
      ...mc,
      blockNumber,
      allowFailure: false,
      contracts: [
        { ...c, functionName: "ethPrice" },
        { ...c, functionName: "floorRate" },
        { ...c, functionName: "ethPot" },
        { ...c, functionName: "ethToBuyback" },
        { ...c, functionName: "ethRedeemBurn" },
        { ...c, functionName: "payeeOn" },
        { ...c, functionName: "settings" },
        { address: MULTICALL3, abi: multicallAbi, functionName: "getEthBalance", args: [core!] },
      ] as const,
    }),
    word(1n),
    word(2n),
    creditScores(client, ids, blockNumber),
  ]);
  const booked = ethPot + toBuyback + redeemBurn;
  const income = held > booked ? held - booked : 0n;
  const toPayee = payeeOn ? (income * BigInt(st.payeePpm)) / 1_000_000n : 0n;
  const toRedeemBurn = ((income - toPayee) * BigInt(st.feeToRedeemBurnBps)) / 10000n;
  return replayEth(scores, {
    price,
    peak,
    pot: ethPot + income - toPayee - toRedeemBurn,
    start: BigInt(startWord ?? "0x0"),
    bucket: BigInt(bucketWord ?? "0x0") & ((1n << 64n) - 1n),
    nowBucket: BigInt(Math.floor(now / 60)),
    dropPerCreditBps: BigInt(st.dropPerCreditBps),
    dropFloorBps: BigInt(st.dropFloorBps),
    ceilBps: BigInt(st.ceilBps),
    rateCap: BigInt(st.rateCap),
    refScore: BigInt(st.refScore),
  });
}

// the score of each credit id, read the way the Core reads it (CreditScore.scoreOf(seedOf, timestampOf))
async function creditScores(client: Client, ids: bigint[], blockNumber?: bigint): Promise<bigint[]> {
  if (ids.length === 0) return [];
  const seeds = await client.multicall({
    ...mc,
    blockNumber,
    allowFailure: false,
    contracts: ids.flatMap((id) => [
      { address: credits, abi: seedAbi, functionName: "seedOf", args: [id] },
      { address: credits, abi: seedAbi, functionName: "timestampOf", args: [id] },
    ] as const),
  });
  return client.multicall({
    ...mc,
    blockNumber,
    allowFailure: false,
    contracts: ids.map((_, i) => ({ address: CREDIT_SCORE, abi: scoreAbi, functionName: "scoreOf", args: [seeds[2 * i] as `0x${string}`, seeds[2 * i + 1] as bigint] }) as const),
  });
}

// the per-credit eth bid now, one multicall of Core.bidOf over the ids
export async function bidsOf(client: Client, ids: bigint[]): Promise<bigint[]> {
  if (ids.length === 0) return [];
  return client.multicall({
    ...mc,
    allowFailure: false,
    contracts: ids.map((id) => ({ address: core!, abi: coreAbi, functionName: "bidOf", args: [id] }) as const),
  });
}

// the per-credit eth bid for `ids`, id to wei, refreshed with the chain clock's minute
export function useBidsOf(ids: bigint[], now: number) {
  const client = usePublicClient();
  const minute = Math.floor(now / 60);
  const key = ids.map(String).join(",");
  return useQuery<Record<string, bigint>>({
    queryKey: ["bids-of", key, minute],
    enabled: engineDeployed && Boolean(client) && ids.length > 0,
    refetchInterval: 15000,
    queryFn: async () => {
      const bids = await bidsOf(client!, ids);
      const m: Record<string, bigint> = {};
      ids.forEach((id, i) => (m[id.toString()] = bids[i]));
      return m;
    },
  });
}

// the credit score (CreditScore.scoreOf(seedOf, timestampOf)) for each id, id to score. the score does not change, so
// it is cached and not polled. used by the credit swap, where score(inId) must be at or above score(outId)
export function useScores(ids: bigint[]) {
  const client = usePublicClient();
  const key = ids.map(String).join(",");
  return useQuery<Record<string, bigint>>({
    queryKey: ["scores-of", key],
    enabled: engineDeployed && Boolean(client) && ids.length > 0,
    staleTime: Infinity,
    queryFn: async () => {
      const scores = await creditScores(client!, ids);
      const m: Record<string, bigint> = {};
      ids.forEach((id, i) => (m[id.toString()] = scores[i]));
      return m;
    },
  });
}

// Credit price floor input: controller valueOf(score) per id, id to wei. Credit floor price =
// max(cost, value) * snap.creditFloorBps / 10000 and start = floor * snap.creditStartBps / 10000 (see Snapshot).
// Scores are cached (useScores); values refresh when the snapshot's floor rate changes. Not polled.
export function useCreditValues(ids: bigint[]) {
  const client = usePublicClient();
  const { data: s } = useSnapshot();
  const { data: scores } = useScores(ids);
  const key = ids.map(String).join(",");
  return useQuery<Record<string, bigint>>({
    queryKey: ["credit-values", key, s?.controller, s?.floorRate.toString(), s?.balanceUnit?.toString()],
    enabled: Boolean(client && s && scores),
    queryFn: async () => {
      const vals = await client!.multicall({
        ...mc,
        allowFailure: true,
        contracts: ids.map((id) => ({ address: s!.controller, abi: controllerAbi, functionName: "valueOf", args: [scores![id.toString()]] }) as const),
      });
      const m: Record<string, bigint> = {};
      ids.forEach((id, i) => (m[id.toString()] = val(vals[i], 0n)));
      return m;
    },
  });
}

export interface CreditTraits {
  mask: number; // active plate bitmask, 1 to 15 (CreditScore.traitsOf). Bit 0 (1) = C, bit 1 (2) = M, bit 2 (4) = Y, bit 3 (8) = K; a set bit is a printed plate (matches the tokenURI "Colors" trait).
  active: number; // inked bits across the active plates
  occupied: number; // distinct inked raster cells after plate misregistration
  eights: number; // ASCII '8' count in the seed
  band: number; // registration band: 0 Registered, 1 Nudge, 2 Slip, 3 Skew, 4 Drift, 5 Loose
}

// CreditScore.traitsOf(seedOf, timestampOf) per id. Fixed once minted, so cached and not polled.
export function useCreditTraits(ids: bigint[]) {
  const client = usePublicClient();
  const key = ids.map(String).join(",");
  return useQuery<Record<string, CreditTraits>>({
    queryKey: ["traits-of", key],
    enabled: engineDeployed && Boolean(client) && ids.length > 0,
    staleTime: Infinity,
    queryFn: async () => {
      const seeds = await client!.multicall({
        ...mc,
        allowFailure: false,
        contracts: ids.flatMap((id) => [
          { address: credits, abi: seedAbi, functionName: "seedOf", args: [id] },
          { address: credits, abi: seedAbi, functionName: "timestampOf", args: [id] },
        ] as const),
      });
      const t = await client!.multicall({
        ...mc,
        allowFailure: false,
        contracts: ids.map((_, i) => ({ address: CREDIT_SCORE, abi: scoreAbi, functionName: "traitsOf", args: [seeds[2 * i] as `0x${string}`, seeds[2 * i + 1] as bigint] }) as const),
      });
      const m: Record<string, CreditTraits> = {};
      ids.forEach((id, i) => {
        const r = t[i];
        m[id.toString()] = { mask: Number(r[0]), active: Number(r[1]), occupied: Number(r[2]), eights: Number(r[3]), band: Number(r[4]) };
      });
      return m;
    },
  });
}

// sellQuote for the selected credit ids, refreshed with the chain clock's minute.
export function useSellQuote(ids: bigint[], now: number) {
  const client = usePublicClient();
  const minute = Math.floor(now / 60);
  const key = ids.map(String).join(",");
  return useQuery<SellQuote | undefined>({
    queryKey: ["sell-quote", key, minute],
    enabled: engineDeployed && Boolean(client) && ids.length > 0,
    refetchInterval: 15000,
    queryFn: () => sellQuote(client!, ids, now),
  });
}

// the balance token total sellForBalance pays for `scores` (in order), replaying the per-credit drop from the snapshot
// rate and settings the way sellQuote replays the eth bid. the sell sets minOut to a share of this
export function balanceQuote(snap: Snapshot, scores: bigint[]): bigint {
  if (scores.length === 0 || snap.balanceUnit === undefined) return 0n;
  return replayBalance(scores, {
    rate: snap.balanceRate,
    unit: snap.balanceUnit,
    refScore: BigInt(snap.settings.refScore),
    dropPerCreditBps: BigInt(snap.settings.dropPerCreditBps),
    dropFloorBps: BigInt(snap.settings.dropFloorBps),
    floorBps: 10000n - BigInt(snap.settings.balanceBidMarginBps),
  });
}

// ---- helpers --------------------------------------------------------------------

// "3h 12m", "4m 05s", "12s"
export function countdown(s: number): string {
  s = Math.max(0, Math.floor(s));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (h) return `${h}h ${m}m`;
  if (m) return `${m}m ${String(s % 60).padStart(2, "0")}s`;
  return `${s}s`;
}

// Short message from a viem error: shortMessage, else the first line.
export function errMsg(e: any): string {
  return e?.shortMessage || String(e?.message || "transaction failed").split("\n")[0];
}
