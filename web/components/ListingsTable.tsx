"use client";

import Link from "next/link";
import { CreditTile } from "@/components/Tiles";
import { useBalanceToken } from "@/lib/live";
import { useBalanceInEth } from "@/lib/market";
import type { ListingRow } from "@/lib/useListings";
import { etaLabel } from "@/lib/compose-eta";
import { eth, formatBalance, rating } from "@/lib/format";

export const gapLabel = (r: ListingRow) =>
  r.clears ? "clears" : r.wait != null ? "at bid" : r.gap === Infinity ? "—" : `+${(r.gap * 100).toFixed(r.gap < 0.1 ? 1 : 0)}%`;

// "~3h 20m", "~4d"; a pot below the price has no time
export function etaText(r: ListingRow): string {
  if (r.paused) return "engine paused";
  const e = r.eta;
  if (r.wait != null) return `next bucket · ${r.wait}s`;
  if (e.kind === "now") return "now";
  if (e.kind === "pot") return "needs a bigger pot";
  if (e.kind === "cap") return "above rate cap";
  if (e.kind === "far") return "over 30d";
  return e.seconds >= 72 * 3600 ? `~${Math.round(e.seconds / 86400)}d` : etaLabel({ seconds: e.seconds, estimated: true });
}

type Acquire = {
  buy: (rows: ListingRow[]) => void;
  available: (rows: ListingRow[]) => ListingRow[];
  pending: boolean;
};

// The listings table: every Credit on the CreditStrategy or OpenSea, closest to the engine's bid first. Shared by the
// listings page and the landing feed tab. A row that clears can be acquired through Core.buyListing.
export function ListingsTable({ rows, acquire }: { rows: ListingRow[]; acquire?: Acquire }) {
  const bal = useBalanceToken();
  const balanceEth = useBalanceInEth();
  return (
    <div className="ltable">
      <div className="ltable-row ltable-head label">
        <span />
        <span>credit</span>
        <span className="hide-sm">source</span>
        <span className="num hide-sm">rating</span>
        <span className="num">price ETH</span>
        <span className="num hide-sm">bid ETH</span>
        <span className="num hide-sm">balance bid</span>
        <span className="num">gap</span>
        <span className="num">clears in</span>
        <span />
      </div>
      {rows.map((r) => (
        <div key={`${r.source}:${r.id}`} className={`ltable-row${r.clears ? " on" : ""}`}>
          <span className="ctable-art">
            <CreditTile id={Number(r.id)} />
          </span>
          <Link href={`/credits/${r.id}`}>
            <span className="hide-sm">credit </span>#{r.id.toString()}
          </Link>
          <span className="muted hide-sm">{r.source === "strategy" ? "CreditStrategy" : "OpenSea"}</span>
          <span className="num muted hide-sm">{rating(r.score)}</span>
          <span className="num ctable-price">{eth(r.price)}</span>
          <span className="num muted hide-sm">
            {r.live ? "" : "~"}
            {eth(r.bid)}
          </span>
          <span className="num muted hide-sm">
            {r.balanceBid ? `${r.live ? "" : "~"}${formatBalance(r.balanceBid, bal)}` : "—"}
            {r.balanceBid && balanceEth(r.balanceBid) != null && <span className="sub">~{eth(balanceEth(r.balanceBid)!)} ETH</span>}
          </span>
          <span className={`num${r.clears ? " ctable-price" : ""}`}>{gapLabel(r)}</span>
          <span className="num">{etaText(r)}</span>
          <span className="lact">
            {acquire && r.clears && acquire.available([r]).length > 0 && (
              <button className="hdr-acq" onClick={() => acquire.buy([r])} disabled={acquire.pending}>
                {acquire.pending ? "…" : "acquire"}
              </button>
            )}
          </span>
        </div>
      ))}
    </div>
  );
}
