import type { CSSProperties, ReactNode } from "react";

// Loading placeholders (web/design/README.md, "loading and motion"). A skeleton holds the box of the value it stands
// for, so nothing moves when the value arrives, and it reads as loading, never as a value: no fake zeros or dashes
// while a source has not answered. The value then fades in once (.fx-in); later updates of a shown value do not fade.

// An inline bar one text line high, `w` wide (a ch width keeps the box of the expected text). `block` makes a block of
// height `h` for art, cards and controls.
export function Sk({ w = "6ch", h, block, className, style }: { w?: string; h?: string; block?: boolean; className?: string; style?: CSSProperties }) {
  return <span className={`sk${block ? " sk-block" : ""}${className ? ` ${className}` : ""}`} style={{ width: w, height: h, ...style }} aria-hidden />;
}

// The value once `ready`, faded in on arrival; the skeleton of width `w` before.
export function Val({ ready, w, children }: { ready: boolean; w?: string; children: ReactNode }) {
  return ready ? <span className="fx-in">{children}</span> : <Sk w={w} />;
}

// Lines of skeleton text, the last one shorter, for copy whose wording depends on data.
export function SkLines({ n = 2, w = "100%" }: { n?: number; w?: string }) {
  return (
    <span className="sk-lines" aria-hidden>
      {Array.from({ length: n }, (_, i) => (
        <Sk key={i} w={i === n - 1 && n > 1 ? "62%" : w} />
      ))}
    </span>
  );
}

// A grid card while its token loads: the square art frame and `rows` body lines (the first in the price size), the
// box of a credit or statement card.
export function SkCard({ rows = 2 }: { rows?: number }) {
  const widths: [string, string][] = [
    ["11ch", "6ch"],
    ["8ch", "9ch"],
    ["7ch", "6ch"],
  ];
  return (
    <div className="ccard sk-card" aria-hidden>
      <div className="ccard-art">
        <Sk block w="100%" className="sk-art" />
      </div>
      <div className="ccard-body">
        {Array.from({ length: rows }, (_, i) => (
          <div key={i} className="sk-card-row">
            <Sk w={widths[i % 3][0]} />
            <Sk w={widths[i % 3][1]} />
          </div>
        ))}
      </div>
    </div>
  );
}

// A screen reader note for a region that is still loading; the skeletons themselves are hidden from assistive tech.
export function LoadingNote({ what = "loading" }: { what?: string }) {
  return (
    <span className="sr-only" role="status">
      {what}
    </span>
  );
}

// A rail section while its data loads: the real label, then copy lines, key and value rows and the action button's
// box, so the sections below it stay where they will be.
export function SkSideSec({ label, lines = 2, kv = 0, action = false }: { label: ReactNode; lines?: number; kv?: number; action?: boolean }) {
  return (
    <section className="side-sec" aria-busy="true">
      <div className="label">{label}</div>
      {lines > 0 && (
        <p className="side-copy">
          <SkLines n={lines} />
        </p>
      )}
      {Array.from({ length: kv }, (_, i) => (
        <div key={i} className="kv">
          <Sk w="9ch" />
          <Sk w="7ch" />
        </div>
      ))}
      {action && (
        <div className="side-act">
          <Sk block w="100%" h="48px" />
        </div>
      )}
    </section>
  );
}

// What an empty list says once its source has answered with nothing.
export function EmptyNote({ children }: { children: ReactNode }) {
  return <p className="empty-note fx-in">{children}</p>;
}
