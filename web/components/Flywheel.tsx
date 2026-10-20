"use client";

import { Fragment } from "react";
import { engineDeployed, STATEMENT_SIZE } from "@/lib/config";
import { useFeed, useStats } from "@/lib/data";
import { useSnapshot } from "@/lib/live";
import { commas } from "@/lib/format";
import { CreditTile } from "./Tiles";
import { Tween } from "./EngineFeed";
import { Sk } from "./Skeleton";

// bps as a percent, up to two decimals: 900 -> "9", 990 -> "9.9"
const pct = (bps: number) => (bps / 100).toLocaleString("en-US", { maximumFractionDigits: 2 });

const Arrow = ({ n }: { n: number }) => (
  <div className="fw-arr" style={{ "--n": n } as React.CSSProperties} aria-hidden>
    <svg viewBox="0 0 56 8" preserveAspectRatio="none">
      <path d="M0 4h49" />
      <path d="M49 0.5 56 4 49 7.5z" className="fw-head" />
    </svg>
  </div>
);

// Engine explainer band: five steps with live values, then the split of a statement sale under steps 02 to 05: a
// bracket back up into the pot and a bar in proportion to the live split. The left column shares its width with the
// first two stat cells (see .home in globals.css).
// TODO: "full mechanics" link; the app has no mechanics page to point at.
export function Flywheel() {
  const { data: snap } = useSnapshot();
  const { data: stats } = useStats();
  const { events: latest, loading: feedLoading } = useFeed("credits", 1);
  // until the snapshot answers the live figures are skeletons; the split bar keeps its row, so nothing below moves.
  // The pot shown is the spendable room, the pot less the processing reserve
  const pot = snap ? <Tween wei={snap.potRoom} /> : engineDeployed ? <Sk w="6ch" /> : "—";
  const wait = (w: string) => (engineDeployed ? <Sk w={w} /> : "—");

  const creditId = latest.find((e) => e.tile?.kind === "credit")?.tile?.id;
  const filled = snap ? Number(snap.pileSize % BigInt(STATEMENT_SIZE)) : 0;
  // split of a statement sale after the artist and operator cuts, in bps
  const split = snap ? { buyback: snap.settings.saleToBuybackBps, pot: 10000 - snap.settings.saleToBuybackBps } : undefined;
  const potPct = split ? <span className="fx-in">{pct(split.pot)}%</span> : wait("3ch");
  const burnPct = split ? <span className="fx-in">{pct(split.buyback)}%</span> : wait("3ch");
  // the bar's columns follow the live split; until it is read they hold the default 3 : 1
  const cols = split ? `${split.pot}fr ${split.buyback}fr` : "3fr 1fr";

  const steps = [
    {
      title: "trade $CC",
      line: "a share of every trade goes to the engine",
      glyph: (
        <svg className="fw-bars" viewBox="0 0 36 36" aria-hidden>
          {[14, 22, 10, 26, 34].map((h, i) => (
            <g key={i}>
              <rect x={i * 8} y={36 - h} width="4" height={h} className="b" />
              <rect x={i * 8} y={36 - h} width="4" height="3" className="cap" />
            </g>
          ))}
        </svg>
      ),
    },
    {
      title: "the pot",
      line: (
        <>
          fees collect here
          <span className="fw-mpot">
            {" · "}
            <b>{pot} ETH</b>
          </span>
        </>
      ),
      glyph: (
        <span className="fw-chip">
          {pot}
          <small>ETH</small>
        </span>
      ),
    },
    {
      title: "buy credits",
      line: "a standing bid, priced by credit rating",
      glyph: (
        <span className="fw-thumb">{creditId != null ? <CreditTile id={creditId} /> : feedLoading && <Sk block w="100%" h="100%" />}</span>
      ),
    },
    {
      title: "compose",
      line: `${STATEMENT_SIZE} credits make one statement`,
      glyph: (
        <span className={`fw-cells${snap || !engineDeployed ? "" : " pulse"}`} aria-hidden>
          {Array.from({ length: STATEMENT_SIZE }, (_, i) => (
            <i key={i} className={i < filled ? "on" : undefined} />
          ))}
        </span>
      ),
    },
    {
      title: "sell",
      line: "statements are listed for ETH",
      glyph: (
        <svg className="fw-ladder" viewBox="0 0 36 36" aria-hidden>
          {[36, 30, 20, 12].map((w, i) => (
            <rect key={i} x="0" y={i * 9} width={w} height="4" className={i === 1 ? "on" : undefined} />
          ))}
        </svg>
      ),
    },
  ];

  return (
    <section className="fw" aria-label="how the engine works">
      <div className="fw-intro">
        <h2>Credit Cycle</h2>
        <div className="fw-lines">
          <p className="lead">every $CC trade funds an onchain collector</p>
          <p>the engine acquires Credits at a standing bid, then combines every {STATEMENT_SIZE} into a Statement</p>
          <p>
            {potPct} of Statement sale proceeds fund more acquisitions, while {burnPct} buys and burns $CC
          </p>
        </div>
      </div>
      <div className="fw-steps">
        {steps.map((s, i) => (
          <Fragment key={s.title}>
            {i > 0 && <Arrow n={i} />}
            <div className="fw-step" style={{ "--n": i + 1 } as React.CSSProperties}>
              <div className="fw-glyph">{s.glyph}</div>
              <div className="fw-text">
                <div className="fw-title">
                  <span>{`0${i + 1}`}</span> {s.title}
                </div>
                <div className="fw-line">{s.line}</div>
              </div>
            </div>
          </Fragment>
        ))}
        <div className="fw-loop">
          <div className="fw-bracket" aria-hidden />
          <div className="fw-bar" style={{ gridTemplateColumns: cols }}>
            <div className="pot">
              <b>{potPct}</b>
              <span>
                back to the pot<span className="wide-only"> · funds more acquisitions</span>
              </span>
            </div>
            {split?.buyback !== 0 && (
              <div className="burn">
                <b>{burnPct}</b>
                <span>
                  <span className="wide-only">buys and </span>burns $CC
                </span>
              </div>
            )}
          </div>
          <div className="fw-cap">
            <span>split of each statement sale, after artist and operator cuts</span>
            <span className="wide-only">
              {stats ? <span className="fx-in">{commas(stats.ccBurned)}</span> : wait("4ch")} $CC burned so far
            </span>
          </div>
        </div>
      </div>
    </section>
  );
}
