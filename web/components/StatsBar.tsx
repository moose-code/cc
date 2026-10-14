"use client";

import { useEffect, useRef, useState } from "react";
import { formatUnits } from "viem";
import { useStats, STATEMENT_SIZE } from "@/lib/engine";
import { useSnapshot } from "@/lib/live";
import { engineDeployed, LAUNCH_SUPPLY_CC } from "@/lib/config";
import { commas, eth } from "@/lib/format";

const TWEEN_MS = 1200;

// An eth amount that counts up (or down) to a new value over TWEEN_MS with an
// ease-out and flashes its colour once (the `pulse` class, keyed so it restarts).
// The first value is shown as is. Only a changed wei value animates.
function Tween({ wei }: { wei: bigint | undefined }) {
  const [shown, setShown] = useState(wei ?? 0n);
  const [pulse, setPulse] = useState(0);
  const cur = useRef(Number(formatUnits(wei ?? 0n, 18)));
  const seen = useRef(wei);
  useEffect(() => {
    if (wei == null) return;
    if (seen.current == null) {
      seen.current = wei;
      cur.current = Number(formatUnits(wei, 18));
      setShown(wei);
      return;
    }
    if (wei === seen.current) return;
    seen.current = wei;
    setPulse((n) => n + 1);
    const from = cur.current;
    const to = Number(formatUnits(wei, 18));
    const t0 = performance.now();
    let id = requestAnimationFrame(function tick(now) {
      const k = Math.min(1, (now - t0) / TWEEN_MS);
      cur.current = from + (to - from) * (1 - (1 - k) ** 3);
      setShown(BigInt(Math.round(cur.current * 1e18)));
      if (k < 1) id = requestAnimationFrame(tick);
    });
    return () => cancelAnimationFrame(id);
  }, [wei]);
  return (
    <span key={pulse} className={pulse ? "pulse" : undefined}>
      {eth(shown)}
    </span>
  );
}

// Bar filled to min(pct, 100).
const Track = ({ pct, kind }: { pct: number; kind: "credit" | "statement" }) => (
  <span className={`track track-${kind}`} aria-hidden>
    <i style={{ width: `${Math.min(100, pct)}%` }} />
  </span>
);

// Utility bar under the header: what the engine holds now and what it has done.
// next credit is the pot over the average-credit bid; past 100% the pot covers several credits.
export function StatsBar() {
  const { data: s } = useStats();
  const { data: snap } = useSnapshot();
  if (!engineDeployed) return null;
  const pot = snap?.potWithPending;
  const bid = snap?.ethRate ?? 0n;
  const creditPct = pot != null && bid > 0n ? Number((pot * 10_000n) / bid) / 100 : 0;
  const ready = Number((snap?.pileSize ?? 0n) % BigInt(STATEMENT_SIZE)); // pile credits toward the next statement
  const burnedPct = (s.ccBurned / LAUNCH_SUPPLY_CC) * 100;
  return (
    <div className="statsbar">
      <Stat label="pot">
        <Tween wei={pot} /> eth
      </Stat>
      <Stat label="next credit" title={`avg bid ${eth(bid)} eth; each credit's own bid scales with its score`}>
        <Track pct={creditPct} kind="credit" />
        {commas(creditPct)}%
      </Stat>
      <Stat label="next statement">
        <Track pct={(ready / STATEMENT_SIZE) * 100} kind="statement" />
        {ready}/{STATEMENT_SIZE}
      </Stat>
      <Stat label="credits bought">{commas(s.creditsEth + s.creditsBalance + s.creditsListing)}</Stat>
      <Stat label="statements sold">{commas(s.sold)}</Stat>
      <Stat label="cc burned">
        {commas(s.ccBurned)} <span className="sub">{commas(burnedPct, 2)}%</span>
      </Stat>
    </div>
  );
}

function Stat({ label, title, children }: { label: string; title?: string; children: React.ReactNode }) {
  return (
    <div className="stat" title={title}>
      <span className="label">{label}</span>
      <span className="value">{children}</span>
    </div>
  );
}
