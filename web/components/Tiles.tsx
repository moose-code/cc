"use client";

import Link from "next/link";
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

// One statement in the "Issued" layout (matching Credit Union's StatementArt):
// 80 credits 8 wide x 10 tall, each 12x12 raster centered in a cell with white
// padding, cells on a 16-wide x 17-tall pitch inside a paper margin. Rows are
// slightly taller than columns, as the contract's 1050 x 1090 pitch is.
const CELL_W = 16;
const CELL_H = 17;
const PAD_X = 2;
const PAD_Y = 2;
const MARGIN = 8;

export function StatementTile({
  id,
  linkCredits = false,
}: {
  id: number;
  linkCredits?: boolean;
}) {
  const ref = useRef<HTMLCanvasElement>(null);
  const w = MARGIN * 2 + STATEMENT_COLS * CELL_W; // 144
  const h = MARGIN * 2 + STATEMENT_ROWS * CELL_H; // 186
  const ids = statementCreditIds(id);
  useEffect(() => {
    const ctx = ref.current?.getContext("2d");
    if (!ctx) return;
    const img = ctx.createImageData(w, h);
    img.data.fill(255); // white paper
    for (let c = 0; c < ids.length; c++) {
      const ox = MARGIN + (c % STATEMENT_COLS) * CELL_W + PAD_X;
      const oy = MARGIN + Math.floor(c / STATEMENT_COLS) * CELL_H + PAD_Y;
      writeCredit(img.data, w, ox, oy, ids[c]);
    }
    ctx.putImageData(img, 0, 0);
  }, [id, w, h, ids]);

  const canvas = (
    <canvas ref={ref} width={w} height={h} className="tile-statement" />
  );
  if (!linkCredits) return canvas;

  // transparent 8x10 link grid over the cells (margins match the canvas).
  return (
    <div className="tile-statement-wrap">
      {canvas}
      <div className="statement-links">
        {ids.map((cid) => (
          <Link
            key={cid}
            href={`/credits/${cid}`}
            title={`credit #${cid}`}
            aria-label={`credit #${cid}`}
          />
        ))}
      </div>
    </div>
  );
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
