"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { decodeFunctionData, zeroAddress, type Address } from "viem";
import { core, deployBlock, engineDeployed, STATEMENT_SIZE } from "./config";
import { coreAbi, engineEventsAbi, erc20Abi, transferEventAbi } from "./abis";
import { lsGet, lsSet, persistedMap, setAnchor, SCOPE, verifyScope } from "./cache";
import { useHead } from "./live";
import { useIxMode } from "./indexer";
import { emptyStats, processLogs, type BalanceTokenInfo, type ComposeMode, type Scan } from "./events";

export type { FeedEvent, FeedKind, Stats, Scan, CreditEvt, CreditHow, StatementRecord, ComposeMode } from "./events";

export { STATEMENT_SIZE };

type Client = NonNullable<ReturnType<typeof usePublicClient>>;

const EMPTY_SCAN: Scan = { feed: [], stats: emptyStats(), credits: {}, statements: {} };

// ---- block timestamps and compose modes ----------------------------------------

// block number -> timestamp. A mined block's timestamp does not change.
const blockTime = persistedMap<number>("ts");

async function timestampOf(client: Client, n: bigint): Promise<number> {
  await verifyScope(client);
  const cached = blockTime.get(n.toString());
  if (cached != null) return cached;
  const ts = Number((await client.getBlock({ blockNumber: n })).timestamp);
  blockTime.set(n.toString(), ts);
  return ts;
}

// Timestamp of one block, undefined until read.
export function useBlockTs(block?: bigint) {
  const client = usePublicClient();
  return useQuery<number | undefined>({
    queryKey: ["block-ts", block?.toString()],
    enabled: block != null && Boolean(client),
    staleTime: Infinity,
    queryFn: () => timestampOf(client!, block!),
  });
}

// Immutable per transaction: did it call Core.compose or Core.composeChosen directly?
const composeMode = persistedMap<ComposeMode | null>("mode");

async function modeOf(client: Client, hash: string): Promise<ComposeMode | null> {
  const cached = composeMode.get(hash);
  if (cached !== undefined) return cached;
  const t = await client.getTransaction({ hash: hash as `0x${string}` });
  let mode: ComposeMode | null = null;
  if (t.to?.toLowerCase() === core?.toLowerCase()) {
    try {
      const fn = decodeFunctionData({ abi: coreAbi, data: t.input }).functionName;
      mode = fn === "compose" ? "default" : fn === "composeChosen" ? "chosen" : null;
    } catch {
      /* not a compose call */
    }
  }
  composeMode.set(hash, mode);
  return mode;
}

// ---- event scan ------------------------------------------------------------------

// Decoded logs of the Core, every controller the Core has used, the coin burn
// transfers and the balance token payments, kept per source. Each source records
// the first block not yet scanned; a scan reads that block minus RESCAN up to the
// head, in CHUNK block ranges. The state is saved in localStorage so a reload
// resumes where it stopped.
const RESCAN = 12n; // blocks re-read behind the last scanned block (reorg window)
const CHUNK = 5_000n; // blocks per getLogs call
const SCAN_KEY = `${SCOPE}:scan:token-history-v2`;

interface ScanState {
  start: bigint; // first block scanned
  next: Record<string, bigint>; // source -> first block not yet scanned
  logs: Record<string, any[]>; // source -> logs, oldest first
  controllers: Record<string, Address>;
  balance?: BalanceTokenInfo;
}

let state: ScanState | undefined;
let balanceChecked = false;
let saved = { total: -1, head: 0n };
let lastGood: Scan | undefined;
let queue: Promise<unknown> = Promise.resolve();

const slim = (l: any) => ({
  eventName: l.eventName,
  args: l.args,
  address: l.address,
  blockNumber: l.blockNumber,
  blockHash: l.blockHash,
  logIndex: l.logIndex,
  transactionHash: l.transactionHash,
});

// Reads one source from its resume point to the head; returns the logs read.
async function readSource(st: ScanState, src: string, head: bigint, fetch: (from: bigint, to: bigint) => Promise<any[]>) {
  const prev = st.next[src];
  if (prev != null && head < prev) return []; // head unchanged
  const from = prev == null || prev > head + 1n ? st.start : prev > st.start + RESCAN ? prev - RESCAN : st.start;
  const fresh: any[] = [];
  for (let a = from; a <= head; a += CHUNK) fresh.push(...(await fetch(a, a + CHUNK - 1n < head ? a + CHUNK - 1n : head)).map(slim));
  st.logs[src] = [...(st.logs[src] ?? []).filter((l) => l.blockNumber < from), ...fresh];
  st.next[src] = head + 1n;
  return fresh;
}

// The balance token and its decimals, unset while the Core has no module.
async function balanceTokenInfo(client: Client): Promise<BalanceTokenInfo | undefined> {
  const address = await client.readContract({ address: core!, abi: coreAbi, functionName: "balanceToken" });
  if (address === zeroAddress) return undefined;
  const decimals = await client.readContract({ address, abi: erc20Abi, functionName: "decimals" });
  return { address, decimals };
}

async function scanTo(client: Client, head: bigint): Promise<Scan> {
  const coreAddr = core!;
  await verifyScope(client);
  if (!state) {
    const s = lsGet<ScanState>(SCAN_KEY);
    state = s && typeof s.start === "bigint" ? s : { start: deployBlock ?? (head > 50000n ? head - 50000n : 0n), next: {}, logs: {}, controllers: {} };
  }
  const st = state;
  const events = engineEventsAbi as any;

  // the coin is a Core immutable
  const coin = await client.readContract({ address: coreAddr, abi: coreAbi, functionName: "COIN" });
  const [coreFresh] = await Promise.all([
    readSource(st, "core", head, (fromBlock, toBlock) => client.getLogs({ address: coreAddr, events, fromBlock, toBlock })),
    readSource(st, "burn", head, (fromBlock, toBlock) =>
      client.getLogs({ address: coin, event: transferEventAbi[0], args: { from: coreAddr, to: zeroAddress }, fromBlock, toBlock })
    ),
  ]);

  // every controller the Core has used: its own logs carry the sale events
  if (Object.keys(st.controllers).length === 0) {
    const c = await client.readContract({ address: coreAddr, abi: coreAbi, functionName: "controller" });
    st.controllers[c.toLowerCase()] = c;
  }
  for (const l of st.logs.core) if (l.eventName === "ControllerSet") st.controllers[l.args.controller.toLowerCase()] = l.args.controller;
  const ctl = Object.entries(st.controllers);
  await Promise.all(
    ctl.map(([k, address]) => readSource(st, `ctl:${k}`, head, (fromBlock, toBlock) => client.getLogs({ address, events, fromBlock, toBlock })))
  );

  // the balance token changes only through BalanceModuleSet
  if (!balanceChecked || coreFresh.some((l) => l.eventName === "BalanceModuleSet")) {
    st.balance = await balanceTokenInfo(client).catch(() => st.balance);
    balanceChecked = true;
  }

  const logs = [...st.logs.core, ...ctl.flatMap(([k]) => st.logs[`ctl:${k}`] ?? [])].sort((x, y) =>
    x.blockNumber === y.blockNumber ? Number(x.logIndex - y.logIndex) : x.blockNumber < y.blockNumber ? -1 : 1
  );

  // total coin burned by the core
  let burned = 0n;
  for (const b of st.logs.burn ?? []) burned += b.args.value ?? 0n;

  // compose mode per Composed transaction
  const modes = new Map<string, ComposeMode>();
  await Promise.all(
    logs
      .filter((l) => l.eventName === "Composed")
      .map(async (l) => {
        const m = await modeOf(client, l.transactionHash).catch(() => null);
        if (m) modes.set(l.transactionHash, m);
      })
  );
  

  // save when logs were added, else every 300 blocks
  const total = Object.values(st.logs).reduce((n, a) => n + a.length, 0);
  if (total !== saved.total || head - saved.head > 300n) {
    lsSet(SCAN_KEY, st, 2_500_000);
    const last = logs.reduce((m, l) => (m == null || l.blockNumber > m.blockNumber ? l : m), undefined as any);
    if (last?.blockHash) setAnchor(last.blockNumber, last.blockHash);
    saved = { total, head };
  }

  const { stats, credits, statements, rows } = processLogs({ logs, head, burned, modes, balanceToken: st.balance });
  // logs arrive oldest first; the feed is newest first
  return (lastGood = { feed: rows.reverse(), stats, credits, statements, balanceToken: st.balance });
}

// Every row for the feed (newest first), totals and per credit / per statement
// histories over every log. Runs once per new head and reads only the blocks since the last run.
export function useScan() {
  const client = usePublicClient();
  const { data: hd } = useHead();
  const head = hd?.n;
  // the scan is the fallback for the indexer: it runs only while the app is in chain mode (lib/indexer.ts useIxMode)
  const chainMode = useIxMode() === "chain";
  const q = useQuery<Scan>({
    queryKey: ["scan", head?.toString()],
    enabled: engineDeployed && Boolean(head) && chainMode,
    gcTime: 30000,
    placeholderData: (prev) => prev,
    queryFn: () => {
      if (!client || !head) return EMPTY_SCAN;
      const p = queue.then(() => scanTo(client, head)).catch((e) => {
        if (!lastGood) throw e; // no scan yet: the query errors
        return lastGood;
      });
      queue = p.catch(() => undefined);
      return p;
    },
  });
  // ready: a scan has answered (until then data is the empty scan, which must not read as an empty history)
  return { ...q, data: q.data ?? EMPTY_SCAN, ready: q.data !== undefined };
}
