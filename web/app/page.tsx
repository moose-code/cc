"use client";

import { useEffect, useState } from "react";
import { EngineFeed, EngineProgress, PotRow } from "@/components/EngineFeed";
import { Flywheel } from "@/components/Flywheel";
import { StatsBar } from "@/components/StatsBar";
import { TradeDock } from "@/components/TradeDock";
import { TradePanel } from "@/components/TradePanel";
import { engineDeployed } from "@/lib/config";
import { useCoinLive } from "@/lib/live";

// At 860px and below the home is one scroll (points, stats, cycle, pot, next statement, ledger; order set in
// globals.css) and the trade panel opens from the docked bar as a bottom sheet; wider layouts ignore the sheet state.
export default function Page() {
  const [sheet, setSheet] = useState(false);
  const [pick, setPick] = useState<{ side: "buy" | "sell" }>();
  const live = useCoinLive();
  useEffect(() => {
    if (!sheet) return;
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setSheet(false);
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [sheet]);
  const prelaunch = !engineDeployed || live === false;
  return (
    <div className="home" data-sheet={sheet ? "open" : undefined}>
      {prelaunch && (
        <div className="prelaunch-bar">
          <div className="prelaunch-message">
            <i className="mark m" aria-hidden />
            <strong>pre-launch</strong>
            <span>$CC is not deployed yet. the engine starts once trading opens.</span>
          </div>
          <span>trading opens soon</span>
        </div>
      )}
      <Flywheel />
      <div className="home-body">
        <StatsBar />
        <EngineFeed />
        <div className="rail">
          <PotRow />
          <EngineProgress />
          <div className="sheet-scrim" aria-hidden onClick={() => setSheet(false)} />
          <div className="sheet" role={sheet ? "dialog" : undefined} aria-label={sheet ? "trade $CC" : undefined}>
            <button className="sheet-grab" aria-label="close" onClick={() => setSheet(false)} />
            <TradePanel pick={pick} />
          </div>
        </div>
      </div>
      <TradeDock
        open={(side) => {
          setPick({ side });
          setSheet(true);
        }}
      />
    </div>
  );
}
