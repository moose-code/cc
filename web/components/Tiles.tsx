import { creditBars, statementGrid } from "@/lib/tiles";

export function CreditTile({ id }: { id: number }) {
  const bars = creditBars(id);
  return (
    <span className="tile-credit" aria-hidden>
      {bars.map((c, i) => (
        <i key={i} style={{ background: c }} />
      ))}
    </span>
  );
}

export function StatementTile({ id, size = 8 }: { id: number; size?: number }) {
  const cells = statementGrid(id, size);
  return (
    <span
      className="tile-statement"
      style={{ gridTemplateColumns: `repeat(${size}, 1fr)` }}
      aria-hidden
    >
      {cells.map((c, i) => (
        <i key={i} style={{ background: c }} />
      ))}
    </span>
  );
}
