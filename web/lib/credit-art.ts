// Credit / Statement art, matching Jack Butcher's Credits format (as rendered by
// gtmcknight/creditunion's CreditDrawing.sol).
//
// A Credit is a CMYK overprint: four 8x8 plates (cyan, magenta, yellow, black)
// slipped by a small misregistration into a 12x12 raster, blended subtractively
// on white. A Statement is 80 Credits laid out 8 wide x 10 tall (burn order).
//
// This is a faithful look-alike seeded by id — not the real on-chain hash art.
// At wiring time, draw the real raster from Credits.seedOf(id) / the art
// contract instead (see web/CONNECTIONS.md).

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

// 12x12 raster of plate masks (0..15) for one credit, deterministic from id.
export function creditMask(id: number): Uint8Array {
  const rnd = mulberry32(seedOf(id));
  const enabled = (Math.floor(rnd() * 15) + 1) & 0xf; // 1..15, >=1 plate prints
  const density = 0.34 + rnd() * 0.34;
  const slips: [number, number][] = [];
  for (let p = 0; p < 4; p++) {
    slips.push([Math.floor(rnd() * 5) - 2, Math.floor(rnd() * 5) - 2]); // -2..2
  }
  const px = new Uint8Array(144);
  for (let layer = 0; layer < 4; layer++) {
    const prints = (enabled & (1 << layer)) !== 0;
    const [dx, dy] = slips[layer];
    for (let y = 0; y < 8; y++) {
      for (let x = 0; x < 8; x++) {
        const on = rnd() < density; // consume stream regardless, keeps it stable
        if (!prints || !on) continue;
        const X = 2 + dx + x;
        const Y = 2 + dy + y;
        if (X < 0 || X > 11 || Y < 0 || Y > 11) continue;
        px[Y * 12 + X] |= 1 << layer;
      }
    }
  }
  return px;
}

// The 80 credit ids a statement composed, deterministic from the statement id.
// CONNECT: replace with the real composed ids from the Core compose record.
export function statementCreditIds(sid: number): number[] {
  const base = 40000 + sid * STATEMENT_COUNT;
  return Array.from({ length: STATEMENT_COUNT }, (_, i) => base + i);
}
