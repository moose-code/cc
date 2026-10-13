"use client";

import Link from "next/link";
import { StatementTile } from "./Tiles";
import { commas, eth } from "@/lib/format";
import { useTokenMeta } from "@/lib/art";

export type StatementStatus = "listed" | "sold" | "redeemed" | "not held";

export function StatementCard({
  id,
  status,
  price,
  priceTag,
}: {
  id: number;
  status: StatementStatus;
  price?: bigint; // asking price while listed, sale price once sold, cost otherwise
  priceTag?: string; // small tag before the price
}) {
  // credit score: the Credit Rating attribute of the statement's tokenURI
  const score = Number(useTokenMeta("statement", id).data?.attrs["Credit Rating"] ?? 0);
  return (
    <Link href={`/statements/${id}`} className="card card-statement">
      <StatementTile id={id} />
      <div className="card-body">
        <div className="card-head">
          <span className="card-id">statement {id}</span>
          <StatusBadge status={status} />
        </div>
        {price != null && (
          <div className="card-price">
            {priceTag && <span className="card-price-tag">{priceTag}</span>}
            {eth(price)} eth
          </div>
        )}
        {score > 0 && (
          <div className="card-sub">
            <span>credit score</span>
            <span>{commas(score)}</span>
          </div>
        )}
      </div>
    </Link>
  );
}

export function StatusBadge({ status }: { status: StatementStatus }) {
  return <span className={`badge badge-${status.replace(" ", "-")}`}>{status === "listed" ? "for sale" : status}</span>;
}
