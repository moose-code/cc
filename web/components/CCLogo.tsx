"use client";

import { useEffect, useRef, useState } from "react";

// The CC logo: three C, M, Y squares on a four-corner track (web/design/logo/README.md). Square i sits in slot
// (i + step) % 4, slots clockwise from top left; each step moves every square one corner clockwise.
// Geometry is in a 100 unit box: squares 58, slots at 6 and 36.
const SLOTS: [number, number][] = [
  [6, 6],
  [36, 6],
  [36, 36],
  [6, 36],
];
const INKS = ["c", "m", "y"] as const;
const SQUARE = 58;

type Props = {
  size?: number; // rendered px
  step?: number; // monotonically increasing; the logo shows step % 4
  autoplay?: boolean; // advance every `interval` ms while set
  interval?: number;
};

export function CCLogo({ size = 22, step, autoplay = false, interval = 1600 }: Props) {
  const reduced = useReducedMotion();
  const [extra, setExtra] = useState(0);
  // the first defined step places the squares without a transition, so loading data or navigating never animates
  const placed = useRef(false);
  const [animate, setAnimate] = useState(false);

  useEffect(() => {
    if (!autoplay || reduced) return;
    const t = setInterval(() => setExtra((n) => n + 1), interval);
    return () => clearInterval(t);
  }, [autoplay, interval, reduced]);

  useEffect(() => {
    if (step === undefined || placed.current) return;
    placed.current = true;
    const t = requestAnimationFrame(() => setAnimate(true));
    return () => cancelAnimationFrame(t);
  }, [step]);

  const s = ((((step ?? 0) + extra) % 4) + 4) % 4;
  const k = size / 100;
  return (
    <span className={`cc-logo${animate && !reduced ? " moving" : ""}`} role="img" aria-label="CC engine" style={{ width: size, height: size }}>
      {INKS.map((ink, i) => {
        const [x, y] = SLOTS[(i + s) % 4];
        return <i key={ink} className={ink} style={{ left: x * k, top: y * k, width: SQUARE * k, height: SQUARE * k }} />;
      })}
    </span>
  );
}

function useReducedMotion() {
  const [r, setR] = useState(false);
  useEffect(() => {
    const m = window.matchMedia("(prefers-reduced-motion: reduce)");
    const f = () => setR(m.matches);
    f();
    m.addEventListener("change", f);
    return () => m.removeEventListener("change", f);
  }, []);
  return r;
}
