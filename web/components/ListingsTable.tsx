"use client";

import Link from "next/link";
import { CreditTile } from "@/components/Tiles";
import { useBalanceToken, useSnapshot } from "@/lib/live";
import { useBalanceInEth } from "@/lib/market";
import type { ListingRow } from "@/lib/useListings";
import { preparedForAcquire } from "@/lib/acquire";
import { eth, formatBalance, rating } from "@/lib/format";

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
  const { data: snap } = useSnapshot();
  const balanceActive = Boolean(snap?.balanceOn && snap.settings.balanceBidOn);
  return (
    <div className={`ltable${balanceActive ? " balance-active" : ""}`}>
      <div className="ltable-row ltable-head">
        <span />
        <span>credit</span>
        <span className="hide-sm">source</span>
        <span className="num hide-sm">rating</span>
        <span className="num">price ETH</span>
        <span className="num hide-sm">bid ETH</span>
        {balanceActive && <span className="num hide-sm">balance bid</span>}
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
          <span className="num">{eth(r.price)}</span>
          <span className="num muted hide-sm">
            {r.live ? "" : "~"}
            {eth(r.bid)}
          </span>
          {balanceActive && (
            <span className="num muted hide-sm">
              {r.balanceBid ? `${r.live ? "" : "~"}${formatBalance(r.balanceBid, bal)}` : "—"}
              {r.balanceBid && balanceEth(r.balanceBid) != null && <span className="sub">~{eth(balanceEth(r.balanceBid)!)} ETH</span>}
            </span>
          )}
          <span className="lact">
            {!preparedForAcquire(r) && <span className="muted" title="The keeper has not prepared fulfillment for this order.">unprepared</span>}
            {acquire && preparedForAcquire(r) && r.clears && acquire.available([r]).length > 0 && (
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
