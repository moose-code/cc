"use client";

import type { ReactNode } from "react";
import { formatUnits } from "viem";
import { useStats } from "@/lib/data";
import { useBalanceToken, useSnapshot } from "@/lib/live";
import { engineDeployed, STATEMENT_SIZE } from "@/lib/config";
import { BALANCE_SYMBOL, commas, eth } from "@/lib/format";
import { Tween } from "./EngineFeed";
import { Sk, SkLines } from "./Skeleton";

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
  // a figure not read yet is a skeleton and each sub line keeps its row, so the cells do not grow when data arrives
  // without an engine nothing loads: values read as a dash and the sub lines are left out
  const wait = engineDeployed ? <Sk w="4ch" /> : "—";
  const sub = (ready: boolean, text: ReactNode, w = "10ch") =>
    engineDeployed && <small>{ready ? <span className="fx-in">{text}</span> : <Sk w={w} />}</small>;
  return (
    <div className="stats">
      <Cell ink="m" label="credits held">
        {on ? <span className="fx-in">{commas(Number(snap.pileSize))}</span> : wait}
        {sub(on && !!s, s && `${commas(s.composed * STATEMENT_SIZE)} composed`)}
      </Cell>
      <Cell ink="y" label="statements held">
        {on ? <span className="fx-in">{commas(snap.held.length)}</span> : wait}
        {sub(on && !!s, s && `${commas(s.composed)} created`)}
      </Cell>
      <Cell ink="c" label={BALANCE_SYMBOL}>
        {!on ? wait : snap.balanceOn ? <span className="fx-in">{balance}</span> : <span className="stat-wait fx-in">awaiting deployment</span>}
      </Cell>
      <Cell ink="k" label="$CC burned">
        {engineDeployed && s ? <span className="fx-in">{commas(s.ccBurned)}</span> : wait}
        {sub(engineDeployed && !!s, `${commas(burnedPct, 2)}%`, "4ch")}
      </Cell>
      <Cell ink="pot" label="pot">
        {on ? <Tween wei={snap.potWithPending} /> : engineDeployed ? <Sk w="7ch" /> : "—"}
        {/* the room and reserve line wraps to two lines in the pot cell; its skeleton holds both */}
        {on ? (
          <small className="fx-in">
            ETH · {eth(snap.potRoom)} buying room · {eth(snap.reserve)} reserved
          </small>
        ) : (
          engineDeployed && (
            <small>
              <SkLines n={2} w="16ch" />
            </small>
          )
        )}
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
