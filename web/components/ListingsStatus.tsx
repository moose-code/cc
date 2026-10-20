"use client";

import { useEffect, useState } from "react";
import { viewLines, viewLive, type MarketOut } from "@/lib/market-view";

// Wall clock ticking each second, for "read 12s ago" lines (view times are wall times, not chain times).
function useWall(ms = 1000) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), ms);
    return () => clearInterval(t);
  }, [ms]);
  return now;
}

// The honest state of a listings surface: the market view's coverage, freshness, stream and failure lines, the last
// chain read, and a retry when the read failed. Stale or disconnected data is named as such, never as live.
export function ListingsStatus({ market, readAt, error, fetching, retry }: { market?: MarketOut; readAt?: number; error?: unknown; fetching: boolean; retry: () => void }) {
  const now = useWall();
  const lines = viewLines(market, now);
  const live = viewLive(market, now);
  return (
    <div className="lstatus" aria-live="polite">
      {lines.map((l, i) => (
        <div key={i} className={i === 0 ? undefined : live ? "quiet" : "warn"}>
          {l}
        </div>
      ))}
      <div className={error ? "warn" : "quiet"}>
        {error
          ? `last chain read failed${readAt ? `; showing the read of ${Math.max(0, Math.round((now - readAt) / 1000))}s ago` : ""}. `
          : readAt
            ? `chain read ${Math.max(0, Math.round((now - readAt) / 1000))}s ago${fetching ? ", reading…" : ""}. `
            : fetching
              ? "reading… "
              : ""}
        {(error || !fetching) && (
          <button className="linkbtn" onClick={retry} disabled={fetching}>
            {error ? "retry" : "refresh"}
          </button>
        )}
      </div>
    </div>
  );
}
