"use client";

import type { ReactNode } from "react";
import { formatUnits } from "viem";
import { useStats } from "@/lib/data";
import { useBalanceToken, useSnapshot } from "@/lib/live";
import { engineDeployed, STATEMENT_SIZE } from "@/lib/config";
import { BALANCE_SYMBOL, commas } from "@/lib/format";
import { Tween } from "./EngineFeed";

const LAUNCH_SUPPLY_CC = 1e9; // the coin's launch supply, 1e27 wei

// Home stats row: credits and statements held by the engine over all ever taken in, the balance token
// held by the engine, $CC burned and the pot. Cell edges: m, y, c, k; the pot is an ink fill.
export function StatsBar() {
  const { data: s } = useStats();
  const { data: snap } = useSnapshot();
  const on = engineDeployed && !!snap;
  const dec = useBalanceToken()?.decimals;
  const balance =
    snap?.balanceOn && snap.balanceAvailable != null && dec != null
      ? commas(Number(formatUnits(snap.balanceAvailable, dec)))
      : "—";
  const burnedPct = s ? (s.ccBurned / LAUNCH_SUPPLY_CC) * 100 : 0;
  return (
    <div className="stats">
      <Cell ink="m" label="credits held">
        {on ? commas(Number(snap.pileSize)) : "—"}
        {on && s && <small>{commas(s.composed * STATEMENT_SIZE)} credits merged</small>}
      </Cell>
      <Cell ink="y" label="statements held">
        {on ? commas(snap.held.length) : "—"}
        {on && s && <small>{commas(s.composed)} statements created</small>}
      </Cell>
      <Cell ink="c" label={BALANCE_SYMBOL}>
        {!on ? "—" : snap.balanceOn ? balance : <span className="stat-wait">waiting deployment</span>}
      </Cell>
      <Cell ink="k" label="$CC burned">
        {engineDeployed && s ? commas(s.ccBurned) : "—"}
        {engineDeployed && s && <small>{commas(burnedPct, 2)}%</small>}
      </Cell>
      <Cell ink="pot" label="pot">
        {on ? <Tween wei={snap.potWithPending} /> : "—"}
        {on && <small>ETH</small>}
      </Cell>
    </div>
  );
}

function Cell({ ink, label, children }: { ink: "c" | "m" | "y" | "k" | "pot"; label: string; children: ReactNode }) {
  return (
    <div className={`stat-cell ink-${ink}`}>
      <span className="label">
        {ink !== "pot" && <i className="mark" />}
        {label}
      </span>
      <span className="value">{children}</span>
    </div>
  );
}
