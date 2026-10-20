"use client";

// Rows of the /listings page and the feed tab: every listed Credit of both venues (lib/useAcquire.ts gathers them from
// the indexer and the keeper's market view), its bid estimated from the snapshot rate and the score, the best LIVE
// rows re-read at one block (Core.bidOf, holder, strategy price, Seaport order status), and the time the bid reaches
// the price (lib/climb.ts). One stable query polled every READ_MS: a failed read keeps the last rows on screen and
// reports the failure, so a page never loops on "reading" without data.

import { keepPreviousData, useQuery, useQueryClient } from "@tanstack/react-query";
import { numberToHex, type Address } from "viem";
import { usePublicClient } from "wagmi";
import { seaportAbi } from "@cc/engine/abis";
import { SEAPORT } from "@cc/engine/addresses";
import { core, credits, engineDeployed, SCORE_PER_100_POINTS, seaportAdapter, strategy, strategyAdapter } from "./config";
import { coreAbi, creditsAbi, strategyAbi } from "./abis";
import { MULTICALL3, readSnapshot, useHead } from "./live";
import { useIxMode } from "./indexer";
import { bucketCount, cheapestPerId, compareListingPricePerPoint, fitsBucket, type Priced, type StrategyReadStatus } from "./acquire";
import { gatherListings, scoresFor, spendCost, spendRoom } from "./useAcquire";
import type { MarketOut } from "./market-view";
import { ETH_ANCHOR_SLOT, ETH_CLOCK_SLOT } from "./sell";
import { clearsIn, type ClearsIn, type ClimbState } from "./climb";

const LIVE = 100; // rows (smallest estimated gap first) whose bid and listing are re-read from the chain
const READ_MS = 12_000; // one chain read per block time while a listings surface is open
const mc = { multicallAddress: MULTICALL3, batchSize: 16_384 } as const;

export interface ListingRow extends Priced {
  score: bigint;
  paused: boolean;
  live: boolean; // bid and price are chain reads, else the bid is an estimate
  gap: number; // price / bid - 1, as a fraction; Infinity with no bid
  clears: boolean; // Core.buyListing would accept it now
  balanceBid?: bigint; // balance token payout (Core.balanceBidOf) when live, else estimated; undefined with the bid off or no usable module
  wait?: number; // seconds until the next spend bucket, set on a row under bid and pot that this bucket's cap blocks
  eta: ClearsIn;
}

export interface ListingsData {
  rows: ListingRow[];
  paused: boolean;
  /** the market view these rows came from, for the status lines; undefined when the website API failed */
  market?: MarketOut;
  strategyStatus: StrategyReadStatus;
  pot: bigint;
  now: number;
  covers: number; // rows under their bid and the pot
  fits: number; // of those, the purchases that fit the current spend bucket in sequence
  capped: boolean;
  bucketSeconds: number;
  climb: ClimbState; // the eth bid's climb state at the head block, for the next-rise line
}

export function useListings() {
  const client = usePublicClient();
  const qc = useQueryClient();
  const mode = useIxMode();
  const { data: head } = useHead();
  return useQuery<ListingsData>({
    queryKey: ["listings-page", mode],
    enabled: engineDeployed && Boolean(client) && Boolean(strategyAdapter) && head != null && mode !== "checking",
    staleTime: READ_MS / 2,
    refetchInterval: READ_MS,
    retry: 0,
    // the rows of the last read stay on screen while the next one loads or fails
    placeholderData: keepPreviousData,
    queryFn: async () => {
      const c = client!;
      const snap = await readSnapshot(c, core!);
      const { listings, known, market, strategyStatus } = await gatherListings(qc);
      const best = cheapestPerId(listings);
      const scores = await scoresFor(c, best.map((l) => l.id), known);
      const bidFor = (rate: bigint, s: bigint) => (rate * s) / SCORE_PER_100_POINTS;
      let rows = best.flatMap((l) => {
        const score = scores.get(l.id);
        return score == null ? [] : [{ ...l, score, bid: bidFor(snap.ethRate, score), live: false }];
      });
      const gapOf = (price: bigint, bid: bigint) => (bid === 0n ? Infinity : Number((price * 1_000_000n) / bid) / 1_000_000 - 1);
      rows.sort((a, b) => (gapOf(a.price, a.bid) - gapOf(b.price, b.bid)) || compareListingPricePerPoint(a, b));

      // live read of the best rows: pot, retired, the two adapters, the climb state, the multiplier, then bidOf / ownerOf / nftForSale per row
      const top = rows.slice(0, LIVE);
      const balanceReads = snap.balanceOn && snap.settings.balanceBidOn; // one balanceBidOf per live row, after the per-row triples
      const orders = top.filter((l) => l.source === "opensea" && l.orderHash); // one Seaport getOrderStatus per live OpenSea row, last
      const cc = { address: core!, abi: coreAbi } as const;
      const word = (i: bigint) => c.getStorageAt({ address: core!, slot: numberToHex(ETH_ANCHOR_SLOT + i, { size: 32 }), blockNumber: snap.blockNumber });
      const [res, w0, w2, w3, clock] = await Promise.all([
        c.multicall({
          ...mc,
          // The website RPC rejects a 100-row Multicall3 payload at the shared batch size, hiding every acquire action.
          batchSize: 4_096,
          blockNumber: snap.blockNumber,
          allowFailure: true,
          contracts: [
            { ...cc, functionName: "retired" },
            { ...cc, functionName: "allowedAdapter", args: [strategyAdapter!] },
            { ...cc, functionName: "allowedAdapter", args: [seaportAdapter ?? strategyAdapter!] },
            { ...cc, functionName: "rateAtCheckpoint" },
            { ...cc, functionName: "checkpointTime" },
            { ...cc, functionName: "lastFillTime" },
            { ...cc, functionName: "spendState" },
            { ...cc, functionName: "climbMultiplier" },
            ...top.flatMap((l) => [
              { ...cc, functionName: "bidOf", args: [l.id] },
              { address: credits, abi: creditsAbi, functionName: "ownerOf", args: [l.id] },
              { address: strategy, abi: strategyAbi, functionName: "nftForSale", args: [l.id] },
            ] as const),
            ...(balanceReads ? top.map((l) => ({ ...cc, functionName: "balanceBidOf", args: [l.id] }) as const) : []),
            ...orders.map((l) => ({ address: SEAPORT, abi: seaportAbi, functionName: "getOrderStatus", args: [l.orderHash as `0x${string}`] }) as const),
          ] as any, // mixed contracts; results are cast by position below
        }),
        word(0n),
        word(2n),
        word(3n),
        c.getStorageAt({ address: core!, slot: numberToHex(ETH_CLOCK_SLOT, { size: 32 }), blockNumber: snap.blockNumber }),
      ]);
      const val = <T,>(i: number) => (res[i].status === "success" ? ((res[i] as { result: unknown }).result as T) : undefined);
      // Snapshot pending income is counted once for a purchase; only booked room advances the clock.
      const pendingPot = snap.potWithPending - snap.ethPot;
      const pot = snap.potRoom;
      const bookedRoom = snap.ethPot > snap.reserve ? snap.ethPot - snap.reserve : 0n;
      const retired = val<boolean>(0) ?? true;
      const allowed = { strategy: val<boolean>(1) ?? false, opensea: Boolean(seaportAdapter) && (val<boolean>(2) ?? false) };

      const live = new Map<bigint, { bid: bigint; price: bigint }>();
      const stale = new Set<bigint>();
      top.forEach((l, i) => {
        const bid = val<bigint>(8 + 3 * i);
        const owner = val<Address>(9 + 3 * i);
        const listed = val<bigint>(10 + 3 * i);
        if (bid == null || owner == null) return;
        if (l.source === "strategy") {
          if (!listed || owner.toLowerCase() !== strategy.toLowerCase()) {
            stale.add(l.id);
            return;
          }
          live.set(l.id, { bid, price: listed });
        } else if (owner.toLowerCase() === core!.toLowerCase()) stale.add(l.id);
        else live.set(l.id, { bid, price: l.price });
      });
      // a cancelled or filled Seaport order leaves the table; an unreadable status keeps the row, the simulation decides
      const orderBase = 8 + 3 * top.length + (balanceReads ? top.length : 0);
      orders.forEach((l, j) => {
        const st = val<readonly [boolean, boolean, bigint, bigint]>(orderBase + j);
        if (st && (st[1] || (st[3] > 0n && st[2] >= st[3]))) stale.add(l.id);
      });
      // balance bid per row: the live read for the top rows (0 or a failed read is off), else score * unit * rate / 10_000
      const balanceLive = new Map<bigint, bigint>();
      if (balanceReads) top.forEach((l, i) => {
        const v = val<bigint>(8 + 3 * top.length + i);
        if (v != null && v > 0n) balanceLive.set(l.id, v);
      });
      const balanceOf = (r: { id: bigint; score: bigint }): bigint | undefined => {
        if (!balanceReads) return undefined;
        if (top.some((l) => l.id === r.id)) return balanceLive.get(r.id);
        return snap.balanceUnit != null ? (r.score * snap.balanceUnit * snap.balanceRate) / 10000n : undefined;
      };
      rows = rows.filter((r) => !stale.has(r.id)).map((r) => {
        const v = live.get(r.id);
        return v ? { ...r, bid: v.bid, price: v.price, live: true } : r;
      });

      // forecast: the climb state of the eth bid, the Core's stored rate and anchor (word 2 packs minuteBucket and peakTime)
      const s = snap.settings;
      const w = BigInt(w2 ?? "0x0");
      const state: ClimbState = {
        r: val<bigint>(3) ?? snap.ethPrice,
        t: Number(val<bigint>(4) ?? 0n),
        anchorTime: Number(val<bigint>(5) ?? 0n),
        climbRestartTime: Number((BigInt(clock ?? "0x0") >> 128n) & ((1n << 64n) - 1n)),
        lastFillRate: BigInt(w0 ?? "0x0"),
        peakRate: BigInt(w3 ?? "0x0"),
        peakTime: Number((w >> 64n) & ((1n << 64n) - 1n)),
        ceilBps: s.ceilBps,
        idleLoosenBps: s.idleLoosenBps,
        idleStepSeconds: s.idleStepSeconds,
        climbMultiplierBps: Number(val<bigint>(7) ?? snap.climbMultiplier),
        rateCap: BigInt(s.rateCap),
        peakHalfLife: s.peakHalfLife,
        climbPerMinBps: s.climbPerMinBps,
        recoveryClimbPerMinBps: s.recoveryClimbPerMinBps,
        recoveryGapBps: s.recoveryGapBps,
        buyToArtistBps: s.buyToArtistBps,
        ethPot: bookedRoom,
        pending: pendingPot,
      };
      const now = head!.ts;
      const room = spendRoom(val<readonly [bigint, bigint, bigint]>(6), s, now + (Date.now() - head!.at) / 1000);
      const under: bigint[] = []; // spend cost of every row under its bid and the pot
      const out: ListingRow[] = rows.map((r) => {
        const covered = !snap.paused && !retired && allowed[r.source] && r.price > 0n && r.price <= r.bid && r.price <= pot;
        const cost = spendCost(r.price, r.bid, pot, s.keeperFee);
        if (covered) under.push(cost);
        const clears = covered && fitsBucket(room, cost);
        const wait = covered && !clears ? room.nextIn : undefined;
        // at or under the bid yet not clearing: the venue's adapter is off or the Core is retired, no time applies
        const f = clearsIn(state, r.price, r.score, SCORE_PER_100_POINTS, now);
        const eta: ClearsIn = clears ? { kind: "now" } : r.price > pot ? { kind: "pot" } : f.kind === "now" ? { kind: "far" } : f;
        return { ...r, paused: snap.paused, gap: gapOf(r.price, r.bid), clears, wait, eta, balanceBid: balanceOf(r) };
      });
      out.sort((a, b) => (a.gap - b.gap) || compareListingPricePerPoint(a, b));
      return { rows: out, paused: snap.paused, market, strategyStatus, pot, now, covers: under.length, fits: bucketCount(room, under), capped: room.capped, bucketSeconds: s.bucketSeconds, climb: state };
    },
  });
}
