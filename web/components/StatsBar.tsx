"use client";

import { usePathname } from "next/navigation";
import { useStats, STATEMENT_SIZE } from "@/lib/engine";
import { engineDeployed, LAUNCH_SUPPLY_CC } from "@/lib/config";
import { commas, eth } from "@/lib/format";
import { Track, Tween, useEngineGauge } from "./Gauge";

// Utility bar under the header: what the engine holds now and what it has done.
// On the desktop home page the swap panel carries pot, next credit and next statement
// (class `engine`), so the bar hides them there.
export function StatsBar() {
  const { data: s } = useStats();
  const g = useEngineGauge();
  const home = usePathname() === "/";
  if (!engineDeployed) return null;
  const burnedPct = (s.ccBurned / LAUNCH_SUPPLY_CC) * 100;
  return (
    <div className={`statsbar${home ? " home" : ""}`}>
      <Stat label="pot" engine>
        <Tween wei={g.pot} /> eth
      </Stat>
      <Stat label="next credit" engine title={`avg bid ${eth(g.bid)} eth; each credit's own bid scales with its score`}>
        <Track pct={g.creditPct} kind="credit" />
        {commas(g.creditPct)}%
      </Stat>
      <Stat label="next statement" engine>
        <Track pct={(g.ready / STATEMENT_SIZE) * 100} kind="statement" />
        {g.ready}/{STATEMENT_SIZE}
      </Stat>
      <Stat label="credits bought">{commas(s.creditsEth + s.creditsBalance + s.creditsListing)}</Stat>
      <Stat label="statements sold">{commas(s.sold)}</Stat>
      <Stat label="cc burned">
        {commas(s.ccBurned)} <span className="sub">{commas(burnedPct, 2)}%</span>
      </Stat>
    </div>
  );
}

function Stat({ label, title, engine, children }: { label: string; title?: string; engine?: boolean; children: React.ReactNode }) {
  return (
    <div className={`stat${engine ? " engine" : ""}`} title={title}>
      <span className="label">{label}</span>
      <span className="value">{children}</span>
    </div>
  );
}
