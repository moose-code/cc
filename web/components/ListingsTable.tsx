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
  activeId?: bigint;
};

// The listings table: every Credit on the CreditStrategy or OpenSea, closest to the engine's bid first. Shared by the
// listings page and the landing feed tab. Acquisition is available only when the listings page supplies its handler.
export function ListingsTable({ rows, acquire, showGap = false }: { rows: ListingRow[]; acquire?: Acquire; showGap?: boolean }) {
  const bal = useBalanceToken();
  const balanceEth = useBalanceInEth();
  const { data: snap } = useSnapshot();
  const balanceActive = Boolean(snap?.balanceOn && snap.settings.balanceBidOn);
  return (
    <div className={`ltable${balanceActive ? " balance-active" : ""}${showGap ? " with-gap" : ""}${acquire ? " with-action" : ""}`}>
      <div className="ltable-row ltable-head">
        <span />
        <span>credit</span>
        <span className="hide-sm">source</span>
        <span className="num hide-sm">rating</span>
        <span className="num">{acquire ? "price ETH" : "listed"}</span>
        <span className="num hide-sm">{acquire ? "bid ETH" : "our bid"}</span>
        {showGap && <span className="num">over/under</span>}
        {balanceActive && <span className="num hide-sm">balance bid</span>}
        {acquire && <span />}
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
          {showGap && <span className="num" title="asking price relative to ETH bid">
            {Number.isFinite(r.gap) ? `${r.gap > 0 ? "+" : ""}${(r.gap * 100).toFixed(1)}%` : "—"}
          </span>}
          {balanceActive && (
            <span className="num muted hide-sm">
              {r.balanceBid ? `${r.live ? "" : "~"}${formatBalance(r.balanceBid, bal)}` : "—"}
              {r.balanceBid && balanceEth(r.balanceBid) != null && <span className="sub">~{eth(balanceEth(r.balanceBid)!)} ETH</span>}
            </span>
          )}
          {acquire && <span className="lact">
            {!preparedForAcquire(r) && <span className="muted" title="The keeper has not prepared fulfillment for this order.">unprepared</span>}
            {preparedForAcquire(r) && r.clears && acquire.available([r]).length > 0 && (
              <button className="hdr-acq" onClick={() => acquire.buy([r])} disabled={acquire.pending}>
                {acquire.pending && acquire.activeId === r.id ? "…" : "acquire"}
              </button>
            )}
          </span>}
        </div>
      ))}
    </div>
  );
}
