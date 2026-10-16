"use client";

import { useFeed, useHistoryDown, type FeedFilter } from "@/lib/data";
import { useBlockTs, useScan } from "@/lib/engine";
import type { FeedEvent, FeedKind } from "@/lib/events";
import { engineDeployed, STATEMENT_SIZE } from "@/lib/config";
import { potPoints, useCreditTraits, useNow, useScores, useSnapshot } from "@/lib/live";
import { useStatementRating } from "./Cards";
import { useEffect, useRef, useState } from "react";
import { formatUnits } from "viem";
import Link from "next/link";
import { relTime, eth, evmNowTx, rating, commas } from "@/lib/format";
import { CreditTile, StatementTile } from "./Tiles";
import { Addr } from "./Addr";

const MARK: Record<FeedKind, string> = {
  credit: "m",
  composed: "y",
  sold: "divider",
  redeemed: "c",
};

const PLATES = ["C", "M", "Y", "K"]; // bit 0 to 3 of CreditTraits.mask; a set bit is a printed plate

const PAGE = 100; // rows per page of the feed

const FILTERS: FeedFilter[] = ["all", "credits", "statements"];

const TWEEN_MS = 1200;

// An eth amount that counts up (or down) to a new value over TWEEN_MS with an
// ease-out. The first value is shown as is. Only a changed wei value animates.
export function Tween({ wei }: { wei: bigint | undefined }) {
  const [shown, setShown] = useState(wei ?? 0n);
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
  return <span>{eth(shown)}</span>;
}


// Pot and next-statement progress at the top of the rail.
// Pot: the points it buys at the rate, drawn as the share of one page (settings.pointsPerPage) in 8 segments.
// Next statement: credits held toward the next STATEMENT_SIZE, one cell each.
// `pts` is the points the pot (with pending income) buys at the rate; `ratio` that as a percent of one page, capped
// at 100; `segs` the filled count of an 8 segment bar; `per100` the rate, eth per 100 points.
export function usePotPage() {
  const { data: snap } = useSnapshot();
  const pts = snap ? potPoints(snap.potWithPending, snap.ethRate) : undefined;
  const ratio = pts != null && snap ? Math.min(100, (Number(pts) * 100) / snap.settings.pointsPerPage) : undefined;
  const segs = ratio == null ? 0 : Math.min(8, Math.floor(ratio / 12.5));
  const per100 = snap?.ethRate ? eth(snap.ethRate, 5) : undefined;
  return { pts, ratio, segs, per100 };
}

export function EngineProgress() {
  const { data: snap } = useSnapshot();
  const ready = snap ? Number(snap.pileSize % BigInt(STATEMENT_SIZE)) : 0;
  const { pts, segs } = usePotPage();
  return (
    <div className="progress">
      <div className="progress-row">
        <div className="progress-head">
          <span>pot covers</span>
          <b>{pts == null ? "—" : `${commas(pts)} pts`}</b>
        </div>
        <div className="progress-segs">
          {Array.from({ length: 8 }, (_, i) => (
            <i key={i} className={i < segs ? "on" : undefined} />
          ))}
        </div>
      </div>
      <div className="progress-row">
        <div className="progress-head">
          <span>next statement</span>
          <b>
            {ready} / {STATEMENT_SIZE} credits
          </b>
        </div>
        <div className="progress-cells">
          {Array.from({ length: STATEMENT_SIZE }, (_, i) => (
            <i key={i} className={i < ready ? "on" : undefined} />
          ))}
        </div>
      </div>
    </div>
  );
}

export function EngineFeed() {
  const now = useNow();
  const [limit, setLimit] = useState(PAGE);
  const [filter, setFilter] = useState<FeedFilter>("all");
  const { events: shown, total } = useFeed(filter, limit);
  const historyDown = useHistoryDown();
  // one batched read for the credits on screen
  const ids = [...new Set(shown.flatMap((e) => (e.tile?.kind === "credit" ? [BigInt(e.tile.id)] : [])))];
  const { data: scores } = useScores(ids);
  const { data: traits } = useCreditTraits(ids);

  if (!engineDeployed)
    return (
      <section className="ledger">
        <p className="muted">engine not deployed.</p>
      </section>
    );

  return (
    <section className="ledger">
      <div className="ledger-head">
        <h2>engine ledger</h2>
        <span className="live">
          <i className="mark c" />
          live
        </span>
        <div className="seg" role="group" aria-label="filter the ledger">
          {FILTERS.map((f) => (
            <button key={f} className={f === filter ? "on" : undefined} onClick={() => setFilter(f)}>
              {f}
            </button>
          ))}
        </div>
      </div>

      <div className="ledger-table">
        <div className="ledger-cols ledger-th">
          <span>time</span>
          <span>entry</span>
          <span>ref</span>
          <span className="plates">plates</span>
          <span className="num rate">rating</span>
          <span className="num">ETH</span>
        </div>
        {shown.map((e) => (
          <Row key={e.key} e={e} now={now} score={e.tile?.kind === "credit" ? scores?.[String(e.tile.id)] : undefined} mask={e.tile?.kind === "credit" ? traits?.[String(e.tile.id)]?.mask : undefined} />
        ))}
      </div>
      {historyDown && <p className="muted ix-down">history unavailable</p>}
      {total > limit && (
        <button className="action more" onClick={() => setLimit(limit + PAGE)}>
          {`show more (${total - limit} older)`}
        </button>
      )}
    </section>
  );
}

function Row({ e, now, score, mask }: { e: FeedEvent; now: number; score?: bigint; mask?: number }) {
  const { data: blockTs } = useBlockTs(e.ts == null ? e.block : undefined);
  const { data: scan } = useScan();
  const ts = e.ts ?? blockTs;
  const sid = e.tile?.kind === "statement" ? e.tile.id : undefined;
  const rec = sid != null && e.kind === "composed" && e.label !== "statement restyled" ? scan.statements[sid]?.composed : undefined;
  const composed = e.composed ?? (rec ? { format: rec.format, credits: rec.ids.length, cost: rec.cost } : undefined);
  const stmt = composed != null && e.label !== "statement restyled";
  const when = ts != null ? relTime(ts, now) : "—";
  return (
    <div className={`ledger-cols ledger-row${stmt ? " stmt" : ""}`}>
      <span className="when" suppressHydrationWarning>
        {e.txHash ? (
          <a href={evmNowTx(e.txHash)} target="_blank" rel="noreferrer">
            {when}
          </a>
        ) : (
          when
        )}
      </span>
      <span className="entry">
        <i className={`mark ${MARK[e.kind]}`} />
        {e.label}
      </span>
      <span className="ref">
        {e.tile?.kind === "credit" && <CreditTile id={e.tile.id} />}
        {e.tile?.kind === "statement" && <StatementTile id={e.tile.id} />}
        <span className="ref-text">
          {e.link && <Link href={e.link.href}>{e.link.text}</Link>}
          {stmt ? (
            <span className="caption">
              {`format ${composed.format} · ${composed.credits} credits · cost ${eth(composed.cost)} ETH`}
            </span>
          ) : (
            (e.detail || e.addr) && (
              <span className="detail">
                {e.detail}
                {e.addr && (
                  <>
                    {" "}
                    <Addr address={e.addr} />
                  </>
                )}
              </span>
            )
          )}
        </span>
      </span>
      <span className="plates">
        {mask != null &&
          PLATES.map((l, i) => (
            <b key={l} className={mask & (1 << i) ? "on" : undefined}>
              {l}
            </b>
          ))}
      </span>
      <span className="num rate">{score != null ? rating(score) : stmt && sid != null ? <StatementRating sid={sid} raw={e.rating} /> : ""}</span>
      <span className="num">{e.eth ?? ""}</span>
    </div>
  );
}

function StatementRating({ sid, raw }: { sid: number; raw?: bigint }) {
  return <>{useStatementRating(sid, raw)}</>;
}
