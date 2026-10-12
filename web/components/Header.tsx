"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useStats } from "@/lib/engine";
import { commas } from "@/lib/format";

const LOGO_BARS = ["#0a9b41", "#16b6d8", "#f5c400", "#ff0080"];

export function Header() {
  const { data: s } = useStats();
  return (
    <header className="header">
      <div className="brand">
        <span className="bars" aria-hidden>
          {LOGO_BARS.map((c, i) => (
            <i key={i} style={{ background: c, height: `${10 + i * 3}px` }} />
          ))}
        </span>
        CC
      </div>

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
