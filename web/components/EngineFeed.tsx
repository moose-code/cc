"use client";

import {
  useFeed,
  useMarket,
  STATEMENT_SIZE,
  type FeedEvent,
  type FeedKind,
} from "@/lib/engine";
import { engineDeployed } from "@/lib/config";
import { useNow } from "@/lib/live";
import { useBlockTs } from "@/lib/engine";
import { useState } from "react";
import Link from "next/link";
import { relTime, eth, evmNowTx } from "@/lib/format";
import { CreditTile, StatementTile } from "./Tiles";
import { Addr } from "./Addr";

const CHIP_COLOR: Record<FeedKind, string> = {
  credit: "var(--credit)",
  composed: "var(--composed)",
  sold: "var(--sold)",
  redeemed: "var(--redeemed)",
};

const PAGE = 100; // rows per page of the feed

export function EngineFeed() {
  const { data: feed } = useFeed();
  const { data: market } = useMarket();
  const now = useNow();
  const [limit, setLimit] = useState(PAGE);

  const stmtPct = Math.min(100, (market.creditsReady / STATEMENT_SIZE) * 100);

  if (!engineDeployed)
    return (
      <section className="feed">
        <p className="muted">engine not deployed.</p>
      </section>
    );

  return (
    <section className="feed">
      <div className="feed-head">
        <span className="feed-title">engine feed</span>
        <span className="live">
          <span className="dot" />
          live
        </span>

        <div className="nextcredit">
          <span>pot</span>
          <span className="amt">{eth(market.pot)} eth</span>
          <span className="bid">
            bid <b>{eth(market.bid)} eth</b>
          </span>
        </div>

        <div className="nextstatement">
          <span>next statement</span>
          <span className="track">
            <i style={{ width: `${stmtPct}%` }} />
          </span>
          <span className="amt">
            {market.creditsReady} / {STATEMENT_SIZE} credits
          </span>
        </div>
      </div>

      <table className="feed-table">
        <thead>
          <tr>
            <th className="col-event">event</th>
            <th className="col-detail">detail</th>
            <th className="col-eth">eth</th>
            <th className="col-time">time</th>
          </tr>
        </thead>
        <tbody>
          {feed.slice(0, limit).map((e) => (
            <Row key={e.key} e={e} now={now} />
          ))}
        </tbody>
      </table>
      {feed.length > limit && (
        <button className="action more" onClick={() => setLimit(limit + PAGE)}>
          {`show more (${feed.length - limit} older)`}
        </button>
      )}
    </section>
  );
}

function Row({ e, now }: { e: FeedEvent; now: number }) {
  const { data: ts } = useBlockTs(e.block);
  const when = ts != null ? relTime(ts, now) : "—";
  return (
    <tr className={e.kind === "credit" ? undefined : "hl"}>
      <td className="col-event">
        <span className="event">
          <span className="chip" style={{ background: CHIP_COLOR[e.kind] }} />
          <span className="name">{e.label}</span>
        </span>
      </td>
      <td className="col-detail">
        <div className="detail-cell">
          {e.tile?.kind === "credit" && <CreditTile id={e.tile.id} />}
          {e.tile?.kind === "statement" && <StatementTile id={e.tile.id} />}
          <span className="label">
            {e.link && <Link href={e.link.href}>{e.link.text}</Link>}
            {e.link && e.detail && " "}
            {e.detail}
            {e.addr && (
              <>
                {" "}
                <Addr address={e.addr} />
              </>
            )}
          </span>
        </div>
      </td>
      <td className="col-eth">{e.eth ?? ""}</td>
      <td className="col-time" suppressHydrationWarning>
        {e.txHash ? (
          <a href={evmNowTx(e.txHash)} target="_blank" rel="noreferrer">
            {when}
          </a>
        ) : (
          when
        )}
      </td>
    </tr>
  );
}
