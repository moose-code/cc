"use client";

import { useState } from "react";
import { EngineFeed, EngineProgress } from "@/components/EngineFeed";
import { Flywheel } from "@/components/Flywheel";
import { StatsBar } from "@/components/StatsBar";
import { TradePanel } from "@/components/TradePanel";

const TABS = ["ledger", "trade", "process"] as const;

// At 860px and below the home sections are shown one at a time (see .home-tabs
// in globals.css); wider layouts ignore the tab state.
export default function Page() {
  const [tab, setTab] = useState<(typeof TABS)[number]>("process");
  return (
    <div className="home" data-tab={tab}>
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
