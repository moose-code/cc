"use client";

import { Sk } from "./Skeleton";
import { eth } from "@/lib/format";
import type { MarketReport as Report } from "@/lib/data";

// One-decimal percent with its sign: "+4.2%", "−1.0%".
export const pct1 = (n: number) => `${n >= 0 ? "+" : "−"}${Math.abs(n).toFixed(1)}%`;

// The credits market report above the credits grid: what the engine paid by rating band over the last 7 days (median,
// change against the 7 days before, sales) and the cheapest credit listed now in each band, so a listing reads
// against its band. A band is a filter for the grid; picking it again clears it. lib/market-report.ts holds the bands.
export function MarketReport({
  report,
  listedFrom,
  listedLoading,
  active,
  onPick,
}: {
  report: Report;
  listedFrom: Map<number, bigint>; // band key to the lowest price listed now
  listedLoading: boolean;
  active?: number;
  onPick: (band?: number) => void;
}) {
  const { bands, loading, basis } = report;
  return (
    <section className="mkt" aria-label="credits market report">
      <div className="mkt-intro">
        <div className="label">market · {basis === "week" ? "7d" : "latest 200"}</div>
        <p>what the engine paid, median by rating. pick a band to filter the listings.</p>
      </div>
      {bands.map((r) => {
        const on = active === r.band.key;
        const listed = listedFrom.get(r.band.key);
        return (
          <button
            key={r.band.key}
            className={`mkt-band${on ? " on" : ""}`}
            aria-pressed={on}
            onClick={() => onPick(on ? undefined : r.band.key)}
            title={on ? "show every band" : `show credits rated ${r.band.label}`}
          >
            <span className="label">rating {r.band.label}</span>
            <span className="mkt-median">
              {loading ? (
                <Sk w="6ch" />
              ) : r.median != null ? (
                <span className="fx-in">
                  {eth(r.median)} <small>ETH</small>
                </span>
              ) : (
                "—"
              )}
            </span>
            <span className="mkt-line">
              {loading ? (
                <Sk w="12ch" />
              ) : (
                <span className="fx-in">
                  {r.change != null && `${pct1(r.change)} · `}
                  {r.sales} {r.sales === 1 ? "sale" : "sales"}
                </span>
              )}
            </span>
            <span className="mkt-line">
              {listedLoading ? <Sk w="14ch" /> : <span className="fx-in">{listed != null ? `listed from ${eth(listed)}` : "none listed"}</span>}
            </span>
          </button>
        );
      })}
    </section>
  );
}
