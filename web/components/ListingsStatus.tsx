"use client";

import { useEffect, useState } from "react";
import type { StrategyReadStatus } from "@/lib/acquire";
import { viewLive, type MarketOut } from "@/lib/market-view";

// Stalled data must become stale even when no new query result arrives.
function useWall(ms = 10000) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), ms);
    return () => clearInterval(t);
  }, [ms]);
  return now;
}

// Keep failures visible without putting keeper diagnostics in the feed.
export function ListingsStatus({ market, strategy, readAt, error, fetching, retry }: { market?: MarketOut; strategy?: StrategyReadStatus; readAt?: number; error?: unknown; fetching: boolean; retry: () => void }) {
  const now = useWall();
  const message = error
    ? readAt ? "could not refresh listings; showing the last view." : "listings unavailable."
    : !readAt ? undefined // the table's skeleton rows show the first read
    : market && !market.available ? "OpenSea listings unavailable."
    : strategy?.error || strategy?.pending ? "some listings are unavailable."
    : market && !viewLive(market, now) ? "listings may be delayed."
    : undefined;
  if (!message) return null;
  return (
    <div className="lstatus" aria-live="polite">
      {message}{" "}
      {Boolean(error) && <button className="linkbtn" onClick={retry} disabled={fetching}>retry</button>}
    </div>
  );
}
