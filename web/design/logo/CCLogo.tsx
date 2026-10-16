// CC Engine logo — "four-slot loop" (option 1d)
// Three CMY squares on a four-corner track. The empty slot implies motion;
// each step moves every square one corner clockwise.
import { useEffect, useState } from "react";

const COLORS = ["#00a3e0", "#e5007e", "#ffd400"]; // C, M, Y
// Slot positions in a 100×100 unit box, clockwise from top-left. Square size 58.
const SLOTS: [number, number][] = [[6, 6], [36, 6], [36, 36], [6, 36]];
const SIZE = 58;

type Props = {
  size?: number;          // rendered px, default 22 (header)
  step?: number;          // controlled step; increment to advance one corner
  autoplay?: boolean;     // loop continuously (landing / loading states)
  interval?: number;      // autoplay ms per step, default 1600
  className?: string;
};

export function CCLogo({ size = 22, step, autoplay = false, interval = 1600, className }: Props) {
  const [auto, setAuto] = useState(0);
  const reduced = usePrefersReducedMotion();

  useEffect(() => {
    if (!autoplay || reduced) return;
    const t = setInterval(() => setAuto((s) => s + 1), interval);
    return () => clearInterval(t);
  }, [autoplay, interval, reduced]);

  const s = ((step ?? auto) % 4 + 4) % 4;
  const k = size / 100;

  return (
    <span
      className={className}
      role="img"
      aria-label="CC engine"
      style={{ position: "relative", display: "inline-block", width: size, height: size, flex: "none" }}
    >
      {COLORS.map((c, i) => {
        const [x, y] = SLOTS[(i + s) % 4];
        return (
          <span
            key={c}
            className="cc-logo-sq"
            style={{
              position: "absolute",
              left: x * k,
              top: y * k,
              width: SIZE * k,
              height: SIZE * k,
              background: c,
              transition: reduced ? "none" : "left .7s cubic-bezier(.6,0,.3,1), top .7s cubic-bezier(.6,0,.3,1)",
            }}
          />
        );
      })}
    </span>
  );
}

function usePrefersReducedMotion() {
  const [r, setR] = useState(false);
  useEffect(() => {
    const m = window.matchMedia("(prefers-reduced-motion: reduce)");
    setR(m.matches);
    const on = (e: MediaQueryListEvent) => setR(e.matches);
    m.addEventListener("change", on);
    return () => m.removeEventListener("change", on);
  }, []);
  return r;
}
