"use client";

// On-chain reads shared by every page: viem multicalls over the views of
// docs/INTEGRATION.md section 2. Hooks read nothing and return empty data while
// no engine is configured.

import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { numberToHex, parseAbi, zeroAddress, type Address } from "viem";
import { core, credits, engineDeployed } from "./config";
import { controllerAbi, coreAbi } from "./abis";
import { replayBalance, replayEth } from "./sell";

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

export async function readSnapshot(client: Client, coreAddr: Address) {
  const c = { address: coreAddr, abi: coreAbi } as const;
  const [
    ethRate,
    ethPrice,
    floorRate,
    ethPot,
    ethToBuyback,
    ethRedeemBurn,
    balancePot,
    payeeOwed,
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
  ] = await client.multicall({
    ...mc,
    allowFailure: false,
    contracts: [
      { ...c, functionName: "ethRate" },
      { ...c, functionName: "ethPrice" },
      { ...c, functionName: "floorRate" },
      { ...c, functionName: "ethPot" },
      { ...c, functionName: "ethToBuyback" },
      { ...c, functionName: "ethRedeemBurn" },
      { ...c, functionName: "balancePot" },
      { ...c, functionName: "payeeOwed" },
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
    ] as const,
  });
  // ethPot plus the share of the unbooked fee income that the next Core._book adds (Core._income, _split)
  const income = coreEth > ethPot + ethToBuyback + ethRedeemBurn + payeeOwed ? coreEth - (ethPot + ethToBuyback + ethRedeemBurn + payeeOwed) : 0n;
  const toPayee = payeeOn ? (income * BigInt(settings.payeePpm)) / 1_000_000n : 0n;
  const toRedeemBurn = ((income - toPayee) * BigInt(settings.feeToRedeemBurnBps)) / 10000n;
  const potWithPending = ethPot + income - toPayee - toRedeemBurn;
  const k = { address: controller, abi: controllerAbi } as const;
  const [creditSaleOn, creditWindow, pointRate, royaltyOwed, page] = await client.multicall({
    ...mc,
    allowFailure: false,
    contracts: [
      { ...k, functionName: "creditSaleOn" },
      { ...k, functionName: "creditWindow" },
      { ...k, functionName: "pointRate" },
      { ...k, functionName: "royaltyOwed" },
      { ...k, functionName: "nextPage" },
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
    balancePot,
    payeeOwed,
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
    royaltyOwed,
    page: { ready: page[0], ids: page[1].map(Number), format: page[2] },
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
  price: bigint; // engine price now, 0 while the sale is off
  gross: bigint; // what buyCredit takes: the price plus the royalty
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
  const per = s.creditSaleOn ? 3 : 1;
  const res = await client.multicall({
    ...mc,
    allowFailure: true,
    contracts: ids.flatMap((id, i) => [
      { ...k, functionName: "pastWindow", args: [info[i][2]] } as const,
      ...(s.creditSaleOn
        ? ([
            { ...k, functionName: "creditPrice", args: [id] },
            { ...k, functionName: "grossCreditPrice", args: [id] },
          ] as const)
        : []),
    ]),
  });
  return ids.map((id, i) => ({
    id: Number(id),
    inPile: info[i][0],
    cost: info[i][1],
    acquiredAt: Number(info[i][2]),
    past: val(res[i * per], true),
    price: s.creditSaleOn ? val(res[i * per + 1], 0n) : 0n,
    gross: s.creditSaleOn ? val(res[i * per + 2], 0n) : 0n,
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

// ---- statements -----------------------------------------------------------------

export interface HeldStatement {
  sid: number;
  cost: bigint;
  composedAt: number;
  age: number; // seconds, paused time excluded
  rating: bigint;
  composer: Address;
  price: bigint; // engine price now
  gross: bigint; // what buy takes: the price plus the royalty
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
            { ...k, functionName: "grossPriceOf", args: a },
            { ...k, functionName: "referenceOf", args: a },
            { ...k, functionName: "atFloor", args: a },
          ] as const;
        }),
      });
      const rating = (i: number) => val<bigint>(res[i * 8 + 2], 0n);
      const values = s!.balanceOn
        ? await client!.multicall({
            ...mc,
            allowFailure: true,
            contracts: s!.held.map((_, i) => ({ ...k, functionName: "valueOf", args: [rating(i)] }) as const),
          })
        : [];
      return s!.held.map((sid, i) => {
        const r = (j: number) => res[i * 8 + j];
        const info = val<readonly [boolean, bigint, bigint]>(r(0), [false, 0n, 0n]);
        return {
          sid,
          cost: info[1],
          composedAt: Number(info[2]),
          age: Number(val(r(1), 0n)),
          rating: rating(i),
          composer: val<Address>(r(3), zeroAddress),
          price: val(r(4), 0n),
          gross: val(r(5), 0n),
          reference: val(r(6), 0n),
          atFloor: val(r(7), false),
          value: values[i] ? val(values[i], 0n) : 0n,
        };
      });
    },
  });
  return { ...q, data: q.data ?? [] };
}

// ---- sell quotes ----------------------------------------------------------------

// State.anchor starts at slot 28 (test/CoreLayout.t.sol, src/lib/CoreLib.sol):
// lastFillRate, minuteStartRate, minuteBucket (uint64) + peakTime, peakRate.
const ANCHOR_SLOT = 28n;
const CREDIT_SCORE = "0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7" as const;
const scoreAbi = parseAbi(["function scoreOf(bytes21 seed, uint64 paidAt) view returns (uint256)"]);
const multicallAbi = parseAbi(["function getEthBalance(address a) view returns (uint256)"]);
const moduleAbi = parseAbi(["function unitPerPoint() view returns (uint256)"]);
const seedAbi = parseAbi(["function seedOf(uint256 id) view returns (bytes21)", "function timestampOf(uint256 id) view returns (uint64)"]);

// Eth Core.sellForEth pays for n credits sold in one call at chain time `now`
// (CoreLib.drop and CoreLib.climb replayed in sell.ts). Reads ethPrice,
// floorRate, the pot with the unbooked fee share the first book adds (Core._book,
// _split), the settings and the minute anchor.
export async function sellQuote(client: Client, n: number, now: number): Promise<bigint> {
  const c = { address: core!, abi: coreAbi } as const;
  const word = (i: bigint) => client.getStorageAt({ address: core!, slot: numberToHex(ANCHOR_SLOT + i, { size: 32 }) });
  const [[price, peak, ethPot, toBuyback, redeemBurn, owed, payeeOn, st, held], startWord, bucketWord] = await Promise.all([
    client.multicall({
      ...mc,
      allowFailure: false,
      contracts: [
        { ...c, functionName: "ethPrice" },
        { ...c, functionName: "floorRate" },
        { ...c, functionName: "ethPot" },
        { ...c, functionName: "ethToBuyback" },
        { ...c, functionName: "ethRedeemBurn" },
        { ...c, functionName: "payeeOwed" },
        { ...c, functionName: "payeeOn" },
        { ...c, functionName: "settings" },
        { address: MULTICALL3, abi: multicallAbi, functionName: "getEthBalance", args: [core!] },
      ] as const,
    }),
    word(1n),
    word(2n),
  ]);
  const booked = ethPot + toBuyback + redeemBurn + owed;
  const income = held > booked ? held - booked : 0n;
  const toPayee = payeeOn ? (income * BigInt(st.payeePpm)) / 1_000_000n : 0n;
  const toRedeemBurn = ((income - toPayee) * BigInt(st.feeToRedeemBurnBps)) / 10000n;
  return replayEth(n, {
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
  });
}

// sellQuote for n credits, refreshed with the chain clock's minute.
export function useSellQuote(n: number, now: number) {
  const client = usePublicClient();
  const minute = Math.floor(now / 60);
  return useQuery<bigint | undefined>({
    queryKey: ["sell-quote", n, minute],
    enabled: engineDeployed && Boolean(client) && n > 0,
    refetchInterval: 15000,
    queryFn: () => sellQuote(client!, n, now),
  });
}

// Balance token Core.sellForBalance pays for the credits `ids`: each credit's
// score from the credit score contract times the module's unitPerPoint, less the margin.
export async function balanceQuote(client: Client, ids: bigint[], module: Address, marginBps: number): Promise<bigint> {
  const seeds = await client.multicall({
    ...mc,
    allowFailure: false,
    contracts: ids.flatMap((id) => [
      { address: credits, abi: seedAbi, functionName: "seedOf", args: [id] },
      { address: credits, abi: seedAbi, functionName: "timestampOf", args: [id] },
    ] as const),
  });
  const [unit, scores] = await Promise.all([
    client.readContract({ address: module, abi: moduleAbi, functionName: "unitPerPoint" }),
    client.multicall({
      ...mc,
      allowFailure: false,
      contracts: ids.map((_, i) => ({ address: CREDIT_SCORE, abi: scoreAbi, functionName: "scoreOf", args: [seeds[2 * i] as `0x${string}`, seeds[2 * i + 1] as bigint] }) as const),
    }),
  ]);
  return replayBalance([...scores], unit, BigInt(marginBps));
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
