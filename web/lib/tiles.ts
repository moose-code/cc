// Deterministic pixel tiles seeded by token id. A credit renders as a few
// vertical bars; a statement renders as a dense grid, matching the engine art.
// Seeded so the same id always draws the same tile (grindable, not secure
// randomness — fine for display).

const PALETTE = [
  "#ff0080", // magenta
  "#12b5d6", // cyan
  "#f5c400", // yellow
  "#0a8f3c", // green
  "#2b6cff", // blue
  "#ff3b1d", // red
  "#000000", // black
  "#7a2bff", // violet
];

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function seedOf(id: number | bigint): number {
  const n = typeof id === "bigint" ? Number(id % 1000000n) : id;
  // hash so adjacent ids look unrelated
  let h = (n ^ 0x9e3779b9) >>> 0;
  h = Math.imul(h ^ (h >>> 16), 0x45d9f3b) >>> 0;
  return h >>> 0;
}

export function creditBars(id: number | bigint): string[] {
  const r = mulberry32(seedOf(id));
  const count = 4 + Math.floor(r() * 2); // 4 or 5 bars
  return Array.from({ length: count }, () =>
    PALETTE[Math.floor(r() * PALETTE.length)]
  );
}

export function statementGrid(id: number | bigint, size = 8): string[] {
  const r = mulberry32(seedOf(id) ^ 0x5bf03);
  return Array.from({ length: size * size }, () =>
    PALETTE[Math.floor(r() * PALETTE.length)]
  );
}
