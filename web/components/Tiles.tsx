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

export function CreditTile({ id }: { id: number }) {
  return <Tile key={id} kind="credit" id={id} />;
}

export function StatementTile({ id }: { id: number }) {
  return <Tile key={id} kind="statement" id={id} />;
}
