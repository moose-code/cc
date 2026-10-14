"use client";

import { useEffect, useRef, useState } from "react";
import { formatUnits } from "viem";
import { STATEMENT_SIZE } from "@/lib/engine";
import { useSnapshot } from "@/lib/live";
import { eth } from "@/lib/format";

const TWEEN_MS = 1200;

// An eth amount that counts up (or down) to a new value over TWEEN_MS with an
// ease-out and flashes its colour once (the `pulse` class, keyed so it restarts).
// The first value is shown as is. Only a changed wei value animates.
export function Tween({ wei }: { wei: bigint | undefined }) {
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

// Bar filled to min(pct, 100); `next` draws the projected fill from pct to min(next, 100) as a lighter segment.
export function Track({ pct, next, kind }: { pct: number; next?: number; kind: "credit" | "statement" }) {
  const a = Math.min(100, pct);
  const b = next != null ? Math.min(100, next) : a;
  return (
    <span className={`track track-${kind}`} aria-hidden>
      <i style={{ width: `${a}%` }} />
      {b > a && <i className="ghost" style={{ left: `${a}%`, width: `${b - a}%` }} />}
    </span>
  );
}

// The pot (with the pending fee income), the average-credit bid, the pot as a percent of
// that bid (past 100 the pot covers several credits) and the pile credits toward the next statement.
export function useEngineGauge() {
  const { data: snap } = useSnapshot();
  const pot = snap?.potWithPending;
  const bid = snap?.ethRate ?? 0n;
  const pctOf = (wei: bigint) => (bid > 0n ? Number((wei * 10_000n) / bid) / 100 : 0);
  return {
    pot,
    bid,
    pctOf,
    creditPct: pot != null ? pctOf(pot) : 0,
    ready: Number((snap?.pileSize ?? 0n) % BigInt(STATEMENT_SIZE)),
  };
}
