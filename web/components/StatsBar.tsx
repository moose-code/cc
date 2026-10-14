"use client";

import { usePathname } from "next/navigation";
import { formatUnits } from "viem";
import { useScan, STATEMENT_SIZE } from "@/lib/engine";
import { useSnapshot } from "@/lib/live";
import { engineDeployed, LAUNCH_SUPPLY_CC } from "@/lib/config";
import { BALANCE_SYMBOL } from "@/lib/events";
import { commas, eth } from "@/lib/format";
import { Track, Tween, useEngineGauge } from "./Gauge";

// Utility bar under the header: what the engine holds and the $CC it has burned.
// The home page adds pot, next credit and next statement (class `engine`) for narrow screens,
// where the swap column that carries them on desktop is a separate page.
export function StatsBar() {
  const { data: scan } = useScan();
  const { data: snap } = useSnapshot();
  const g = useEngineGauge();
  const home = usePathname() === "/";
  if (!engineDeployed) return null;
  const burned = scan.stats.ccBurned;
  const dec = scan.balanceToken?.decimals;
  return (
    <div className="statsbar">
      {home && (
        <>
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
        </>
      )}
      <Stat label="credits held">{snap ? commas(Number(snap.pileSize)) : "—"}</Stat>
      <Stat label="statements held">{snap ? commas(snap.held.length) : "—"}</Stat>
      <Stat label={BALANCE_SYMBOL}>
        {snap?.balanceOn && dec != null ? commas(Number(formatUnits(snap.balancePot, dec)), 2) : <span className="sub">not live</span>}
      </Stat>
      <Stat label="$CC burned">
        {commas(burned)} <span className="sub">{commas((burned / LAUNCH_SUPPLY_CC) * 100, 2)}%</span>
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
