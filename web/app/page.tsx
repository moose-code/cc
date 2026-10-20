"use client";

import { useState } from "react";
import { EngineFeed, EngineProgress } from "@/components/EngineFeed";
import { Flywheel } from "@/components/Flywheel";
import { StatsBar } from "@/components/StatsBar";
import { TradePanel } from "@/components/TradePanel";
import { engineDeployed } from "@/lib/config";
import { useCoinLive } from "@/lib/live";

const TABS = ["ledger", "trade", "process"] as const;

// At 860px and below the home sections are shown one at a time (see .home-tabs
// in globals.css); wider layouts ignore the tab state.
export default function Page() {
  const [tab, setTab] = useState<(typeof TABS)[number]>("ledger");
  const live = useCoinLive();
  const prelaunch = !engineDeployed || live === false;
  return (
    <div className="home" data-tab={tab}>
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
      <div className="home-tabs" role="tablist">
        {TABS.map((t) => (
          <button key={t} role="tab" aria-selected={t === tab} onClick={() => setTab(t)}>
            {t}
          </button>
        ))}
      </div>
      <Flywheel />
      <div className="home-body">
        <StatsBar />
        <EngineFeed />
        <div className="rail">
          <EngineProgress />
          <TradePanel />
        </div>
      </div>
    </div>
  );
}
