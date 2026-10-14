"use client";

import Link from "next/link";
import { useStats } from "@/lib/engine";
import { useSnapshot } from "@/lib/live";
import { engineDeployed } from "@/lib/config";
import { BALANCE_SYMBOL } from "@/lib/events";
import { commas, evmNowAddress } from "@/lib/format";

const LAUNCH_SUPPLY_CC = 1e9; // the coin's launch supply, 1e27 wei

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

function Box({ t, half }: { t: Step; half?: boolean }) {
  const body = (
    <>
      {!half && (
        <svg viewBox="0 0 24 24" aria-hidden>
          {ICONS[t.icon]}
        </svg>
      )}
      <span className={half ? "fw-head" : "fw-label"}>
        {half ? <span className="fw-label">{t.label}</span> : t.label}
        {half && <span className="fw-num">{t.num ?? "later"}</span>}
      </span>
      <span className="fw-line">{t.line}</span>
      {!half && <span className="fw-num">{t.num ?? "later"}</span>}
    </>
  );
  const cls = `${half ? "fw-half" : "fw-box"}${t.later ? " fw-later" : ""}`;
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

// The steps of the engine, each with a live number, under the header of the home page.
// After compose a statement is either listed or redeemed (one split box); both feed the buyback that burns cc.
export function Flywheel() {
  const { data: s } = useStats();
  const { data: snap } = useSnapshot();
  const on = engineDeployed;
  const n = (v: number, max = 0) => (on ? commas(v, max) : "—");
  const burnedPct = (s.ccBurned / LAUNCH_SUPPLY_CC) * 100;
  const balanceOn = !!snap?.balanceOn;
  const trade: Step = {
    icon: "swap",
    label: "trade cc",
    line: "every trade pays 6.9% into the engine",
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
    icon: "swap",
    label: "redeem",
    line: `redeemed for ${BALANCE_SYMBOL} at the floor`,
    num: balanceOn ? `${n(s.redeemed)} statements redeemed` : undefined,
    href: "/statements",
    later: !balanceOn,
  };
  const burn: Step = {
    icon: "flame",
    label: "burn cc",
    line: "a quarter of each sale and the redeem reserve burn cc",
    num: `${n(s.ccBurned)} cc burned${on ? ` · ${commas(burnedPct, 2)}%` : ""}`,
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
            <Box t={list} half />
            <Box t={redeem} half />
          </div>
          <Arrow />
          <Box t={burn} />
        </div>
        <div className="fw-loop" aria-hidden />
        <div className="fw-back" aria-hidden>
          <Arrow />
          back to trade cc
        </div>
      </div>
    </section>
  );
}
