"use client";

import {
  useFeed,
  useMarket,
  STATEMENT_SIZE,
  type FeedEvent,
  type FeedKind,
} from "@/lib/engine";
import { isLive } from "@/lib/config";
import { clock, eth } from "@/lib/format";
import { CreditTile, StatementTile } from "./Tiles";

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

  const pct = market.bid > 0n
    ? Math.min(100, Number((market.nextCreditPaid * 100n) / market.bid))
    : 0;
  const stmtPct = Math.min(100, (market.creditsReady / STATEMENT_SIZE) * 100);

  return (
    <section className="feed">
      <div className="feed-head">
        <span className="feed-title">engine feed</span>
        <span className={`live${isLive ? "" : " sample"}`}>
          <span className="dot" />
          {isLive ? "live" : "sample"}
        </span>

        <div className="nextcredit">
          <span>next credit</span>
          <span className="track">
            <i style={{ width: `${pct}%` }} />
          </span>
          <span className="amt">
            {eth(market.nextCreditPaid)} / {eth(market.bid)} eth
          </span>
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
            <th className="col-time">time</th>
            <th className="col-event">event</th>
            <th className="col-detail">detail</th>
            <th className="col-eth">eth</th>
            <th className="col-tx">tx</th>
          </tr>
        </thead>
        <tbody>
          {feed.map((e) => (
            <Row key={e.key} e={e} />
          ))}
        </tbody>
      </table>
    </section>
  );
}

function Row({ e }: { e: FeedEvent }) {
  return (
    <tr className={HL.has(e.kind) ? "hl" : undefined}>
      <td className="col-time" suppressHydrationWarning>
        {clock(e.ts)}
      </td>
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
          {e.tile?.kind === "statement" && <StatementTile id={e.tile.id} />}
          <span className="label">
            {BOLD.has(e.kind) ? <b>{e.detail}</b> : e.detail}
          </span>
        </div>
      </td>
      <td className="col-eth">{e.eth ?? ""}</td>
      <td className="col-tx tx">
        {e.txHash ? (
          <a
            href={`https://evm.now/tx/${e.txHash}?chainId=1`}
            target="_blank"
            rel="noreferrer"
          >
            {e.tx}
            {"…"}
          </a>
        ) : (
          <span>
            {e.tx}
            {"…"}
          </span>
        )}
      </td>
    </tr>
  );
}
