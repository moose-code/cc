"use client";

import { Fragment } from "react";
import { engineDeployed, STATEMENT_SIZE } from "@/lib/config";
import { useFeed } from "@/lib/data";
import { useSnapshot } from "@/lib/live";
import { useCcMarket, useHookFeeBps } from "@/lib/market";
import { BALANCE_SYMBOL } from "@/lib/format";
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

// Engine explainer band: five steps with live values and the return line from
// sell or redeem back to the pot. The left column shares its width with the
// first two stat cells (see .home in globals.css).
// TODO: "full mechanics" link; the app has no mechanics page to point at.
export function Flywheel() {
  const { data: snap } = useSnapshot();
  const { events: latest, loading: feedLoading } = useFeed("credits", 1);
  const { market } = useCcMarket();
  const { data: fee } = useHookFeeBps(market);
  // until the snapshot answers the live figures are skeletons; the split line keeps its row, so nothing below moves
  const pot = snap ? <Tween wei={snap.potWithPending} /> : engineDeployed ? <Sk w="6ch" /> : "—";
  const wait = (w: string) => (engineDeployed ? <Sk w={w} /> : "—");
  const balanceOn = !!snap?.balanceOn;

  const creditId = latest.find((e) => e.tile?.kind === "credit")?.tile?.id;
  const filled = snap ? Number(snap.pileSize % BigInt(STATEMENT_SIZE)) : 0;
  // split of a statement sale after the artist and operator cuts, in bps
  const split = snap ? { buyback: snap.settings.saleToBuybackBps, pot: 10000 - snap.settings.saleToBuybackBps } : undefined;

  // the standing engine share; the launch fee window is left out of the explainer. A fee still loading is a skeleton;
  // no pool or a failed read keeps the general wording
  const tradeLine = fee ? (
    `${pct(fee.engineBaseBps)}% of every trade goes to the engine`
  ) : market && fee === undefined ? (
    <>
      <Sk w="5ch" /> of every trade goes to the engine
    </>
  ) : (
    "a share of every trade goes to the engine"
  );

  const steps = [
    {
      title: "trade $CC",
      line: tradeLine,
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
      title: balanceOn ? "sell or redeem" : "sell",
      line: balanceOn
        ? `statements are listed for ETH or redeemed for ${BALANCE_SYMBOL}`
        : "statements are listed for ETH",
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
        <p>
          $CC trades fill the pot. the pot buys Credits, priced by rating, from CreditStrategy, OpenSea or anyone who
          sells. every {STATEMENT_SIZE} become a statement, which {balanceOn ? "sells or redeems" : "sells"} to refill
          the pot.
        </p>
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
        <div className="fw-ret" aria-hidden />
        <div className="fw-ret-end" aria-hidden />
        <div className="fw-split">
          <span>
            <b>{split ? <span className="fx-in">{pct(split.pot)}%</span> : wait("3ch")}</b> of statement sales back to the pot
          </span>
          <i aria-hidden>·</i>
          <span>
            <b>{split ? <span className="fx-in">{pct(split.buyback)}%</span> : wait("3ch")}</b> buys and burns $CC
          </span>
        </div>
      </div>
    </section>
  );
}
