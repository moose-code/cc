"use client";

import type { ReactNode } from "react";
import { useStats } from "@/lib/data";
import { useBalanceToken, useEngineBalance, usePointsHeld, useSnapshot, useStatements } from "@/lib/live";
import { engineDeployed, STATEMENT_SIZE } from "@/lib/config";
import { BALANCE_SYMBOL, balanceAmount, commas } from "@/lib/format";
import { Sk, SkLines } from "./Skeleton";

const LAUNCH_SUPPLY_CC = 1e9; // the coin's launch supply, 1e27 wei

// Home stats row: credits and statements held by the engine over all ever taken in, $CC bought and burned, the ETH
// statement sales returned to the pot, and the points the engine holds. Cell edges: m, y, k, c; the points panel is an
// ink fill. Points carry no valuation and back nothing a $CC holder can redeem.
export function StatsBar() {
  const { data: s } = useStats();
  const { data: snap } = useSnapshot();
  const pts = usePointsHeld();
  const held = useStatements();
  const balToken = useBalanceToken();
  const engineBal = useEngineBalance();
  // the points in held Statements: each can be redeemed (converted) into $BALANCE through the treasury by anyone
  const waitingPts =
    snap && held.isSuccess && held.data.length === snap.held.length
      ? held.data.reduce((t, st) => t + st.rating, 0n)
      : undefined;
  const on = engineDeployed && !!snap;
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
      <Cell
        ink="k"
        label={
          <>
            $CC <span className="wide-only">bought + </span>burned
          </>
        }
      >
        {engineDeployed && s ? <span className="fx-in">{commas(s.ccBurned)}</span> : wait}
        {sub(engineDeployed && !!s, `${commas(burnedPct, 2)}% of supply`, "8ch")}
      </Cell>
      <Cell ink="c" label="ETH recycled">
        {engineDeployed && s ? <span className="fx-in">{commas(s.ethToPot, 4)}</span> : wait}
        {sub(
          engineDeployed && !!s,
          s && (
            <>
              from {commas(s.potSales)} <span className="wide-only">statement </span>
              {s.potSales === 1 ? "sale" : "sales"}
            </>
          ),
          "12ch"
        )}
      </Cell>
      <div className="stat-cell ink-pts">
        <span className="label">points held by engine</span>
        <span className="value">
          {pts != null ? <span className="fx-in">{commas(Number(pts / 10_000n))}</span> : engineDeployed ? <Sk w="7ch" /> : "—"}
          <small>pts</small>
        </span>
        {on ? (
          <small className="stat-note fx-in">
            {waitingPts != null ? commas(Number(waitingPts / 10_000n)) : <Sk w="5ch" />} pts in{" "}
            {commas(snap.held.length)} statements waiting to be redeemed for {BALANCE_SYMBOL} ·{" "}
            {engineBal != null && balToken ? balanceAmount(engineBal, balToken) : <Sk w="5ch" />} {BALANCE_SYMBOL} held
          </small>
        ) : (
          engineDeployed && (
            <small className="stat-note">
              <SkLines n={2} w="20ch" />
            </small>
          )
        )}
      </div>
    </div>
  );
}

function Cell({ ink, label, children }: { ink: "c" | "m" | "y" | "k"; label: ReactNode; children: ReactNode }) {
  return (
    <div className={`stat-cell ink-${ink}`}>
      <span className="label">
        <i className="mark" />
        <span>{label}</span>
      </span>
      <span className="value">{children}</span>
    </div>
  );
}
