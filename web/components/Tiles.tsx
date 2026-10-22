"use client";

import { useState } from "react";
import { useTokenMeta, type TokenKind } from "@/lib/art";

// Token art is the image of the contract's tokenURI. A token whose tokenURI
// reverts shows an empty tile with its id. While the metadata loads the tile
// pulses in its own box; art that arrives after the first render fades in, and
// art already cached shows at once.

function Tile({ kind, id }: { kind: TokenKind; id: number }) {
  const { data } = useTokenMeta(kind, id);
  const [waited] = useState(() => data === undefined);
  const cls = kind === "credit" ? "tile-credit" : "tile-statement";
  const label = kind === "credit" ? `credit #${id}` : `statement ${id}`;
  if (data?.image)
    // eslint-disable-next-line @next/next/no-img-element
    return <img className={`${cls}${waited ? " tile-in" : ""}`} src={data.image} alt={label} decoding="async" />;
  return (
    <span className={`${cls} tile-empty${data === undefined ? " tile-wait" : ""}`} role="img" aria-label={label} aria-busy={data === undefined}>
      {data === null ? id : ""}
    </span>
  );
}

// The $CC burn's tile: a pixel flame drawn like Credit art (an 8 x 8 grid of 20 px cells centred on a white 320
// canvas, crisp edges) in the Credits inks, red over yellow.
const FLAME = ["....R...", "...RR...", "..RRR.R.", ".RRYRRR.", ".RYYYRRR", "RRYYYYRR", "RRYYYYRR", ".RRYYRR."];
const INK: Record<string, string> = { R: "#e40000", Y: "#ffd100" };
export function BurnTile() {
  return (
    <svg className="tile-credit" viewBox="0 0 320 320" shapeRendering="crispEdges" role="img" aria-label="$CC burned">
      <rect width="320" height="320" fill="#ffffff" />
      {FLAME.flatMap((row, y) =>
        [...row].map((c, x) => (c in INK ? <rect key={`${x}-${y}`} x={80 + x * 20} y={80 + y * 20} width="20" height="20" fill={INK[c]} /> : null)),
      )}
    </svg>
  );
}

export function CreditTile({ id }: { id: number }) {
  return <Tile key={id} kind="credit" id={id} />;
}

export function StatementTile({ id }: { id: number }) {
  return <Tile key={id} kind="statement" id={id} />;
}
