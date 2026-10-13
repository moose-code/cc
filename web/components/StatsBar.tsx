"use client";

import { useStats } from "@/lib/engine";
import { engineDeployed } from "@/lib/config";
import { commas } from "@/lib/format";

// Subtle utility bar under the header: the engine's running totals.
export function StatsBar() {
  const { data: s } = useStats();
  return (
    <div className="statsbar">
      <Stat label="credits bought" value={engineDeployed ? commas(s.creditsBought) : "—"} />
      <Stat label="statements" value={engineDeployed ? commas(s.statements) : "—"} />
      <Stat
        label="eth into credits"
        value={
          engineDeployed
            ? s.ethIntoCredits.toLocaleString("en-US", { maximumFractionDigits: 1 })
            : "—"
        }
      />
      <Stat label="cc burned" value={engineDeployed ? commas(s.ccBurned) : "—"} />
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
