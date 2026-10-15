"use client";

import { useMemo } from "react";
import { STATEMENT_SIZE, useBlockTs, useScan } from "@/lib/engine";
import { useHead, useNow, useSnapshot, type PileCredit } from "@/lib/live";
import { BUY_RATE_WINDOW_S, composeEta, type Eta } from "@/lib/compose-eta";

// Buys per hour over the last BUY_RATE_WINDOW_S, from the scan's bought events (adopted credits are not buys).
// Block timestamps come from the head and the oldest bought event, so the cutoff block is estimated from the
// average block time between them. undefined while those are loading.
export function useBuyRate(): number | undefined {
  const { data: scan } = useScan();
  const { data: head } = useHead();
  const { blocks, oldest } = useMemo(() => {
    const blocks: bigint[] = [];
    for (const evts of Object.values(scan.credits))
      for (const e of evts) if (e.t === "bought" && e.how !== "adopted") blocks.push(e.block);
    const oldest = blocks.reduce<bigint | undefined>((m, b) => (m === undefined || b < m ? b : m), undefined);
    return { blocks, oldest };
  }, [scan.credits]);
  const { data: oldestTs } = useBlockTs(oldest);
  return useMemo(() => {
    if (!head) return undefined;
    if (oldest === undefined) return 0;
    if (oldestTs == null) return undefined;
    const span = Number(head.n - oldest);
    const secPerBlock = span > 0 ? Math.max(1, (head.ts - oldestTs) / span) : 12;
    const cutoff = head.n - BigInt(Math.floor(BUY_RATE_WINDOW_S / secPerBlock));
    const count = blocks.filter((b) => b >= cutoff).length;
    const seconds = Math.min(BUY_RATE_WINDOW_S, Math.max(3600, head.ts - oldestTs));
    return count / (seconds / 3600);
  }, [blocks, oldest, head, oldestTs]);
}

// Compose estimate by queue position in `pile` (oldest first).
export function useComposeEta(pile: PileCredit[], tickMs = 1000) {
  const { data: snap } = useSnapshot();
  const perHour = useBuyRate();
  const now = useNow(tickMs);
  return {
    perHour,
    now,
    at: (index: number): Eta | undefined =>
      snap
        ? composeEta({
            index,
            held: Number(snap.pileSize),
            size: STATEMENT_SIZE,
            windowS: snap.creditSaleOn ? snap.creditWindow : 0,
            now,
            perHour,
            acquiredAt: (i) => pile[i]?.acquiredAt,
          })
        : undefined,
  };
}
