"use client";

// Listing acquisition through Core.buyListing (owner decision 134). Both venues and their known immutable scores
// come from the keeper's cached market view through the website API. Purchases still fetch prepared fulfillment
// and simulate the current chain call before sending.

import { useEffect, useState } from "react";
import type { QueryClient } from "@tanstack/react-query";
import { useAccount, usePublicClient } from "wagmi";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { type Address } from "viem";
import { core, strategyAdapter, seaportAdapter } from "./config";
import { coreAbi } from "./abis";
import { creditScores, useSnapshot } from "./live";
import { fetchScoresIx, getIxMode } from "./indexer";
import { readMarketView, type MarketOut } from "./market-view";
import { useTx } from "./tx";
import { preparedForAcquire, type Listing, type Priced, type SpendRoom, type StrategyReadStatus } from "./acquire";

type Client = NonNullable<ReturnType<typeof usePublicClient>>;
const MAX_SCORE_READS = 600;
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

/** Both venues from the keeper's last published catalog; gathering never starts a visitor's chain-history scan. */
export async function gatherListings(qc: QueryClient): Promise<{ listings: Listing[]; known: Map<bigint, bigint>; market?: MarketOut; strategyStatus: StrategyReadStatus }> {
  const market = await readMarketView(qc);
  const view = market.available ? market.view : undefined;
  const listings: Listing[] = [];
  const known = new Map<bigint, bigint>();
  for (const r of view?.strategy.rows ?? []) {
    const id = BigInt(r.id);
    listings.push({ id, price: BigInt(r.price), source: "strategy", params: "0x" });
    if (r.score != null) known.set(id, BigInt(r.score));
  }
  const now = Math.floor(Date.now() / 1000);
  for (const l of view?.rows ?? []) {
    if (l.endTime !== 0 && l.endTime <= now) continue;
    const id = BigInt(l.id);
    if (l.score != null && !known.has(id)) known.set(id, BigInt(l.score));
    listings.push({ id, price: BigInt(l.price), source: "opensea", params: "0x", orderHash: l.hash, prepared: l.signed });
  }
  const strategy = view?.strategy;
  return { listings, known, market, strategyStatus: {
    pending: !strategy?.publishedAt,
    publishedAt: strategy?.publishedAt,
    error: !view ? "CreditStrategy listings unavailable: keeper view unavailable."
      : strategy?.lastFailure && strategy.lastFailure.at > strategy.publishedAt ? "CreditStrategy refresh failed; showing its last published rows." : undefined,
  } };
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
 * Core.buyListing for the first candidate that simulates, or sequentially for selected OpenSea bulk candidates.
 * A candidate that reverts is dropped for the block. OpenSea fulfillment is fetched from the route before simulation.
 * Shared by the header button and the /listings rows.
 */
export function useAcquireTx(block: bigint | undefined) {
  const { address } = useAccount();
  const client = usePublicClient();
  const paused = useSnapshot().data?.paused ?? false;
  const { openConnectModal } = useConnectModal();
  const { run, pending, err } = useTx();
  const [dropped, setDropped] = useState<{ block?: bigint; keys: string[] }>({ keys: [] });
  const [done, setDone] = useState<{ id: bigint; hash: `0x${string}`; count: number; target: number }>();

  const live = dropped.block === block ? dropped.keys : [];
  const available = <T extends Listing>(list: T[]) => paused ? [] : list.filter((l) => preparedForAcquire(l) && !live.includes(keyOf(l)));

  // the confirmation stays 20 s
  useEffect(() => {
    if (!done) return;
    const t = setTimeout(() => setDone(undefined), 20_000);
    return () => clearTimeout(t);
  }, [done]);

  const purchase = (candidates: Priced[], target: number, bulk: boolean) => {
    if (paused) return;
    if (!address) return openConnectModal?.();
    setDone(undefined);
    return run(async (write) => {
      const bad: string[] = [];
      let count = 0;
      try {
        const choices = available(candidates);
        if (bulk && choices.length < target) throw new Error("selected listings are no longer available; refresh and try again");
        for (let l of bulk ? choices.slice(0, target) : choices) {
          const shownPrice = l.price;
          const candidateKey = keyOf(l);
          if (l.source === "opensea" && l.params === "0x") {
            try {
              const f = (await (await fetch(`/api/listings?fulfill=${l.orderHash}`)).json()) as { price?: string; params?: `0x${string}` };
              if (!f.params || !f.price) throw new Error("no fulfillment");
              l = { ...l, price: BigInt(f.price), params: f.params };
            } catch {
              bad.push(candidateKey);
              if (bulk) throw new Error(`stopped after ${count} of ${target}: fulfillment unavailable`);
              continue;
            }
          }
          if (bulk) {
            if (l.source !== "opensea") throw new Error("bulk acquire supports OpenSea listings only");
            if (l.price > shownPrice) {
              bad.push(candidateKey);
              throw new Error(`stopped after ${count} of ${target}: ask changed; refresh and try again`);
            }
          }
          const req = { address: core!, abi: coreAbi, functionName: "buyListing", args: [adapterOf(l), l.id, l.params] } as const;
          try {
            await client!.simulateContract({ ...req, account: address });
          } catch {
            bad.push(candidateKey);
            if (bulk) throw new Error(`stopped after ${count} of ${target}: listing no longer clears`);
            continue;
          }
          const hash = await write(req);
          count++;
          setDone({ id: l.id, hash, count, target });
          if (count === target) return;
        }
        throw new Error(bulk ? `stopped after ${count} of ${target}: listings unavailable` : "no listing available");
      } finally {
        if (bad.length) setDropped((d) => ({ block, keys: [...(d.block === block ? d.keys : []), ...bad] }));
      }
    }, Array.from({ length: target }, (_, i) => ({ label: bulk ? `acquire ${i + 1} of ${target}` : "acquire" })));
  };
  const buy = (candidates: Priced[]) => purchase(candidates, 1, false);
  const buyMany = (candidates: Priced[]) => purchase(candidates, candidates.length, true);
  return { buy, buyMany, available, pending, err, done };
}
