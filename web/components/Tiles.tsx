"use client";

import { useTokenMeta } from "@/lib/art";

// Token art is the image of the contract's tokenURI. A token whose tokenURI
// reverts shows an empty tile with its id.

export function CreditTile({ id }: { id: number }) {
  const { data } = useTokenMeta("credit", id);
  if (data?.image)
    // eslint-disable-next-line @next/next/no-img-element
    return <img className="tile-credit" src={data.image} alt={`credit #${id}`} />;
  return (
    <span className="tile-credit tile-empty" role="img" aria-label={`credit #${id}`}>
      {data === null ? id : ""}
    </span>
  );
}

export function StatementTile({ id }: { id: number }) {
  const { data } = useTokenMeta("statement", id);
  if (data?.image)
    // eslint-disable-next-line @next/next/no-img-element
    return <img className="tile-statement" src={data.image} alt={`statement ${id}`} />;
  return (
    <span className="tile-statement tile-empty" role="img" aria-label={`statement ${id}`}>
      {data === null ? id : ""}
    </span>
  );
}
