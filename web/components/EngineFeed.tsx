"use client";

import {
  useFeed,
  STATEMENT_SIZE,
  type FeedEvent,
  type FeedKind,
} from "@/lib/engine";
import { engineDeployed } from "@/lib/config";
import { useNow, useSnapshot } from "@/lib/live";
import { useBlockTs } from "@/lib/engine";
import { useEffect, useRef, useState } from "react";
import { formatUnits } from "viem";
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

const TWEEN_MS = 1200;

// An eth amount that counts up (or down) to a new value over TWEEN_MS with an
// ease-out and flashes its colour once (the `pulse` class, keyed so it restarts).
// The first value is shown as is. Only a changed wei value animates.
function Tween({ wei }: { wei: bigint | undefined }) {
  const [shown, setShown] = useState(wei ?? 0n);
  const [pulse, setPulse] = useState(0);
  const cur = useRef(Number(formatUnits(wei ?? 0n, 18)));
  const seen = useRef(wei);
  useEffect(() => {
    if (wei == null) return;
    if (seen.current == null) {
      seen.current = wei;
      cur.current = Number(formatUnits(wei, 18));
      setShown(wei);
      return;
    }
    if (wei === seen.current) return;
    seen.current = wei;
    setPulse((n) => n + 1);
    const from = cur.current;
    const to = Number(formatUnits(wei, 18));
    const t0 = performance.now();
    let id = requestAnimationFrame(function tick(now) {
      const k = Math.min(1, (now - t0) / TWEEN_MS);
      cur.current = from + (to - from) * (1 - (1 - k) ** 3);
      setShown(BigInt(Math.round(cur.current * 1e18)));
      if (k < 1) id = requestAnimationFrame(tick);
    });
    return () => cancelAnimationFrame(id);
  }, [wei]);
  return (
    <span key={pulse} className={pulse ? "pulse" : undefined}>
      {eth(shown)}
    </span>
  );
}

export function EngineFeed() {
  const { data: feed } = useFeed();
  const { data: snap } = useSnapshot();
  const now = useNow();
  const [limit, setLimit] = useState(PAGE);

  const ready = Number((snap?.pileSize ?? 0n) % BigInt(STATEMENT_SIZE)); // credits in the pile toward the next statement
  const stmtPct = (ready / STATEMENT_SIZE) * 100;

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
          <span className="amt">
            <Tween wei={snap?.potWithPending} /> eth
          </span>
          <span className="bid" title="the bid for an average credit; each credit's own bid scales with its score">
            avg bid{" "}
            <b>
              <Tween wei={snap?.ethRate} /> eth
            </b>
          </span>
        </div>

        <div className="nextstatement">
          <span>next statement</span>
          <span className="track">
            <i style={{ width: `${stmtPct}%` }} />
          </span>
          <span className="amt">
            {ready} / {STATEMENT_SIZE} credits
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
