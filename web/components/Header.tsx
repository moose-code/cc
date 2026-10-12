"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useStats } from "@/lib/engine";
import { commas } from "@/lib/format";

const LOGO_BARS = ["#0a9b41", "#16b6d8", "#f5c400", "#ff0080"];

const NAV = [
  { href: "/", label: "feed" },
  { href: "/statements", label: "statements" },
  { href: "/credits", label: "credits" },
  { href: "/sell", label: "sell" },
];

export function Header() {
  const { data: s } = useStats();
  const path = usePathname();
  const active = (href: string) =>
    href === "/" ? path === "/" : path.startsWith(href);
  return (
    <header className="header">
      <Link href="/" className="brand">
        <span className="bars" aria-hidden>
          {LOGO_BARS.map((c, i) => (
            <i key={i} style={{ background: c, height: `${10 + i * 3}px` }} />
          ))}
        </span>
        CC
      </Link>

      <nav className="nav">
        {NAV.map((n) => (
          <Link
            key={n.href}
            href={n.href}
            className={active(n.href) ? "on" : undefined}
          >
            {n.label}
          </Link>
        ))}
      </nav>

      <div className="stats">
        <Stat label="credits bought" value={commas(s.creditsBought)} />
        <Stat label="statements" value={commas(s.statements)} />
        <Stat
          label="eth into credits"
          value={s.ethIntoCredits.toLocaleString("en-US", {
            maximumFractionDigits: 1,
          })}
        />
        <Stat label="cc burned" value={commas(s.ccBurned)} />
      </div>

      <div className="connect">
        <ConnectButton
          showBalance={false}
          accountStatus="address"
          chainStatus="none"
        />
      </div>
    </header>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="stat">
      <span className="label">{label}</span>
      <span className="value">{value}</span>
    </div>
  );
}
