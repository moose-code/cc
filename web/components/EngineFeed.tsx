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
import { relTime, eth, evmNowTx } from "@/lib/format";
import { CreditTile, StatementTile } from "./Tiles";
import { useTokenMeta } from "@/lib/art";
import { Addr } from "./Addr";

const CHIP_COLOR: Record<FeedKind, string> = {
  fee: "var(--fee)",
  credit: "var(--credit)",
  composed: "var(--composed)",
  listed: "var(--listed)",
  sold: "var(--sold)",
  burn: "var(--burn)",
  exit: "var(--exit)",
  price: "var(--price)",
  admin: "var(--muted2)",
};

const PAGE = 100; // rows per page of the feed

const BOLD = new Set<FeedKind>(["composed", "listed", "sold", "exit"]);
const HL = new Set<FeedKind>(["composed", "listed", "sold", "burn", "exit"]);

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
    <tr className={HL.has(e.kind) ? "hl" : undefined}>
      <td className="col-event">
        <span className="event">
          <span
            className={`chip${e.kind === "listed" ? " listed" : ""}`}
            style={e.kind === "listed" ? undefined : { background: CHIP_COLOR[e.kind] }}
          />
          <span className="name">{e.label}</span>
        </span>
      </td>
      <td className="col-detail">
        <div className="detail-cell">
          {e.tile?.kind === "credit" && <CreditTile id={e.tile.id} />}
          {e.tile?.kind === "statement" && <StatementTile id={e.tile.id} />}
          <span className="label">
            {BOLD.has(e.kind) ? <b>{e.detail}</b> : e.detail}
            {e.addr && (
              <>
                {" "}
                <Addr address={e.addr} />
              </>
            )}
            {e.format != null && e.tile?.kind === "statement" && <FormatName sid={e.tile.id} index={e.format} />}
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

// " · format Consolidated": the name is the Format attribute of the statement's tokenURI.
function FormatName({ sid, index }: { sid: number; index: number }) {
  const { data } = useTokenMeta("statement", sid);
  return <span className="muted"> · format {data?.attrs.Format ?? index}</span>;
}
