"use client";

import { statementSaleSplit } from "@/lib/sale-split";
import { Fragment } from "react";
import { useFeed, STATEMENT_SIZE } from "@/lib/engine";
import { useSnapshot } from "@/lib/live";
import { useCcMarket, useHookFeeBps } from "@/lib/market";
import { BALANCE_SYMBOL } from "@/lib/events";
import { CreditTile } from "./Tiles";
import { Tween } from "./EngineFeed";

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
  const { data: feed } = useFeed();
  const { data: fee } = useHookFeeBps(useCcMarket());
  const balanceOn = !!snap?.balanceOn;

  const creditId = feed.find((e) => e.tile?.kind === "credit")?.tile?.id;
  const filled = snap ? Number(snap.pileSize % BigInt(STATEMENT_SIZE)) : 0;
  const split = snap ? statementSaleSplit(snap.settings) : undefined;

  let tradeLine = "a share of every trade goes to the engine";
  if (fee) {
    tradeLine = `${pct(fee.engineBps)}% of every trade goes to the engine`;
    if (fee.active) tradeLine += `, ${pct(fee.engineBaseBps)}% once the opening window ends`;
  }

  const steps = [
    {
      title: "trade $CC",
      line: tradeLine,
      glyph: (
        <svg className="fw-bars" viewBox="0 0 36 36" aria-hidden>
          {[14, 22, 10, 30, 18].map((h, i) => (
            <g key={i}>
              <rect x={i * 8} y={36 - h} width="4" height={h} className="body" />
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
            <b>
              <Tween wei={snap?.potWithPending} /> ETH
            </b>
          </span>
        </>
      ),
      glyph: (
        <span className="fw-chip">
          <Tween wei={snap?.potWithPending} />
          <small>ETH</small>
        </span>
      ),
    },
    {
      title: "buy credits",
      line: "a standing bid, priced by credit rating",
      glyph: (
        <span className="fw-thumb">{creditId != null && <CreditTile id={creditId} />}</span>
      ),
    },
    {
      title: "compose",
      line: `${STATEMENT_SIZE} credits make one statement`,
      glyph: (
        <span className="fw-cells" aria-hidden>
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
        <h2>a machine that collects Credits, funded by $CC trading</h2>
        <p>
          trading fees fill a pot. the pot buys Credits, every {STATEMENT_SIZE} become a statement, and statement
          sales pay the pot back.
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
        {split && (
          <>
            <div className="fw-ret" aria-hidden />
            <div className="fw-ret-end" aria-hidden />
            <div className="fw-split">
              <span>
                <b>{pct(split.pot * 100)}%</b> of statement sales back to the pot
              </span>
              <i aria-hidden>·</i>
              <span>
                <b>{pct(split.buyback * 100)}%</b> buys and burns $CC
              </span>
            </div>
          </>
        )}
      </div>
    </section>
  );
}
