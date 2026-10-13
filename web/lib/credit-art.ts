// Credit / Statement art, matching Jack Butcher's Credits format (as rendered by
// gtmcknight/creditunion's CreditDrawing.sol).
//
// A Credit is a CMYK overprint: four 8x8 plates (cyan, magenta, yellow, black)
// slipped by a small misregistration into a 12x12 raster, blended subtractively
// on white. A Statement is 80 Credits laid out 8 wide x 10 tall (burn order).
//
// The raster is drawn from the credit id with a seeded PRNG. It renders the
// Credits format; it does not read the on-chain hash art.

export const STATEMENT_COLS = 8;
export const STATEMENT_ROWS = 10;
export const STATEMENT_COUNT = STATEMENT_COLS * STATEMENT_ROWS; // 80

const INKS: [number, number, number][] = [
  [0x00, 0xb5, 0xe2], // cyan
  [0xe4, 0x00, 0x7c], // magenta
  [0xff, 0xd1, 0x00], // yellow
  [0x11, 0x11, 0x11], // black
];

// 16 colors: subtractive mix of the enabled plate inks on white, rounded as the
// contract's palette() does.
export const PALETTE_RGB: [number, number, number][] = (() => {
  const out: [number, number, number][] = [];
  for (let mask = 0; mask < 16; mask++) {
    let r = 255,
      g = 255,
      b = 255;
    for (let layer = 0; layer < 4; layer++) {
      if ((mask & (1 << layer)) === 0) continue;
      const [ir, ig, ib] = INKS[layer];
      r = Math.floor((r * ir + 127) / 255);
      g = Math.floor((g * ig + 127) / 255);
      b = Math.floor((b * ib + 127) / 255);
    }
    out.push([r, g, b]);
  }
  return out;
})();

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

function seedOf(id: number): number {
  let h = (id ^ 0x9e3779b9) >>> 0;
  h = Math.imul(h ^ (h >>> 16), 0x45d9f3b) >>> 0;
  h = Math.imul(h ^ (h >>> 13), 0xc2b2ae35) >>> 0;
  return (h ^ (h >>> 16)) >>> 0;
}

// A small registration slip, mostly within the 2px white border so the margin
// survives: ~45% none, ~35% one cell, ~20% two cells.
function slip(rnd: () => number): number {
  const r = rnd();
  if (r < 0.45) return 0;
  const dir = rnd() < 0.5 ? -1 : 1;
  return r < 0.8 ? dir : dir * 2;
}

// 12x12 raster of plate masks (0..15) for one credit, deterministic from id.
// Sparse and airy to match real Credits: few plates print, moderate density,
// an 8x8 core with a white margin and CMYK fringing from the slip.
export function creditMask(id: number): Uint8Array {
  const rnd = mulberry32(seedOf(id));

  // how many plates print — weighted toward 1-2 (keeps credits light, not muddy)
  const pr = rnd();
  const plateCount = pr < 0.3 ? 1 : pr < 0.7 ? 2 : pr < 0.92 ? 3 : 4;
  // pick which plates (Fisher-Yates on C,M,Y,K)
  const order = [0, 1, 2, 3];
  for (let i = 3; i > 0; i--) {
    const j = Math.floor(rnd() * (i + 1));
    [order[i], order[j]] = [order[j], order[i]];
  }
  const plates = order.slice(0, plateCount);

  // density (weight trait): mostly sparse/lean
  const dr = rnd();
  const density = dr < 0.35 ? 0.22 : dr < 0.7 ? 0.32 : dr < 0.92 ? 0.42 : 0.55;

  const px = new Uint8Array(144);
  for (const layer of plates) {
    const dx = slip(rnd);
    const dy = slip(rnd);
    for (let y = 0; y < 8; y++) {
      for (let x = 0; x < 8; x++) {
        if (rnd() >= density) continue;
        const X = 2 + dx + x;
        const Y = 2 + dy + y;
        if (X < 0 || X > 11 || Y < 0 || Y > 11) continue;
        px[Y * 12 + X] |= 1 << layer;
      }
    }
  }
  return px;
}
