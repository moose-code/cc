"use client";

import { useEffect, useRef } from "react";
import {
  creditMask,
  statementCreditIds,
  PALETTE_RGB,
  STATEMENT_COLS,
  STATEMENT_ROWS,
} from "@/lib/credit-art";

// One credit: a 12x12 CMYK raster drawn onto a canvas, scaled up crisply.
export function CreditTile({ id }: { id: number }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const ctx = ref.current?.getContext("2d");
    if (!ctx) return;
    const img = ctx.createImageData(12, 12);
    writeCredit(img.data, 12, 0, 0, id);
    ctx.putImageData(img, 0, 0);
  }, [id]);
  return <canvas ref={ref} width={12} height={12} className="tile-credit" />;
}

// One statement: 80 credits laid out 8 wide x 10 tall (burn order).
export function StatementTile({ id }: { id: number }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const w = STATEMENT_COLS * 12; // 96
  const h = STATEMENT_ROWS * 12; // 120
  useEffect(() => {
    const ctx = ref.current?.getContext("2d");
    if (!ctx) return;
    const img = ctx.createImageData(w, h);
    const ids = statementCreditIds(id);
    for (let c = 0; c < ids.length; c++) {
      const ox = (c % STATEMENT_COLS) * 12;
      const oy = Math.floor(c / STATEMENT_COLS) * 12;
      writeCredit(img.data, w, ox, oy, ids[c]);
    }
    ctx.putImageData(img, 0, 0);
  }, [id, w, h]);
  return <canvas ref={ref} width={w} height={h} className="tile-statement" />;
}

// Blit one credit's 12x12 raster into an ImageData buffer at (ox, oy).
function writeCredit(
  data: Uint8ClampedArray,
  stride: number,
  ox: number,
  oy: number,
  id: number
) {
  const px = creditMask(id);
  for (let i = 0; i < 144; i++) {
    const [r, g, b] = PALETTE_RGB[px[i]];
    const di = ((oy + ((i / 12) | 0)) * stride + (ox + (i % 12))) * 4;
    data[di] = r;
    data[di + 1] = g;
    data[di + 2] = b;
    data[di + 3] = 255;
  }
}
