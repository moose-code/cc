"use client";

// On-chain reads shared by every page: viem multicalls over the views of
// docs/INTEGRATION.md section 2. Hooks read nothing and return empty data while
// no engine is configured.

import { useEffect, useMemo, useState } from "react";
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { useReadContract, usePublicClient } from "wagmi";
import { BaseError, ContractFunctionRevertedError, ContractFunctionZeroDataError, numberToHex, zeroAddress, type Address } from "viem";
import { atBlock, mc as engineMc, MULTICALL3, pendingIncome, readSnapshot, type Snapshot } from "@cc/engine/snapshot";
import { CREDIT_SCORE } from "@cc/engine/addresses";
import { multicallAbi, scoreAbi, seedAbi } from "@cc/engine/abis";
import { core, credits, engineDeployed, SCORE_PER_100_POINTS, statements } from "./config";
import { controllerAbi, coreAbi, creditsAbi, erc20Abi, redemptionPolicyAbi, statementsAbi, treasuryAbi } from "./abis";
import { SCOPE, lsGet, lsSet } from "./cache";
import { ETH_ANCHOR_SLOT, ethAnchorWords, replayBalanceFills, replayEthFills, replayValueFills } from "./sell";
import { useCreditRow, useCreditTraitsIx, useHeldCredits, useIxMode, useStatementDetailIx, useWalletCreditsIx } from "./indexer";
import type { AcquiredHow } from "./indexer-schema";
import type { BalanceTokenInfo } from "./format";
import type { ClaimQuoteRead } from "./exchange";

type Client = NonNullable<ReturnType<typeof usePublicClient>>;

export { MULTICALL3, readSnapshot } from "@cc/engine/snapshot";

// The website's RPC API takes a request body of at most 128 KiB (lib/rpc-handler.ts). viem's multicall batchSize
// counts only the calls' own calldata, while the Multicall3 encoding adds about 188 bytes a call, so the shared 16 KB
// chunk of 36 byte per-id calls (455 of them) encodes to about 200 KB and is refused, failing every call of the chunk.
// 4 KB of calldata per request (wagmi's batching merges concurrent multicalls up to the same size) is at most 113
// per-id calls, about 51 KB of hex. Every per-credit multicall of the website uses this.
export const RPC_BATCH_BYTES = 4_096;
export const mc = { ...engineMc, batchSize: RPC_BATCH_BYTES } as const;

// CreditScore.scoreOf(seedOf, timestampOf) per id, in input order: the engine helper's reads with the website's
// batch size. wagmi batches multicalls, merging concurrent ones of the same batch size up to that size, so a read
// at the engine's 16 KB size merges into requests the RPC API refuses (200 credits' seed reads are about 180 KB).
export async function creditScores(client: Client, ids: bigint[], blockNumber?: bigint): Promise<bigint[]> {
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

// Whether the coin has code: false while the Core is deployed and the coin is not launched, undefined until read.
// While false it is read again every COIN_LIVE_POLL_MS (one getCode per poll); once true it is cached and not polled.
const COIN_LIVE_POLL_MS = 15000;
export function useCoinLive(): boolean | undefined {
  const client = usePublicClient();
  const coin = useSnapshot().data?.coin;
  return useQuery<boolean>({
    queryKey: ["coin-live", coin],
    enabled: Boolean(client && coin),
    staleTime: Infinity,
    refetchInterval: (q) => (q.state.data === true ? false : COIN_LIVE_POLL_MS),
    queryFn: async () => ((await client!.getCode({ address: coin! })) ?? "0x") !== "0x",
  }).data;
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
// creditPrice. `loading` is true until the source answers.
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
    if (mode !== "ix" || !s || !base) return [];
    return base.map((c) => ({
      ...c,
      inPile: true,
      price: saleOn ? prices.data?.get(c.id) ?? 0n : 0n,
      past: !saleOn || c.acquiredAt + s.creditWindow <= now,
    }));
  }, [mode, s, base, saleOn, prices.data, now]);
  // loading: the source has not answered yet, so an empty list is not an empty pile. pricing: the list is known but the
  // live prices are still being read (indexer mode reads them after the list, in chunks), so a price of 0 is unread
  const loading =
    engineDeployed &&
    (!s ||
    mode === "checking" ||
    (mode === "ix" ? base === undefined && !held.isError : chain.data === undefined && !chain.isError));
  const pricing = mode === "ix" && saleOn && (base?.length ?? 0) > 0 && !prices.data && !prices.isError;
  return { data: mode === "ix" ? ixData : chain.data ?? [], loading, pricing };
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
  // A failed ethPrice read leaves the batch available; the other reads must answer.
  const [res, startWord, bucketWord, scores] = await Promise.all([
    client.multicall({
      ...mc,
      blockNumber,
      allowFailure: true,
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
        { ...c, functionName: "sharedRate" },
        { ...c, functionName: "controller" },
      ] as const,
    }),
    word(1n),
    word(2n),
    creditScores(client, ids, blockNumber),
  ]);
  const need = <T,>(i: number): T => {
    if (res[i].status !== "success") throw new Error("sell quote read failed");
    return res[i].result as T;
  };
  const ethPot = need<bigint>(2), toBuyback = need<bigint>(3), redeemBurn = need<bigint>(4), payeeOn = need<boolean>(5);
  const st = need<Snapshot["settings"]>(6), held = need<bigint>(7), reserve = need<bigint>(8);
  const { toPot } = pendingIncome(held, ethPot, toBuyback, redeemBurn, payeeOn, st.payeePpm, st.feeToRedeemBurnBps);
  // the bids read the pot less the reserve (Core.room); a batch that carries the pile across a page raises the reserve
  // by one queued compose, which this quote does not model
  const pot = ethPot + toPot;
  const room = pot > reserve ? pot - reserve : 0n;
  if (st.valueModeOn) {
    // Value mode: the shared instance times the protected buy value; replay stops when that value is unusable.
    const [value, ok] = await client.readContract({ address: need<Address>(10), abi: controllerAbi, functionName: "valuePerPoint", args: [false], blockNumber });
    if (!ok || value === 0n) throw new Error("the balance token price quote is unavailable");
    return replayValueFills(scores, {
      rate: need<bigint>(9),
      value,
      pot: room,
      rateCap: BigInt(st.rateCap),
      scorePer100Points: SCORE_PER_100_POINTS,
      dropPer100PointsBps: BigInt(st.dropPer100PointsBps),
      dropFloorBps: BigInt(st.dropFloorBps),
      floorBps: 10000n - BigInt(st.balanceBidMarginBps),
      buyToArtistBps: BigInt(st.buyToArtistBps),
    });
  }
  return replayEthFills(scores, {
    price: need<bigint>(0),
    peak: need<bigint>(1),
    pot: room,
    ...ethAnchorWords(BigInt(startWord ?? "0x0"), BigInt(bucketWord ?? "0x0"), BigInt(Math.floor(now)), BigInt(st.bucketSeconds)),
    dropPer100PointsBps: BigInt(st.dropPer100PointsBps),
    dropFloorBps: BigInt(st.dropFloorBps),
    ceilBps: BigInt(st.ceilBps),
    rateCap: BigInt(st.rateCap),
    scorePer100Points: SCORE_PER_100_POINTS,
    buyToArtistBps: BigInt(st.buyToArtistBps),
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
    placeholderData: keepPreviousData, // a new id keeps the others' scores on screen while the list is read again
    queryFn: async () => {
      const scores = await creditScores(client!, ids);
      const m: Record<string, bigint> = {};
      ids.forEach((id, i) => (m[id.toString()] = scores[i]));
      return m;
    },
  });
  const ixq = useCreditTraitsIx(mode === "ix" ? ids.map(Number) : []);
  const ixScores = useMemo(() => (ixq.data ? Object.fromEntries(Object.entries(ixq.data).map(([id, r]) => [id, r.score])) : undefined), [ixq.data]);
  return { data: mode === "ix" ? ixScores : chain.data, loading: readsPending(ids.length, mode, ixq, chain) };
}

// A per-credit read (scores, traits) whose ids are not all in hand yet: the indexer check, or the source's query (its
// previous answer kept while it reads a changed list) has not answered. A failed read is not pending.
type Q = { isPending: boolean; isPlaceholderData: boolean; isError: boolean };
const readsPending = (n: number, mode: string, ixq: Q, chain: Q): boolean =>
  engineDeployed && n > 0 && (mode === "checking" || (() => {
    const q = mode === "ix" ? ixq : chain;
    return (q.isPending || q.isPlaceholderData) && !q.isError;
  })());

// Points held by the engine: the scores of the credits in the pile plus the current totals of the statements it holds
// (ratingOf, which an overprint can change). A composed credit leaves the pile, so nothing counts twice. Scores are in
// 1/10,000 point. undefined until every part is read: the whole pile (chain mode lists only its first PILE_PAGE), each
// pile credit's score and the held statements.
export function usePointsHeld(): bigint | undefined {
  const { data: s } = useSnapshot();
  const { data: pile, loading } = usePile();
  const { data: scores } = useScores(pile.map((c) => BigInt(c.id)));
  const held = useStatements();
  if (!s || loading || pile.length !== Number(s.pileSize) || !held.isSuccess || held.data.length !== s.held.length) return undefined;
  let total = 0n;
  for (const c of pile) {
    const v = c.score ?? scores?.[String(c.id)];
    if (v == null) return undefined;
    total += v;
  }
  for (const st of held.data) total += st.rating;
  return total;
}

// Credit price floor input: controller valueOf(score) per id, id to wei. Credit floor price =
// max(cost, value) * snap.creditFloorBps / 10000 (the controller's floorMultBps) and start = floor * snap.creditStartBps / 10000 (see Snapshot).
// Scores are cached (useScores). valueOf follows the floor rate, so the query is keyed on the snapshot's
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
    placeholderData: keepPreviousData,
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
  return { data: mode === "ix" ? ixTraits : chain.data, loading: readsPending(ids.length, mode, ixq, chain) };
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
  return { data: data ?? [], scores, ready: data !== undefined, error: mode === "ix" ? ixq.error : chain.error };
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
  // in value mode the payout is clamped to the value rate at the protected sale price. When that price is missing or
  // zero the contract returns no quote and sellForBalance reverts, so the replay pays 0 (see replayBalanceFills)
  const valued = snap.value.on;
  return replayBalanceFills(scores, {
    rate: snap.balanceRate,
    unit: snap.balanceUnit,
    scorePer100Points: SCORE_PER_100_POINTS,
    dropPer100PointsBps: BigInt(snap.settings.dropPer100PointsBps),
    dropFloorBps: BigInt(snap.settings.dropFloorBps),
    floorBps: 10000n - BigInt(snap.settings.balanceBidMarginBps),
    valueModeOn: valued,
    ethPrice: valued ? snap.ethPrice : undefined,
    valueSell: snap.value.perPointSell,
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

// ---- phase 2 treasury (the claim panel of /exchange) -------------------------------------------------------------

export interface TreasuryInfo {
  treasury: Address;
  balanceToken: Address;
  balanceSymbol?: string;
  balanceDecimals?: number;
  coin: Address;
  coinSymbol?: string;
  coinDecimals?: number;
  ccSupply: bigint;
  walletCc?: bigint;
  policy: Address;
  policyVersion?: string;
  claimReserve: bigint;
  freeWorking: bigint;
  conversionToClaimBps: number;
  redemptionFeeBps: number;
  configEpoch: bigint;
  ccRedemptionEnabled: boolean;
  // selectedForClaims(): the Core's module and not migrated, the gate of CC burns
  selected: boolean;
  transfersReady: boolean;
  solvent: boolean;
  migrated: boolean;
}

const TREASURY_POLL_MS = 15000;

// The Core's balance module read as a phase 2 treasury (IPhase2BalanceTreasury.sol), every 15 s. `data` is null when
// the module does not answer quoteRedemption and claimReserve (no module, or the StatementBalanceModule), so the panel
// can say so instead of showing figures. Every other read is tolerant: a missing symbol or policy version leaves its
// field undefined. Live reads only; the indexer's treasury tables are history (docs/INDEXER.md section 9.6)
export function useTreasury(account?: Address) {
  const client = usePublicClient();
  const { data: snap } = useSnapshot();
  const module = snap?.balanceModule && snap.balanceModule !== zeroAddress ? snap.balanceModule : undefined;
  const q = useQuery<TreasuryInfo | null>({
    queryKey: ["treasury", module, account],
    enabled: engineDeployed && Boolean(client && module),
    refetchInterval: TREASURY_POLL_MS,
    placeholderData: keepPreviousData,
    queryFn: async () => {
      const t = { address: module!, abi: treasuryAbi } as const;
      const r = await client!.multicall({
        ...mc,
        allowFailure: true,
        contracts: [
          { ...t, functionName: "quoteRedemption", args: [1n] },
          { ...t, functionName: "claimReserve" },
          { ...t, functionName: "freeWorking" },
          { ...t, functionName: "conversionToClaimBps" },
          { ...t, functionName: "redemptionFeeBps" },
          { ...t, functionName: "configEpoch" },
          { ...t, functionName: "redemptionPolicy" },
          { ...t, functionName: "ccRedemptionEnabled" },
          { ...t, functionName: "selected" },
          { ...t, functionName: "transfersReady" },
          { ...t, functionName: "solvent" },
          { ...t, functionName: "migrated" },
          { ...t, functionName: "balanceToken" },
          { ...t, functionName: "ccToken" },
          { ...t, functionName: "selectedForClaims" },
        ] as const,
      });
      const probe = r[0];
      if (probe.status !== "success" || r[1].status !== "success") return null;
      const v = <T,>(i: number, d: T): T => val(r[i], d);
      const balanceToken = v<Address>(12, zeroAddress);
      const coin = v<Address>(13, snap?.coin ?? zeroAddress);
      const policy = v<Address>(6, zeroAddress);
      const e = { abi: erc20Abi } as const;
      const x = await client!.multicall({
        ...mc,
        allowFailure: true,
        contracts: [
          { ...e, address: coin, functionName: "symbol" },
          { ...e, address: coin, functionName: "decimals" },
          { ...e, address: coin, functionName: "totalSupply" },
          { ...e, address: coin, functionName: "balanceOf", args: [account ?? zeroAddress] },
          { ...e, address: balanceToken, functionName: "symbol" },
          { ...e, address: balanceToken, functionName: "decimals" },
          { address: policy, abi: redemptionPolicyAbi, functionName: "VERSION" },
        ] as const,
      });
      const opt = <T,>(i: number): T | undefined => (x[i].status === "success" ? (x[i].result as T) : undefined);
      return {
        treasury: module!,
        balanceToken,
        balanceSymbol: opt<string>(4),
        balanceDecimals: opt<number>(5),
        coin,
        coinSymbol: opt<string>(0),
        coinDecimals: opt<number>(1),
        // the supply quoteRedemption divides by; the probe's answer and totalSupply agree at one block
        ccSupply: opt<bigint>(2) ?? (probe.result as readonly [bigint, bigint, bigint, bigint, boolean])[2],
        walletCc: account ? opt<bigint>(3) : undefined,
        policy,
        policyVersion: opt<string>(6),
        claimReserve: r[1].result as bigint,
        freeWorking: v<bigint>(2, 0n),
        conversionToClaimBps: Number(v<number>(3, 0)),
        redemptionFeeBps: Number(v<number>(4, 0)),
        configEpoch: BigInt(v<bigint>(5, 0n)),
        ccRedemptionEnabled: v<boolean>(7, false),
        // the burn gate is selectedForClaims (selected and not migrated, whatever the Core's retirement); a treasury
        // built before that view answers selected()
        selected: v<boolean>(14, v<boolean>(8, false)),
        transfersReady: v<boolean>(9, false),
        solvent: v<boolean>(10, false),
        migrated: v<boolean>(11, false),
      };
    },
  });
  // no module: known absent; the hook reports ready with null so the page can say the balance side is not set
  return { data: module ? q.data : engineDeployed && snap ? null : undefined, error: q.error, ready: module ? q.data !== undefined : Boolean(snap) };
}

// quoteRedemption(ccIn) of the treasury for the entered amount, every 15 s; the previous answer stays while the
// next loads for the same amount only. undefined while ccIn is 0
export function useClaimQuote(treasury: Address | undefined, ccIn: bigint) {
  const client = usePublicClient();
  const key = ccIn.toString();
  return useQuery<ClaimQuoteRead | undefined>({
    queryKey: ["claim-quote", treasury, key],
    enabled: engineDeployed && Boolean(client && treasury) && ccIn > 0n,
    refetchInterval: TREASURY_POLL_MS,
    placeholderData: (prev, prevQuery) => (prevQuery?.queryKey[2] === key ? prev : undefined),
    queryFn: async () => {
      const [balanceOut, reserve, supply, epoch, executable] = await client!.readContract({ address: treasury!, abi: treasuryAbi, functionName: "quoteRedemption", args: [ccIn] });
      return { ccIn, balanceOut, reserve, supply, epoch: BigInt(epoch), executable };
    },
  });
}
