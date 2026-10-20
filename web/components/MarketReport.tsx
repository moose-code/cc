"use client";

import { Sk } from "./Skeleton";
import { eth } from "@/lib/format";
import type { MarketReport as Report } from "@/lib/data";

// One-decimal percent with its sign: "+4.2%", "−1.0%".
export const pct1 = (n: number) => `${n >= 0 ? "+" : "−"}${Math.abs(n).toFixed(1)}%`;

// The credits market report above the credits grid: per rating band, the median the engine paid over the last 7 days
// (with the change against the 7 days before and how many it bought), then the lowest ask now, the engine's own and the
// market's (OpenSea and CreditStrategy). A band is a filter for the grid; picking it again clears it. lib/market-report.ts
// holds the bands.
export function MarketReport({
  report,
  engineAsks,
  engineLoading,
  marketAsks,
  marketLoading,
  active,
  onPick,
}: {
  report: Report;
  engineAsks: Map<number, bigint>; // band key to the lowest price of a held credit
  engineLoading: boolean;
  marketAsks: Map<number, bigint>; // band key to the lowest OpenSea or CreditStrategy ask
  marketLoading: boolean;
  active?: number;
  onPick: (band?: number) => void;
}) {
  const { bands, loading, basis } = report;
  const ask = (wait: boolean, v?: bigint) => (wait ? <Sk w="6ch" /> : <span className="fx-in">{v != null ? eth(v) : "—"}</span>);
  return (
    <section className="mkt" aria-label="credits market report">
      <div className="mkt-intro">
        <div className="label">market · {basis === "week" ? "7d" : "latest 200"}</div>
        <p>median the engine paid, and the lowest asks now: the engine&apos;s and the market&apos;s. pick a band to filter.</p>
      </div>
      {bands.map((r) => {
        const on = active === r.band.key;
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
                  {r.sales} bought
                </span>
              )}
            </span>
            <span className="mkt-ask mkt-ask-top">
              <span>engine</span>
              {ask(engineLoading, engineAsks.get(r.band.key))}
            </span>
            <span className="mkt-ask">
              <span>market</span>
              {ask(marketLoading, marketAsks.get(r.band.key))}
            </span>
          </button>
        );
      })}
    </section>
  );
}
