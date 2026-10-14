"use client";

import Link from "next/link";
import { useStats } from "@/lib/engine";
import { useSnapshot } from "@/lib/live";
import { engineDeployed, LAUNCH_SUPPLY_CC } from "@/lib/config";
import { BALANCE_SYMBOL } from "@/lib/events";
import { commas, evmNowAddress } from "@/lib/format";

const SHOW_LIVE = false; // live numbers under each step, off while the copy settles

// 24 by 24 line icons; strokes are currentColor.
const lines = (n: number, a: number, b: number, f: (v: number) => string) =>
  Array.from({ length: n - 1 }, (_, i) => f(a + ((i + 1) * b) / n)).join("");
const ICONS: Record<string, React.ReactNode> = {
  swap: <path d="M4 8h15m-3-3 3 3-3 3M20 16H5m3-3-3 3 3 3" />,
  tile: <path d="M4 4h16v16H4zM9 9h6v6H9z" />,
  grid: (
    <path
      d={`M5 3h14v18H5z${lines(8, 5, 14, (x) => `M${x} 3v18`)}${lines(10, 3, 18, (y) => `M5 ${y}h14`)}`}
      strokeWidth={0.6}
    />
  ),
  tag: <path d="M3 4h8l8 8-8 8-8-8zM7 8h.01M21 2v6m-2-2 2 2 2-2" />,
  redeem: <path d="M12 3v11m-4-4 4 4 4-4M4 15v5h16v-5" />,
  flame: (
    <path d="M12 3c1 4 5 6 5 11a5 5 0 0 1-10 0c0-2 1-3 2-4 0 2 1 3 2 3 0-4-1-6 1-10z" />
  ),
};

const Arrow = () => (
  <svg className="fw-arrow" viewBox="0 0 28 8" aria-hidden>
    <path d="M0 4h26m-3-3 3 3-3 3" />
  </svg>
);

type Step = {
  icon: string;
  label: string;
  line: string;
  num?: string;
  href?: string;
  later?: boolean;
};

// box: a step in the row. half: one side of the list or redeem step. mini: the burn node on the return loop.
function Box({ t, kind = "box" }: { t: Step; kind?: "box" | "half" | "mini" }) {
  const body = (
    <>
      <svg viewBox="0 0 24 24" aria-hidden>
        {ICONS[t.icon]}
      </svg>
      <span className="fw-label">{t.label}</span>
      <span className="fw-line">{t.line}</span>
      {SHOW_LIVE && <span className="fw-num">{t.num ?? "later"}</span>}
    </>
  );
  const cls = `fw-${kind}${t.later ? " fw-later" : ""}`;
  if (!t.href) return <div className={cls}>{body}</div>;
  if (t.href.startsWith("/"))
    return (
      <Link href={t.href} className={cls}>
        {body}
      </Link>
    );
  return (
    <a href={t.href} target="_blank" rel="noreferrer" className={cls}>
      {body}
    </a>
  );
}

// The steps of the engine under the header of the home page: trade, buy credits, compose, then a
// statement is listed or redeemed (one box, two halves joined by "or"). The return loop runs from
// the sale back to buy credits: sale proceeds refill the pot, and the burn node on the loop is the
// part that buys $CC and burns it.
export function Flywheel() {
  const { data: s } = useStats();
  const { data: snap } = useSnapshot();
  const on = engineDeployed;
  const n = (v: number, max = 0) => (on ? commas(v, max) : "—");
  const burnedPct = (s.ccBurned / LAUNCH_SUPPLY_CC) * 100;
  const balanceOn = !!snap?.balanceOn;
  const trade: Step = {
    icon: "swap",
    label: "trade $CC",
    line: "every trade pays 9.9% into the engine",
    num: `${n(s.feesBooked, 3)} eth booked`,
    href: snap ? evmNowAddress(snap.coin) : undefined,
  };
  const buy: Step = {
    icon: "tile",
    label: "buy credits",
    line: "a standing bid for any credit, no listing",
    num: `${n(s.creditsEth + s.creditsBalance + s.creditsListing)} credits bought`,
    href: "/sell",
  };
  const compose: Step = {
    icon: "grid",
    label: "compose",
    line: "80 credits become one statement",
    num: `${n(s.composed)} statements composed`,
    href: "/compose",
  };
  const list: Step = {
    icon: "tag",
    label: "list",
    line: "listed for eth, 1.5x down to the floor",
    num: `${n(s.sold)} statements sold`,
    href: "/statements",
  };
  const redeem: Step = {
    icon: "redeem",
    label: "redeem",
    line: `redeemed for ${BALANCE_SYMBOL} at the floor`,
    num: balanceOn ? `${n(s.redeemed)} statements redeemed` : undefined,
    href: "/statements",
    later: !balanceOn,
  };
  const burn: Step = {
    icon: "flame",
    label: "burn $CC",
    line: "proceeds refill the pot; part buys $CC and burns it",
    num: `${n(s.ccBurned)} $CC burned${on ? ` · ${commas(burnedPct, 2)}%` : ""}`,
    href: "/statements",
  };
  return (
    <section className="flywheel" aria-label="how the engine works">
      <div className="fw-inner">
        <div className="fw-row">
          <Box t={trade} />
          <Arrow />
          <Box t={buy} />
          <Arrow />
          <Box t={compose} />
          <Arrow />
          <div className="fw-box fw-split" role="group" aria-label="list or redeem">
            <Box t={list} kind="half" />
            <span className="fw-or" aria-hidden>
              or
            </span>
            <Box t={redeem} kind="half" />
          </div>
        </div>
        <div className="fw-loop">
          <Box t={burn} kind="mini" />
        </div>
        <div className="fw-back" aria-hidden>
          <Arrow />
          back to buy credits
        </div>
      </div>
    </section>
  );
}
