"use client";

import Link from "next/link";
import { CreditTile, StatementTile } from "./Tiles";
import { ArtFrame } from "./Shell";
import { commas, eth, rating } from "@/lib/format";
import { useTokenMeta } from "@/lib/art";
import type { FormingKind } from "@/lib/forming";

export type StatementState = "for sale" | "at floor" | "sold" | "redeemed" | "not held";

// Statement rating in points. `raw` is the on-chain rating (ten-thousandths of a point, same unit as a credit score:
// Core.ratingOf for a held statement, statement.rating from the indexer) and is shown with rating(). Without it the
// "Credit Rating" attribute of the tokenURI is used, which is that rating already in whole points. Both read "27,221"
// for the same statement.
export function useStatementRating(sid: number, raw?: bigint): string {
  const known = raw != null && raw > 0n;
  const attr = useTokenMeta("statement", sid, !known).data?.attrs["Credit Rating"];
  if (known) return rating(raw);
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

// The art of a statement still forming: the actual Credits of its page in the 8 x 10 sheet grid a composed statement
// uses, empty slots for the rest, on white.
export function FormingArt({ ids, size }: { ids: number[]; size: number }) {
  return (
    <div className="forming-art">
      <div className="forming-grid">
        {Array.from({ length: size }, (_, i) =>
          i < ids.length ? (
            <span key={ids[i]} className="forming-slot">
              <CreditTile id={ids[i]} />
            </span>
          ) : (
            <span key={`e${i}`} className="forming-slot empty" />
          ),
        )}
      </div>
    </div>
  );
}

// A statement forming in the pile, before it is composed (no art of its own yet). `building` is a page still filling;
// otherwise the page is full and waits for its newest credit to clear the sale window or for an earlier page. Links to
// its detail at `sid`, the id it will take, once the next statement id is read.
export function FormingCard({ kind, sid, ids, size, foot }: { kind: FormingKind; sid?: number; ids: number[]; size: number; foot: string }) {
  const label = kind === "building" ? "in progress" : "upcoming statement";
  const href = sid != null ? `/statements/${sid}` : undefined;
  return (
    <div className="ccard forming-card">
      {href ? (
        <Link href={href} className="ccard-art" aria-label={`statement ${sid}, ${label}`}>
          <FormingArt ids={ids} size={size} />
        </Link>
      ) : (
        <div className="ccard-art">
          <FormingArt ids={ids} size={size} />
        </div>
      )}
      <div className="ccard-body">
        <div className="scard-head">
          {href ? <Link href={href}>{label}</Link> : <span>{label}</span>}
          <small>
            {ids.length} / {size}
          </small>
        </div>
        <div className="scard-foot">
          <span className="forming-foot">{foot}</span>
        </div>
      </div>
    </div>
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
