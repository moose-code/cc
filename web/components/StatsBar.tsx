"use client";

import { useStats } from "@/lib/engine";
import { commas } from "@/lib/format";

// Subtle utility bar under the header: the engine's running totals.
export function StatsBar() {
  const { data: s } = useStats();
  return (
    <div className="statsbar">
      <Stat label="credits bought" value={commas(s.creditsBought)} />
      <Stat label="statements" value={commas(s.statements)} />
      <Stat
        label="eth into credits"
        value={s.ethIntoCredits.toLocaleString("en-US", {
          maximumFractionDigits: 1,
        })}
      />
      <Stat label="cc burned" value={commas(s.ccBurned)} />
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="stat">
      <span className="label">{label}</span>
      <span className="value">{value}</span>
    </div>
  );
}
