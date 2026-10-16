"use client";

// On-chain reads shared by every page: viem multicalls over the views of
// docs/INTEGRATION.md section 2. Hooks read nothing and return empty data while
// no engine is configured.

import { useEffect, useMemo, useState } from "react";
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { useReadContract, usePublicClient } from "wagmi";
import { BaseError, ContractFunctionRevertedError, ContractFunctionZeroDataError, numberToHex, zeroAddress, type Address } from "viem";
import { atBlock, creditScores, mc, MULTICALL3, pendingIncome, readSnapshot, type Snapshot } from "@cc/engine/snapshot";
import { CREDIT_SCORE } from "@cc/engine/addresses";
import { multicallAbi, scoreAbi, seedAbi } from "@cc/engine/abis";
import { core, credits, engineDeployed, SCORE_PER_100_POINTS, statements } from "./config";
import { controllerAbi, coreAbi, creditsAbi, erc20Abi, statementsAbi } from "./abis";
import { SCOPE, lsGet, lsSet } from "./cache";
import { ETH_ANCHOR_SLOT, ethAnchorWords, replayBalanceFills, replayEthFills } from "./sell";
import { useCreditRow, useCreditTraitsIx, useHeldCredits, useIxMode, useStatementDetailIx, useWalletCreditsIx } from "./indexer";
import type { AcquiredHow } from "./indexer-schema";
import type { BalanceTokenInfo } from "./format";

type Client = NonNullable<ReturnType<typeof usePublicClient>>;

export { MULTICALL3, creditScores, readSnapshot } from "@cc/engine/snapshot";
export type { Snapshot } from "@cc/engine/snapshot";
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
  score?: bigint; // indexer mode only
  mask?: number; // printed plates, bit0 C, bit1 M, bit2 Y, bit3 K (indexer mode only)
  how?: AcquiredHow | null; // how the engine got it (indexer mode only)
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

// The credits the engine holds, oldest first (the compose order). Indexer mode: the list, costs, acquisition times and
// scores come from the indexer (no 200 credit cap), the price is read live (creditPrice falls every second) and `past`
// follows chain time. Chain mode: the first PILE_PAGE credits of Core.pilePage, read with creditInfo, pastWindow and
// creditPrice.
export function usePile() {
  const client = usePublicClient();
  const { data: s } = useSnapshot();
  const mode = useIxMode();
  const now = useNow(15000);
  const held = useHeldCredits();
  const chain = useQuery<PileCredit[]>({
    queryKey: ["pile", s?.pileSize.toString(), s?.creditSaleOn, s?.controller],
    enabled: Boolean(s) && mode === "chain",
    refetchInterval: 15000,
    queryFn: async () => {
      const ids = await client!.readContract({ address: core!, abi: coreAbi, functionName: "pilePage", args: [0n, PILE_PAGE] });
      return readCredits(client!, s!, [...ids]);
    },
  });
  const base = held.data;
  const saleOn = s?.creditSaleOn ?? false;
  const key = base?.map((c) => c.id).join(",");
  const prices = useQuery<Map<number, bigint>>({
    queryKey: ["pile-prices", key, s?.controller],
    enabled: Boolean(s && client && base && saleOn && base.length > 0) && mode === "ix",
    refetchInterval: 15000,
    placeholderData: keepPreviousData,
    queryFn: async () => {
      const res = await client!.multicall({
        ...mc,
        allowFailure: true,
        contracts: base!.map((c) => ({ address: s!.controller, abi: controllerAbi, functionName: "creditPrice", args: [BigInt(c.id)] }) as const),
      });
      return new Map(base!.map((c, i) => [c.id, val(res[i], 0n)] as const));
    },
  });
  const ixData: PileCredit[] = useMemo(() => {
    if (mode !== "ix" || !s || !base || (saleOn && base.length > 0 && !prices.data)) return [];
    return base.map((c) => ({
      ...c,
      inPile: true,
      price: saleOn ? prices.data?.get(c.id) ?? 0n : 0n,
      past: !saleOn || c.acquiredAt + s.creditWindow <= now,
    }));
  }, [mode, s, base, saleOn, prices.data, now]);
  return { data: mode === "ix" ? ixData : chain.data ?? [] };
}

// One credit, in the pile or not (chain mode) or only in the pile (indexer mode). undefined until loaded.
export function useCredit(id: number) {
  const client = usePublicClient();
  const { data: s } = useSnapshot();
  const mode = useIxMode();
  const { data: pile } = usePile();
  const q = useQuery<PileCredit | undefined>({
    queryKey: ["credit", id, s?.controller, s?.creditSaleOn],
    enabled: Boolean(s) && mode === "chain",
    refetchInterval: 15000,
    queryFn: async () => (await readCredits(client!, s!, [BigInt(id)]))[0],
  });
  return { data: mode === "ix" ? pile.find((c) => c.id === id) : q.data };
}

// Current owner of a credit (undefined once burned) and of a statement. Re-read when the snapshot's pile size, held
// statement ids or next statement id change: every engine tx that moves a token changes one of them. Only the
// ownerOf revert of a nonexistent or burned token maps to undefined; other errors reject so react-query retries.
// Indexer mode reads the owner column of the credit or statement row instead.
function useOwnerOf(kind: "credit" | "statement", id: number) {
  const client = usePublicClient();
  const { data: s } = useSnapshot();
  const mode = useIxMode();
  const creditRow = useCreditRow(id, kind === "credit");
  const stmtRow = useStatementDetailIx(id, kind === "statement");
  const chain = useQuery<Address | undefined>({
    queryKey: ["owner-of", kind, id, s?.pileSize.toString(), s?.held.join(","), s?.nextStatementId],
    enabled: Boolean(client) && engineDeployed && Boolean(s) && mode === "chain",
    queryFn: async () => {
      const address = kind === "credit" ? credits : statements;
      try {
        return await client!.readContract({ address, abi: kind === "credit" ? creditsAbi : statementsAbi, functionName: "ownerOf", args: [BigInt(id)] });
      } catch (e) {
        if (e instanceof BaseError && e.walk((x) => x instanceof ContractFunctionRevertedError || x instanceof ContractFunctionZeroDataError)) return undefined;
        throw e;
      }
    },
  });
  const ixOwner = (kind === "credit" ? creditRow.data?.owner : stmtRow.data?.owner) as Address | null | undefined;
  return { data: mode === "ix" ? ixOwner ?? undefined : chain.data };
}
export const useCreditOwner = (id: number) => useOwnerOf("credit", id);
export const useStatementOwner = (id: number) => useOwnerOf("statement", id);

// creditCostToPotBps in force at `block` (the block of a CreditSold event). The value of a past block never changes,
// so it is cached for good in memory and localStorage. undefined when the node cannot serve that block.
export function useCreditCostToPotAt(block: bigint | undefined) {
  const client = usePublicClient();
  const chainMode = useIxMode() === "chain"; // indexer mode: credit.costToPotBps
  return useQuery<number | undefined>({
    queryKey: ["cost-to-pot-at", block?.toString()],
    enabled: Boolean(client && block !== undefined && engineDeployed) && chainMode,
    staleTime: Infinity,
    retry: false,
    queryFn: async () => {
      const key = `${SCOPE}:costToPot:${block}`;
      const hit = lsGet<number>(key);
      if (hit != null) return hit;
      try {
        const v = Number(await client!.readContract({ address: core!, abi: coreAbi, functionName: "creditCostToPotBps", blockNumber: block }));
        lsSet(key, v);
        return v;
      } catch {
        return undefined; // pruned state
      }
    },
  });
}

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


// Eth Core.sellForEth pays for n credits sold in one call at chain time `now`
// (CoreLib.drop and CoreLib.climb replayed in sell.ts). Reads ethPrice,
// floorRate, the pot with the unbooked fee share the first book adds (Core._book,
// _split), the settings and the minute anchor. Every read is pinned to one block (atBlock); `pinned` is false when
// the node refused the pinned reads and the quote came from unpinned ones. `fills` is what each credit pays, id to
// wei, in the order of `ids`; `amount` is their sum.
export interface SellQuote {
  amount: bigint;
  fills: Record<string, bigint>;
  pinned: boolean;
}

export async function sellQuote(client: Client, ids: bigint[], now: number): Promise<SellQuote> {
  const { value, pinned } = await atBlock(client, (blockNumber) => sellQuoteAt(client, ids, now, blockNumber));
  const fills: Record<string, bigint> = {};
  ids.forEach((id, i) => (fills[id.toString()] = value[i]));
  return { amount: value.reduce((t, x) => t + x, 0n), fills, pinned };
}

async function sellQuoteAt(client: Client, ids: bigint[], now: number, blockNumber?: bigint): Promise<bigint[]> {
  const c = { address: core!, abi: coreAbi } as const;
  const word = (i: bigint) => client.getStorageAt({ address: core!, slot: numberToHex(ETH_ANCHOR_SLOT + i, { size: 32 }), blockNumber });
  const [[price, peak, ethPot, toBuyback, redeemBurn, payeeOn, st, held, reserve], startWord, bucketWord, scores] = await Promise.all([
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
        { ...c, functionName: "reserve" },
      ] as const,
    }),
    word(1n),
    word(2n),
    creditScores(client, ids, blockNumber),
  ]);
  const { toPot } = pendingIncome(held, ethPot, toBuyback, redeemBurn, payeeOn, st.payeePpm, st.feeToRedeemBurnBps);
  // the bids read the pot less the reserve (Core.room); a batch that carries the pile across a page raises the reserve
  // by one queued compose, which this quote does not model
  const pot = ethPot + toPot;
  return replayEthFills(scores, {
    price,
    peak,
    pot: pot > reserve ? pot - reserve : 0n,
    ...ethAnchorWords(BigInt(startWord ?? "0x0"), BigInt(bucketWord ?? "0x0"), BigInt(Math.floor(now)), BigInt(st.bucketSeconds)),
    dropPer100PointsBps: BigInt(st.dropPer100PointsBps),
    dropFloorBps: BigInt(st.dropFloorBps),
    ceilBps: BigInt(st.ceilBps),
    rateCap: BigInt(st.rateCap),
    scorePer100Points: SCORE_PER_100_POINTS,
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
// it is cached and not polled. used by the credit swap, where score(inId) must be at or above score(outId).
// Indexer mode reads credit.score.
export function useScores(ids: bigint[]) {
  const client = usePublicClient();
  const mode = useIxMode();
  const key = ids.map(String).join(",");
  const chain = useQuery<Record<string, bigint>>({
    queryKey: ["scores-of", key],
    enabled: engineDeployed && Boolean(client) && ids.length > 0 && mode === "chain",
    staleTime: Infinity,
    queryFn: async () => {
      const scores = await creditScores(client!, ids);
      const m: Record<string, bigint> = {};
      ids.forEach((id, i) => (m[id.toString()] = scores[i]));
      return m;
    },
  });
  const ixq = useCreditTraitsIx(mode === "ix" ? ids.map(Number) : []);
  const ixScores = useMemo(() => (ixq.data ? Object.fromEntries(Object.entries(ixq.data).map(([id, r]) => [id, r.score])) : undefined), [ixq.data]);
  return { data: mode === "ix" ? ixScores : chain.data };
}

// Credit price floor input: controller valueOf(score) per id, id to wei. Credit floor price =
// max(cost, value) * snap.creditFloorBps / 10000 (the controller's floorMultBps) and start = floor * snap.creditStartBps / 10000 (see Snapshot).
// Scores are cached (useScores). valueOf includes a pool value that moves, so the query is keyed on the snapshot's
// last update and refreshes with the snapshot's 15 s cadence. A failed read leaves the id out of the map.
export function useCreditValues(ids: bigint[]) {
  const client = usePublicClient();
  const { data: s, dataUpdatedAt } = useSnapshot();
  const { data: scores } = useScores(ids);
  const key = ids.map(String).join(",");
  return useQuery<Record<string, bigint>>({
    queryKey: ["credit-values", key, s?.controller, dataUpdatedAt],
    enabled: Boolean(client && s && scores),
    queryFn: async () => {
      const vals = await client!.multicall({
        ...mc,
        allowFailure: true,
        contracts: ids.map((id) => ({ address: s!.controller, abi: controllerAbi, functionName: "valueOf", args: [scores![id.toString()]] }) as const),
      });
      const m: Record<string, bigint> = {};
      ids.forEach((id, i) => {
        if (vals[i].status === "success") m[id.toString()] = vals[i].result as bigint;
      });
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
  const mode = useIxMode();
  const key = ids.map(String).join(",");
  const chain = useQuery<Record<string, CreditTraits>>({
    queryKey: ["traits-of", key],
    enabled: engineDeployed && Boolean(client) && ids.length > 0 && mode === "chain",
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
  const ixq = useCreditTraitsIx(mode === "ix" ? ids.map(Number) : []);
  const ixTraits = useMemo(
    () => (ixq.data ? (Object.fromEntries(Object.entries(ixq.data).map(([id, r]) => [id, { mask: r.mask, active: r.active, occupied: r.occupied, eights: r.eights, band: r.band }])) as Record<string, CreditTraits>) : undefined),
    [ixq.data]
  );
  return { data: mode === "ix" ? ixTraits : chain.data };
}

// Credits owned by a wallet with their scores, lowest id first. Indexer mode: the credit table's owner column. Chain
// mode: Credits.tokensOf and the scores read from the chain.
export function useWalletCredits(address?: Address) {
  const client = usePublicClient();
  const mode = useIxMode();
  const ixq = useWalletCreditsIx(address);
  const chain = useQuery<{ id: number; score: bigint; mask?: number }[]>({
    queryKey: ["wallet-credits-live", address],
    enabled: Boolean(address && client && engineDeployed) && mode === "chain",
    queryFn: async () => {
      const ids = await client!.readContract({ address: credits, abi: creditsAbi, functionName: "tokensOf", args: [address!] });
      const scores = await creditScores(client!, [...ids]);
      return ids.map((id, i) => ({ id: Number(id), score: scores[i] }));
    },
  });
  const data = mode === "ix" ? ixq.data : chain.data;
  const scores = useMemo(() => Object.fromEntries((data ?? []).map((c) => [c.id.toString(), c.score])) as Record<string, bigint>, [data]);
  return { data: data ?? [], scores, ready: data !== undefined };
}

// The balance token and its decimals, undefined while the Core has no module.
export function useBalanceToken(): BalanceTokenInfo | undefined {
  const { data: s } = useSnapshot();
  const token = s?.balanceToken && s.balanceToken !== zeroAddress ? s.balanceToken : undefined;
  const { data: decimals } = useReadContract({ address: token, abi: erc20Abi, functionName: "decimals", query: { enabled: Boolean(token), staleTime: Infinity } });
  return token && decimals != null ? { address: token, decimals } : undefined;
}

// sellQuote for the selected credit ids in sell order, refreshed with the chain clock. The previous minute's quote
// stays on screen while the next one loads, for the same ids only.
export function useSellQuote(ids: bigint[], now: number) {
  const client = usePublicClient();
  const minute = Math.floor(now / 60);
  const key = ids.map(String).join(",");
  return useQuery<SellQuote | undefined>({
    queryKey: ["sell-quote", key, minute],
    enabled: engineDeployed && Boolean(client) && ids.length > 0,
    refetchInterval: 15000,
    placeholderData: (prev, prevQuery) => (prevQuery?.queryKey[1] === key ? prev : undefined),
    queryFn: () => sellQuote(client!, ids, now),
  });
}

// the balance token total sellForBalance pays for `scores` (in order), replaying the per-credit drop from the snapshot
// rate and settings the way sellQuote replays the eth bid. the sell sets minOut to a share of this
export function balanceQuote(snap: Snapshot, scores: bigint[]): bigint {
  return balanceFills(snap, scores).reduce((t, x) => t + x, 0n);
}

// what each of `scores` (in sell order) pays in the balance token in one sellForBalance call; balanceQuote is their sum
export function balanceFills(snap: Snapshot, scores: bigint[]): bigint[] {
  if (scores.length === 0 || snap.balanceUnit === undefined) return [];
  return replayBalanceFills(scores, {
    rate: snap.balanceRate,
    unit: snap.balanceUnit,
    scorePer100Points: SCORE_PER_100_POINTS,
    dropPer100PointsBps: BigInt(snap.settings.dropPer100PointsBps),
    dropFloorBps: BigInt(snap.settings.dropFloorBps),
    floorBps: 10000n - BigInt(snap.settings.balanceBidMarginBps),
  });
}

// ---- helpers --------------------------------------------------------------------

// Points the eth pot buys at `rate` (wei per 100 points): pot * 100 / rate. 0 at a zero rate.
export function potPoints(pot: bigint, rate: bigint): bigint {
  return rate > 0n ? (pot * 100n) / rate : 0n;
}

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
