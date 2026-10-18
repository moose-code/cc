"use client";

// The listing the header acquire button buys (owner decision 134). Candidates come from the CreditStrategy
// (indexer table strategy_listing; in chain mode a browser scan of its two events) and from the OpenSea route. They
// are shortlisted by an estimated bid, read at one snapshot block (price, owner, Core.bidOf, buying room) and filtered by lib/acquire.ts.
// One query per chain head; the route caches OpenSea for 20 s on the server.

import { useEffect, useState } from "react";
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { useAccount, usePublicClient } from "wagmi";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { type Address } from "viem";
import { core, credits, engineDeployed, SCORE_PER_100_POINTS, seaportAdapter, strategy, strategyAdapter, strategyStartBlock } from "./config";
import { coreAbi, creditsAbi, strategyAbi } from "./abis";
import { creditScores, MULTICALL3, readSnapshot, useHead } from "./live";
import { fetchScoresIx, fetchStrategyListings, getIxMode, useIxMode } from "./indexer";
import { useTx } from "./tx";
import { clearing, fitsBucket, shortlist, type Listing, type Priced, type SpendRoom } from "./acquire";

type Client = NonNullable<ReturnType<typeof usePublicClient>>;
const mc = { multicallAddress: MULTICALL3, batchSize: 16_384 } as const;
const SHORTLIST = 6;
const MAX_SCORE_READS = 600;
const FULFILL_TRIES = 3; // OpenSea fulfillments fetched per query, best estimated margin first
const CHUNK = 10_000n; // blocks per getLogs call
const RESCAN = 12n; // blocks re-read behind the last scanned block (reorg window)

// ---- chain mode: strategy listings from its events ------------------------------------------------------------

const scan = { next: strategyStartBlock, listed: new Map<bigint, bigint>() };

// NFTBoughtByProtocol lists a credit at listPrice, NFTSoldByProtocol ends the listing; the last event of an id wins.
// Replaying the last RESCAN blocks yields the same state.
async function scanStrategy(client: Client, head: bigint): Promise<Map<bigint, bigint>> {
  const from = scan.next > strategyStartBlock + RESCAN ? scan.next - RESCAN : strategyStartBlock;
  for (let a = from; a <= head; a += CHUNK) {
    const to = a + CHUNK - 1n < head ? a + CHUNK - 1n : head;
    const logs = await client.getLogs({ address: strategy, events: [strategyAbi[0], strategyAbi[1]], fromBlock: a, toBlock: to });
    for (const l of logs) {
      if (l.eventName === "NFTBoughtByProtocol") scan.listed.set(l.args.tokenId!, l.args.listPrice!);
      else scan.listed.delete(l.args.tokenId!);
    }
  }
  scan.next = head + 1n;
  return scan.listed;
}

// ---- scores ---------------------------------------------------------------------------------------------------

const scoreCache = new Map<bigint, bigint>(); // credit scores never change

async function scoresOf(client: Client, ids: bigint[], known: Map<bigint, bigint>): Promise<Map<bigint, bigint>> {
  const out = new Map<bigint, bigint>();
  const missing: bigint[] = [];
  for (const id of ids) {
    const s = known.get(id) ?? scoreCache.get(id);
    if (s != null) {
      scoreCache.set(id, s);
      out.set(id, s);
    } else missing.push(id);
  }
  if (missing.length) {
    // ponytail: at most MAX_SCORE_READS unknown scores are read in chain mode; an indexer that holds every credit never reaches this
    missing.splice(MAX_SCORE_READS);
    const read = await creditScores(client, missing);
    missing.forEach((id, i) => {
      scoreCache.set(id, read[i]);
      out.set(id, read[i]);
    });
  }
  return out;
}

// ---- spend cap ------------------------------------------------------------------------------------------------

/**
 * The current bucket of CoreLib.spend from a `spendState()` read. A failed read (a Core without the view) leaves the
 * cap unchecked and the pre-send simulation decides. `now` is chain time in seconds.
 */
export function spendRoom(state: readonly [bigint, bigint, bigint] | undefined, s: { spendCapBps: number; bucketSeconds: number }, now: number): SpendRoom {
  if (!state || s.spendCapBps >= 10_000) return { capped: false, budget: 0n, spent: 0n, nextIn: 0 };
  const [bucket, budget, spent] = state;
  return { capped: true, budget, spent, nextIn: Math.max(1, Number(bucket + 1n) * s.bucketSeconds - Math.floor(now)) };
}

/**
 * What CoreLib.spend books for a purchase: the ask plus the keeper payment. The payment is at least `keeperFee` plus gas
 * and at most the bid and the pot less the ask; the fixed fee within that bound is the part known before the call.
 */
export function spendCost(price: bigint, bid: bigint, pot: bigint, keeperFee: bigint | number | string): bigint {
  const left = (bid < pot ? bid : pot) - price;
  const fee = BigInt(keeperFee);
  return price + (left < 0n ? 0n : left < fee ? left : fee);
}

/** Name of the contract error in a viem error, else its short message. */
function revertReason(e: unknown): string {
  for (let cur = e as { cause?: unknown; data?: { errorName?: string }; shortMessage?: string } | undefined, i = 0; cur && i < 6; cur = cur.cause as typeof cur, i++) {
    if (cur.data?.errorName) return cur.data.errorName;
  }
  return (e as { shortMessage?: string })?.shortMessage ?? "reverted";
}

// ---- candidate gathering, shared with the /listings page --------------------------------------------------------

/** OpenSea route entries: id, total price, order hash, expiry; `max` is the route's bound on the list. */
export async function fetchOpenSea(): Promise<{ listings: { id: string; price: string; orderHash: string; expiry: number }[]; max: number }> {
  try {
    const body = await (await fetch("/api/listings")).json();
    return { listings: body.listings ?? [], max: body.max ?? 0 };
  } catch {
    return { listings: [], max: 0 };
  }
}

/**
 * Every listing of both venues and the scores the indexer already holds. Strategy listings come from the indexer
 * (decision 133: the chain scan when it is unconfigured or failing); OpenSea from the server route, unexpired only.
 */
export async function gatherListings(c: Client, head: bigint): Promise<{ listings: Listing[]; known: Map<bigint, bigint>; osMax: number }> {
  const listings: Listing[] = [];
  const known = new Map<bigint, bigint>();
  let strat: { id: bigint; price: bigint }[] | undefined;
  if (getIxMode() === "ix") {
    try {
      const rows = await fetchStrategyListings();
      strat = rows;
      rows.forEach((r) => r.score != null && known.set(r.id, r.score));
    } catch {
      /* the indexer failed: scan the chain below */
    }
  }
  strat ??= [...(await scanStrategy(c, head)).entries()].map(([id, price]) => ({ id, price }));
  for (const r of strat) listings.push({ id: r.id, price: r.price, source: "strategy", params: "0x" });
  const os = await fetchOpenSea();
  const now = Math.floor(Date.now() / 1000);
  for (const l of os.listings) if (l.expiry > now) listings.push({ id: BigInt(l.id), price: BigInt(l.price), source: "opensea", params: "0x", orderHash: l.orderHash });
  return { listings, known, osMax: os.max };
}

/** Scores for `ids`: the indexer's credit table first, the chain for the rest. */
export async function scoresFor(c: Client, ids: bigint[], known: Map<bigint, bigint>): Promise<Map<bigint, bigint>> {
  if (getIxMode() === "ix") {
    try {
      for (const [id, s] of await fetchScoresIx(ids.filter((id) => !known.has(id)))) known.set(id, s);
    } catch {
      /* scores are read from the chain below */
    }
  }
  return scoresOf(c, ids, known);
}

// ---- the hook -------------------------------------------------------------------------------------------------

export interface Diag {
  id: string;
  source: string;
  price: string;
  bid: string;
  est: string; // estimate from the snapshot rate and the score, the shortlist key
  clears: boolean;
}

export function useAcquireCandidate() {
  const { address } = useAccount();
  const client = usePublicClient();
  const mode = useIxMode();
  const { data: head } = useHead();
  const on = engineDeployed && Boolean(client) && Boolean(strategyAdapter) && head != null && mode !== "checking";

  const q = useQuery<{ cleared: Priced[]; top: Diag[]; waiting: number; nextIn: number; reverted?: string }>({
    queryKey: ["acquire", mode, head?.n?.toString(), address],
    enabled: on,
    staleTime: 10_000,
    retry: 0,
    placeholderData: keepPreviousData,
    queryFn: async () => {
      try {
      const c = client!;
      const snap = await readSnapshot(c, core!);

      // 1. listings and known scores
      const { listings, known } = await gatherListings(c, head!.n);

      // 2. shortlist by estimated margin over every listing
      const ids = [...new Set(listings.map((l) => l.id))];
      const scores = await scoresFor(c, ids, known);
      const est = (id: bigint) => (snap.ethRate * (scores.get(id) ?? 0n)) / SCORE_PER_100_POINTS;
      const picked = shortlist(listings, snap.ethRate, SCORE_PER_100_POINTS, scores, SHORTLIST);
      if (!picked.length) return { cleared: [], top: [], waiting: 0, nextIn: 0 };

      // 3. live read of the shortlist
      const cc = { address: core!, abi: coreAbi } as const;
      const res = await c.multicall({
        ...mc,
        blockNumber: snap.blockNumber,
        allowFailure: true,
        contracts: [
          { ...cc, functionName: "retired" },
          { ...cc, functionName: "allowedAdapter", args: [strategyAdapter!] },
          { ...cc, functionName: "allowedAdapter", args: [seaportAdapter ?? strategyAdapter!] },
          { ...cc, functionName: "spendState" },
          ...picked.flatMap((l) => [
            { ...cc, functionName: "bidOf", args: [l.id] },
            { address: credits, abi: creditsAbi, functionName: "ownerOf", args: [l.id] },
            { address: strategy, abi: strategyAbi, functionName: "nftForSale", args: [l.id] },
          ] as const),
        ] as any, // mixed contracts; results are cast by position below
      });
      const val = <T,>(i: number) => (res[i].status === "success" ? ((res[i] as { result: unknown }).result as T) : undefined);
      // Snapshot buying room includes pending income once; the bid and listing reads use its block.
      const pot = snap.potRoom;
      const retired = val<boolean>(0) ?? true;
      const allowed: Record<Listing["source"], boolean> = { strategy: val<boolean>(1) ?? false, opensea: Boolean(seaportAdapter) && (val<boolean>(2) ?? false) };

      const room = spendRoom(val<readonly [bigint, bigint, bigint]>(3), snap.settings, head!.ts + (Date.now() - head!.at) / 1000);
      const fee = snap.settings.keeperFee;

      const priced: Priced[] = [];
      picked.forEach((l, i) => {
        const bid = val<bigint>(4 + 3 * i);
        const owner = val<Address>(5 + 3 * i);
        const live = val<bigint>(6 + 3 * i);
        if (bid == null || owner == null || !allowed[l.source]) return;
        if (l.source === "strategy") {
          if (!live || owner.toLowerCase() !== strategy.toLowerCase()) return;
          priced.push({ ...l, price: live, bid });
        } else if (owner.toLowerCase() !== core!.toLowerCase()) priced.push({ ...l, bid });
      });
      // 4. fulfillment data for the best OpenSea candidates that clear; the price is re-checked against it
      const first = clearing(priced, pot, retired);
      let tries = 0;
      let waiting = 0; // clears on bid and pot, over the bucket's spend cap
      const cleared: Priced[] = [];
      for (const l of first) {
        if (!fitsBucket(room, spendCost(l.price, l.bid, pot, fee))) {
          waiting++;
          continue;
        }
        if (l.source !== "opensea") {
          cleared.push(l);
          continue;
        }
        if (tries++ >= FULFILL_TRIES) continue;
        try {
          const f = (await (await fetch(`/api/listings?fulfill=${l.orderHash}`)).json()) as { price?: string; params?: `0x${string}` };
          if (!f.params || !f.price) continue;
          const p = { ...l, price: BigInt(f.price), params: f.params };
          if (clearing([p], pot, retired).length) {
            if (fitsBucket(room, spendCost(p.price, p.bid, pot, fee))) cleared.push(p);
            else waiting++;
          }
        } catch {
          /* this order is skipped */
        }
      }
      const top = [...priced]
        .sort((a, b) => Number(b.bid - b.price - (a.bid - a.price)))
        .map((l) => ({ id: l.id.toString(), source: l.source, price: l.price.toString(), bid: l.bid.toString(), est: est(l.id).toString(), clears: first.includes(l) }));
      // 5. the first candidate whose call simulates enables the button; a revert is reported instead of sent
      let reverted: string | undefined;
      let ready: Priced[] = [];
      for (const l of cleared) {
        try {
          await c.simulateContract({ address: core!, abi: coreAbi, functionName: "buyListing", args: [adapterOf(l), l.id, l.params], account: address });
          ready = [l];
          break;
        } catch (e) {
          reverted ??= `#${l.id} ${revertReason(e)}`;
        }
      }
      // eslint-disable-next-line no-console
      console.debug("[acquire] shortlist " + JSON.stringify({ pot: pot.toString(), retired, cleared: cleared.length, waiting, reverted, top }));
      return { cleared: ready, top, waiting, nextIn: room.nextIn, reverted: ready.length ? undefined : reverted };

      } catch (e) {
        console.warn("[acquire] listing read failed", e);
        return { cleared: [], top: [], waiting: 0, nextIn: 0 };
      }
    },
  });
  return { cleared: q.data?.cleared ?? [], top: q.data?.top ?? [], waiting: q.data?.waiting ?? 0, nextIn: q.data?.nextIn ?? 0, reverted: q.data?.reverted, block: head?.n };
}

/** `params` and adapter of a candidate for Core.buyListing. */
export const adapterOf = (l: Listing): Address => (l.source === "strategy" ? strategyAdapter! : seaportAdapter!);

const keyOf = (l: { source: string; id: bigint; price: bigint }) => `${l.source}:${l.id}:${l.price}`;

/**
 * Core.buyListing for the first of `candidates` that simulates. A candidate that reverts is dropped for the block.
 * An OpenSea candidate without fulfillment data (`params` "0x") has it fetched from the route first. Shared by the
 * header button and the /listings rows.
 */
export function useAcquireTx(block: bigint | undefined) {
  const { address } = useAccount();
  const client = usePublicClient();
  const { openConnectModal } = useConnectModal();
  const { run, pending, err } = useTx();
  const [dropped, setDropped] = useState<{ block?: bigint; keys: string[] }>({ keys: [] });
  const [done, setDone] = useState<{ id: bigint; hash: `0x${string}` }>();

  const live = dropped.block === block ? dropped.keys : [];
  const available = <T extends Listing>(list: T[]) => list.filter((l) => !live.includes(keyOf(l)));

  // the confirmation stays 20 s
  useEffect(() => {
    if (!done) return;
    const t = setTimeout(() => setDone(undefined), 20_000);
    return () => clearTimeout(t);
  }, [done]);

  const buy = (candidates: Priced[]) => {
    if (!address) return openConnectModal?.();
    setDone(undefined);
    run(async (write) => {
      const bad: string[] = [];
      try {
        for (let l of available(candidates)) {
          if (l.source === "opensea" && l.params === "0x") {
            try {
              const f = (await (await fetch(`/api/listings?fulfill=${l.orderHash}`)).json()) as { price?: string; params?: `0x${string}` };
              if (!f.params || !f.price) throw new Error("no fulfillment");
              l = { ...l, price: BigInt(f.price), params: f.params };
            } catch {
              bad.push(keyOf(l));
              continue;
            }
          }
          const req = { address: core!, abi: coreAbi, functionName: "buyListing", args: [adapterOf(l), l.id, l.params] } as const;
          try {
            await client!.simulateContract({ ...req, account: address });
          } catch {
            bad.push(keyOf(l));
            continue;
          }
          const hash = await write(req);
          setDone({ id: l.id, hash });
          return;
        }
        throw new Error("no listing available");
      } finally {
        if (bad.length) setDropped((d) => ({ block, keys: [...(d.block === block ? d.keys : []), ...bad] }));
      }
    }, [{ label: "acquire" }]);
  };
  return { buy, available, pending, err, done };
}
