"use client";

import Link from "next/link";
import { StatementTile } from "./Tiles";
import { ArtFrame } from "./Shell";
import { commas, eth, rating } from "@/lib/format";
import { useTokenMeta } from "@/lib/art";

export type StatementState = "for sale" | "at floor" | "sold" | "redeemed" | "not held";

// Statement rating in points. A held statement passes its on-chain rating (ten-thousandths of a point, same unit as a
// credit score) and is shown with rating(). Other statements use the "Credit Rating" attribute of the tokenURI, which
// is that rating already in whole points. Both read "27,221" for the same statement.
export function useStatementRating(sid: number, raw?: bigint): string {
  const attr = useTokenMeta("statement", sid).data?.attrs["Credit Rating"];
  if (raw != null && raw > 0n) return rating(raw);
  return attr != null && attr !== "" ? commas(Number(attr)) : "";
}

// 8px ink mark plus the state label: for sale and at floor y, redeemed c, sold and not held divider.
export function StateMark({ state }: { state: StatementState }) {
  const ink = state === "redeemed" ? "c" : state === "for sale" || state === "at floor" ? "y" : "divider";
  return (
    <span className={`state-mark${ink === "divider" ? " dim" : ""}`}>
      <span className={`mark ${ink}`} />
      {state === "for sale" ? "for sale ↓" : state}
    </span>
  );
}

export function StatementCard({
  id,
  state,
  price,
  raw,
}: {
  id: number;
  state: StatementState;
  price?: bigint; // asking price while held, sale price once sold
  raw?: bigint; // on-chain rating while held
}) {
  const r = useStatementRating(id, raw);
  return (
    <div className="ccard">
      <Link href={`/statements/${id}`} className="ccard-art" aria-label={`statement ${id}`}>
        <ArtFrame>
          <StatementTile id={id} />
        </ArtFrame>
      </Link>
      <div className="ccard-body">
        <div className="scard-head">
          <Link href={`/statements/${id}`}>statement {id}</Link>
          {r && <small>r {r}</small>}
        </div>
        <div className="scard-foot">
          <span>{price != null ? `${eth(price)} ETH` : "— ETH"}</span>
          <StateMark state={state} />
        </div>
      </div>
    </div>
  );
}

// Old statement detail badge, removed with that page's rewrite.
export function StatusBadge({ status }: { status: "listed" | "sold" | "redeemed" | "not held" }) {
  return <span className={`badge badge-${status.replace(" ", "-")}`}>{status === "listed" ? "for sale" : status}</span>;
}
