"use client";

// The listing the header acquire button buys (owner decision 128). Candidates come from the CreditStrategy
// (indexer table strategy_listing; in chain mode a browser scan of its two events) and from the OpenSea route. They
// are shortlisted by an estimated bid, read live (price, owner, Core.bidOf, pot) and filtered by lib/acquire.ts.
// One query per chain head; the route caches OpenSea for 20 s on the server.

import { useQuery, useQueryClient } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { type Address } from "viem";
import { core, credits, engineDeployed, seaportAdapter, strategy, strategyAdapter, strategyStartBlock } from "./config";
import { coreAbi, creditsAbi, strategyAbi } from "./abis";
import { creditScores, MULTICALL3, useHead, type Snapshot } from "./live";
import { fetchStrategyListings, getIxMode, useIxMode } from "./indexer";
import { clearing, shortlist, type Listing, type Priced } from "./acquire";

type Client = NonNullable<ReturnType<typeof usePublicClient>>;
const mc = { multicallAddress: MULTICALL3, batchSize: 16_384 } as const;
const SHORTLIST = 6;
const MAX_SCORE_READS = 200;
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
    // ponytail: only the cheapest MAX_SCORE_READS unknown scores are read; an indexer that holds every credit never reaches this
    missing.splice(MAX_SCORE_READS);
    const read = await creditScores(client, missing);
    missing.forEach((id, i) => {
      scoreCache.set(id, read[i]);
      out.set(id, read[i]);
    });
  }
  return out;
}

// ---- the hook -------------------------------------------------------------------------------------------------

export interface Diag {
  id: string;
  source: string;
  price: string;
  bid: string;
  clears: boolean;
}

export function useAcquireCandidate() {
  const client = usePublicClient();
  const qc = useQueryClient();
  const mode = useIxMode();
  const { data: head } = useHead();
  const on = engineDeployed && Boolean(client) && Boolean(strategyAdapter) && head != null && mode !== "checking";

  const q = useQuery<{ cleared: Priced[]; top: Diag[] }>({
    queryKey: ["acquire", mode, head?.n?.toString()],
    enabled: on,
    staleTime: 10_000,
    retry: 0,
    queryFn: async () => {
      try {
      const snap = qc.getQueryData<Snapshot>(["snapshot", core]);
      if (!snap) return { cleared: [], top: [] };
      const c = client!;

      // 1. listings and known scores
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
      strat ??= [...(await scanStrategy(c, head!.n)).entries()].map(([id, price]) => ({ id, price }));
      for (const r of strat) listings.push({ id: r.id, price: r.price, source: "strategy", params: "0x" });
      try {
        const r = await fetch("/api/listings");
        const body = (await r.json()) as { listings: { id: string; price: string; params: `0x${string}` }[] };
        for (const l of body.listings ?? []) listings.push({ id: BigInt(l.id), price: BigInt(l.price), source: "opensea", params: l.params });
      } catch {
        /* the strategy listings stand alone */
      }

      // 2. shortlist by estimated bid
      const byPrice = [...listings].sort((a, b) => (a.price < b.price ? -1 : a.price > b.price ? 1 : 0));
      const scores = await scoresOf(c, [...new Set(byPrice.map((l) => l.id))], known);
      const picked = shortlist(listings, snap.ethRate, BigInt(snap.settings.refScore), scores, SHORTLIST);
      if (!picked.length) return { cleared: [], top: [] };

      // 3. live read of the shortlist
      const cc = { address: core!, abi: coreAbi } as const;
      const res = await c.multicall({
        ...mc,
        allowFailure: true,
        contracts: [
          { ...cc, functionName: "ethPot" },
          { ...cc, functionName: "retired" },
          { ...cc, functionName: "allowedAdapter", args: [strategyAdapter!] },
          { ...cc, functionName: "allowedAdapter", args: [seaportAdapter ?? strategyAdapter!] },
          ...picked.flatMap((l) => [
            { ...cc, functionName: "bidOf", args: [l.id] },
            { address: credits, abi: creditsAbi, functionName: "ownerOf", args: [l.id] },
            { address: strategy, abi: strategyAbi, functionName: "nftForSale", args: [l.id] },
          ] as const),
        ] as any, // mixed contracts; results are cast by position below
      });
      const val = <T,>(i: number) => (res[i].status === "success" ? ((res[i] as { result: unknown }).result as T) : undefined);
      const pot = val<bigint>(0) ?? 0n;
      const retired = val<boolean>(1) ?? true;
      const allowed: Record<Listing["source"], boolean> = { strategy: val<boolean>(2) ?? false, opensea: Boolean(seaportAdapter) && (val<boolean>(3) ?? false) };

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
      const cleared = clearing(priced, pot, retired);
      const top = [...priced]
        .sort((a, b) => Number(b.bid - b.price - (a.bid - a.price)))
        .map((l) => ({ id: l.id.toString(), source: l.source, price: l.price.toString(), bid: l.bid.toString(), clears: cleared.includes(l) }));
      // eslint-disable-next-line no-console
      console.debug("[acquire] shortlist " + JSON.stringify({ pot: pot.toString(), retired, cleared: cleared.length, top }));
      return { cleared, top };

      } catch (e) {
        console.warn("[acquire] listing read failed", e);
        return { cleared: [], top: [] };
      }
    },
  });
  return { cleared: q.data?.cleared ?? [], top: q.data?.top ?? [], block: head?.n };
}

/** `params` and adapter of a candidate for Core.buyListing. */
export const adapterOf = (l: Listing): Address => (l.source === "strategy" ? strategyAdapter! : seaportAdapter!);
