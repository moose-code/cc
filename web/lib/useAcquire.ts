"use client";

// Listing acquisition through Core.buyListing (owner decision 134). Candidates come from the CreditStrategy (indexer
// table strategy_listing; in chain mode a browser scan of its two events) and from the keeper's market view through
// the website API. The listings page reads them at one block and filters with lib/acquire.ts; a purchase fetches the
// order's prepared fulfillment and simulates the call before sending.

import { useEffect, useState } from "react";
import type { QueryClient } from "@tanstack/react-query";
import { useAccount, usePublicClient } from "wagmi";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { type Address } from "viem";
import { core, strategy, strategyAdapter, seaportAdapter, strategyStartBlock } from "./config";
import { coreAbi, strategyAbi } from "./abis";
import { creditScores, useSnapshot } from "./live";
import { fetchScoresIx, fetchStrategyListings, getIxMode } from "./indexer";
import { readMarketView, type MarketOut } from "./market-view";
import { useTx } from "./tx";
import { type Listing, type Priced, type SpendRoom } from "./acquire";

type Client = NonNullable<ReturnType<typeof usePublicClient>>;
const MAX_SCORE_READS = 600;
const CHUNK = 5_000n; // blocks per getLogs call
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

// ---- candidate gathering, shared with the /listings page --------------------------------------------------------

/**
 * Every listing of both venues and the scores already known. Strategy listings come from the indexer (decision 133:
 * the chain scan when it is unconfigured or failing); OpenSea asks from the keeper's market view through the website
 * API (lib/market-view.ts), unexpired only, with the keeper's cached immutable scores.
 */
export async function gatherListings(c: Client, head: bigint, qc: QueryClient): Promise<{ listings: Listing[]; known: Map<bigint, bigint>; market?: MarketOut }> {
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
  let market: MarketOut | undefined;
  try {
    market = await readMarketView(qc);
  } catch {
    /* the website API failed: strategy listings only, the status line says so */
  }
  const now = Math.floor(Date.now() / 1000);
  for (const l of market?.view?.rows ?? []) {
    if (l.endTime !== 0 && l.endTime <= now) continue;
    const id = BigInt(l.id);
    if (l.score != null && !known.has(id)) known.set(id, BigInt(l.score));
    listings.push({ id, price: BigInt(l.price), source: "opensea", params: "0x", orderHash: l.hash });
  }
  return { listings, known, market };
}

/** Scores for `ids`: the known ones first, the indexer's credit table next, the chain for the rest. */
export async function scoresFor(c: Client, ids: bigint[], known: Map<bigint, bigint>): Promise<Map<bigint, bigint>> {
  if (getIxMode() === "ix") {
    try {
      for (const [id, s] of await fetchScoresIx(ids.filter((id) => !known.has(id) && !scoreCache.has(id)))) known.set(id, s);
    } catch {
      /* scores are read from the chain below */
    }
  }
  return scoresOf(c, ids, known);
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
  const paused = useSnapshot().data?.paused ?? false;
  const { openConnectModal } = useConnectModal();
  const { run, pending, err } = useTx();
  const [dropped, setDropped] = useState<{ block?: bigint; keys: string[] }>({ keys: [] });
  const [done, setDone] = useState<{ id: bigint; hash: `0x${string}` }>();

  const live = dropped.block === block ? dropped.keys : [];
  const available = <T extends Listing>(list: T[]) => paused ? [] : list.filter((l) => !live.includes(keyOf(l)));

  // the confirmation stays 20 s
  useEffect(() => {
    if (!done) return;
    const t = setTimeout(() => setDone(undefined), 20_000);
    return () => clearTimeout(t);
  }, [done]);

  const buy = (candidates: Priced[]) => {
    if (paused) return;
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
