"use client";

import { STATEMENT_SIZE } from "@/lib/config";
import { useNow, useSnapshot, type PileCredit } from "@/lib/live";
import { useBuyRate } from "@/lib/data";
import { composeEta, type Eta } from "@/lib/compose-eta";

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
