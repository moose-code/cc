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
import { relTime, eth, evmNowTx } from "@/lib/format";
import { CreditTile, StatementTile } from "./Tiles";
import { Addr } from "./Addr";

const EVENT_NAME: Record<FeedKind, string> = {
  fee: "fee in",
  credit: "credit",
  composed: "composed",
  listed: "listed",
  sold: "sold",
  burn: "burn",
};

const CHIP_COLOR: Record<FeedKind, string> = {
  fee: "var(--fee)",
  credit: "var(--credit)",
  composed: "var(--composed)",
  listed: "var(--listed)",
  sold: "var(--sold)",
  burn: "var(--burn)",
};

const BOLD = new Set<FeedKind>(["composed", "listed", "sold"]);
const HL = new Set<FeedKind>(["composed", "listed", "sold", "burn"]);

export function EngineFeed() {
  const { data: feed } = useFeed();
  const { data: market } = useMarket();
  const now = useNow();

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
          {feed.map((e) => (
            <Row key={e.key} e={e} now={now} />
          ))}
        </tbody>
      </table>
    </section>
  );
}

function Row({ e, now }: { e: FeedEvent; now: number }) {
  return (
    <tr className={HL.has(e.kind) ? "hl" : undefined}>
      <td className="col-event">
        <span className="event">
          <span
            className={`chip${e.kind === "listed" ? " listed" : ""}`}
            style={e.kind === "listed" ? undefined : { background: CHIP_COLOR[e.kind] }}
          />
          <span className="name">{EVENT_NAME[e.kind]}</span>
        </span>
      </td>
      <td className="col-detail">
        <div className="detail-cell">
          {e.tile?.kind === "credit" && <CreditTile id={e.tile.id} />}
          {e.tile?.kind === "statement" && <StatementTile ids={e.tile.ids} />}
          <span className="label">
            {BOLD.has(e.kind) ? <b>{e.detail}</b> : e.detail}
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
            {relTime(e.ts, now)}
          </a>
        ) : (
          relTime(e.ts, now)
        )}
      </td>
    </tr>
  );
}
