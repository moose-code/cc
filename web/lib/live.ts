"use client";

// On-chain reads shared by the credits, compose, sell and statement pages.
// Hooks read nothing and return empty data while no engine is configured.

import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { numberToHex, type ContractFunctionReturnType } from "viem";
import { addresses, engineDeployed } from "./config";
import { coreAbi, coreLensAbi } from "./abis";

export type Snapshot = ContractFunctionReturnType<typeof coreLensAbi, "view", "snapshot">;

export const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;
const PILE_PAGE = 200n; // ponytail: first 200 pile credits only, page with pilePage(startAfter) if the pile grows past it

// Chain time: the latest block's timestamp, run forward by the wall seconds
// since that block was first seen. Every countdown and "ago" label reads this,
// so a chain whose clock is ahead of the browser's (local anvil after time
// warps) shows the times the contracts use. Wall clock until the first block is read.
let blockSeen: { n: bigint; ts: number; at: number } | undefined;

// The one head poll of the app: the latest block, read every 12 s. The scan, the
// market and the footer key off it. react-query skips the interval while the tab is
// hidden, and staleTime keeps focus refetches inside the 12 s window from sending.
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

// lens.snapshot(). undefined until loaded.
export function useSnapshot() {
  const client = usePublicClient();
  return useQuery<Snapshot | undefined>({
    queryKey: ["snapshot"],
    enabled: engineDeployed,
    refetchInterval: 15000,
    queryFn: async () => {
      if (!client || !addresses.coreLens) return undefined;
      return client.readContract({
        address: addresses.coreLens,
        abi: coreLensAbi,
        functionName: "snapshot",
      });
    },
  });
}

export interface PileCredit {
  id: number;
  cost: bigint; // wei the engine paid
  acquiredAt: number; // unix seconds
  price: bigint; // controller credit price now, 0 while the sale is off
  choosable: boolean; // lens.choosable(id): in the pile and past its window
}

export interface Pile {
  items: PileCredit[];
  saleOn: boolean;
  window: number; // seconds
}

const EMPTY_PILE: Pile = { items: [], saleOn: false, window: 0 };

export function usePile() {
  const client = usePublicClient();
  const snap = useSnapshot();
  const s = snap.data;
  const q = useQuery<Pile>({
    queryKey: ["pile", s?.pileSize?.toString(), s?.creditSaleOn],
    enabled: Boolean(s),
    refetchInterval: 15000,
    queryFn: async (): Promise<Pile> => {
      if (!client || !s || !addresses.core || !addresses.coreLens) return EMPTY_PILE;
      const core = addresses.core;
      const lens = addresses.coreLens;
      const ids = await client.readContract({
        address: core,
        abi: coreAbi,
        functionName: "pilePage",
        args: [0n, PILE_PAGE],
      });
      const mc = { allowFailure: false, multicallAddress: MULTICALL3 } as const;
      const [info, choosable, price] = await Promise.all([
        client.multicall({
          ...mc,
          contracts: ids.map((id) => ({ address: core, abi: coreAbi, functionName: "creditInfo", args: [id] }) as const),
        }),
        client.multicall({
          ...mc,
          contracts: ids.map((id) => ({ address: lens, abi: coreLensAbi, functionName: "choosable", args: [id] }) as const),
        }),
        s.creditSaleOn
          ? client.multicall({
              ...mc,
              contracts: ids.map((id) => ({ address: lens, abi: coreLensAbi, functionName: "creditPriceOf", args: [id] }) as const),
            })
          : Promise.resolve(ids.map(() => 0n)),
      ]);
      return {
        saleOn: s.creditSaleOn,
        window: Number(s.creditWindow),
        items: ids.map((id, i) => ({
          id: Number(id),
          cost: info[i][1],
          acquiredAt: Number(info[i][2]),
          price: price[i],
          choosable: choosable[i],
        })),
      };
    },
  });
  // empty until the first read lands
  return { ...q, data: q.data ?? EMPTY_PILE };
}

// RateStore.SLOT: Anchor { lastFillRate, minuteStartRate, minuteBucket (uint64), ... }
const RATE_SLOT = 0x4e200413f073f368n;

// Total eth Core.sellForEth pays for n credits sold in one call at chain time
// `now`, replaying the contract's loop: each credit pays min(rate state, pot),
// then the state falls dropPerCreditBps, held at or above dropFloorBps of the
// state at the first fill of the minute (CoreLib.drop). Reads ethPrice (rate
// state before the pot clamp), ethPot, settings and the minute anchor.
export async function sellQuote(client: NonNullable<ReturnType<typeof usePublicClient>>, n: number, now: number): Promise<bigint> {
  const core = addresses.core!;
  const read = (functionName: "ethPrice" | "ethPot") => client.readContract({ address: core, abi: coreAbi, functionName });
  const slot = (i: bigint) => client.getStorageAt({ address: core, slot: numberToHex(RATE_SLOT + i, { size: 32 }) });
  const [st, price, pot, startWord, bucketWord] = await Promise.all([
    client.readContract({ address: core, abi: coreAbi, functionName: "settings" }),
    read("ethPrice"),
    read("ethPot"),
    slot(1n),
    slot(2n),
  ]);
  const drop = BigInt(st.dropPerCreditBps);
  const floorBps = BigInt(st.dropFloorBps);
  const nowBucket = BigInt(Math.floor(now / 60));
  let start = BigInt(startWord ?? "0x0");
  let bucket = BigInt(bucketWord ?? "0x0") & ((1n << 64n) - 1n);
  let r = price;
  let left = pot;
  let total = 0n;
  for (let i = 0; i < n; i++) {
    const x = r < left ? r : left;
    total += x;
    left -= x;
    if (bucket !== nowBucket || r < (start * floorBps) / 10000n) {
      bucket = nowBucket;
      start = r;
    }
    const dropped = (r * (10000n - drop)) / 10000n;
    const floor = (start * floorBps) / 10000n;
    r = dropped > floor ? dropped : floor;
  }
  return total;
}

// sellQuote for n credits, refreshed with the chain clock's minute.
export function useSellQuote(n: number, now: number) {
  const client = usePublicClient();
  const minute = Math.floor(now / 60);
  return useQuery<bigint | undefined>({
    queryKey: ["sell-quote", n, minute],
    enabled: engineDeployed && n > 0,
    refetchInterval: 15000,
    queryFn: () => sellQuote(client!, n, now),
  });
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
