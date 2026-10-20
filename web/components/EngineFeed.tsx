"use client";

import { useFeed, useHistoryDown } from "@/lib/data";
import { useBlockTs, useScan } from "@/lib/engine";
import type { FeedEvent, FeedKind } from "@/lib/events";
import { engineDeployed, STATEMENT_SIZE } from "@/lib/config";
import { potPoints, useCreditTraits, useNow, useScores, useSnapshot } from "@/lib/live";
import { useListings } from "@/lib/useListings";
import { ListingsTable } from "./ListingsTable";
import { ListingsStatus } from "./ListingsStatus";
import { useStatementRating } from "./Cards";
import { useEffect, useRef, useState } from "react";
import { formatUnits } from "viem";
import Link from "next/link";
import { relTime, eth, evmNowTx, rating, commas } from "@/lib/format";
import { CreditTile, StatementTile } from "./Tiles";
import { Addr } from "./Addr";
import { CCLogo } from "./CCLogo";
import { Sk } from "./Skeleton";

const MARK: Record<FeedKind, string> = {
  credit: "m",
  composed: "y",
  sold: "divider",
  redeemed: "c",
};

const PLATES = ["C", "M", "Y", "K"]; // bit 0 to 3 of CreditTraits.mask; a set bit is a printed plate

const PAGE = 100; // rows per page of the feed

type FeedView = "ledger" | "listings";

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


// Pot figures for the header. Only room above the reserve buys Credits, and the artist payment comes on top.
export function usePotPage() {
  const { data: snap } = useSnapshot();
  const bidRoom = snap ? (snap.potRoom * 10_000n) / BigInt(10_000 + snap.settings.buyToArtistBps) : undefined;
  const pts = snap && bidRoom != null ? potPoints(bidRoom, snap.ethRate) : undefined;
  const per1 = snap ? eth(snap.ethRate / 100n, 7) : undefined;
  return { pts, per1 };
}

export function EngineProgress() {
  const { data: snap } = useSnapshot();
  const ready = snap ? Number(snap.pileSize % BigInt(STATEMENT_SIZE)) : 0;
  return (
    <div className="progress">
      <div className="progress-row">
        <div className="progress-head">
          <span>next statement</span>
          <b>
            {snap ? <span className="fx-in">{ready}</span> : engineDeployed ? <Sk w="2ch" /> : 0} / {STATEMENT_SIZE} credits
          </b>
        </div>
        <div className={`progress-cells${snap || !engineDeployed ? "" : " pulse"}`}>
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
  const [view, setView] = useState<FeedView>("ledger");
  const { events: shown, total, loading } = useFeed("all", limit);
  const historyDown = useHistoryDown();
  // one batched read for the credits on screen
  const ids = [...new Set(shown.flatMap((e) => (e.tile?.kind === "credit" ? [BigInt(e.tile.id)] : [])))];
  const { data: scores, loading: scoresLoading } = useScores(ids);
  const { data: traits, loading: traitsLoading } = useCreditTraits(ids);

  return (
    <section className="ledger">
      <div className="ledger-head">
        <h2>{view === "listings" ? "listings" : "engine ledger"}</h2>
        <span className="live">
          <i className="mark c" />
          live
        </span>
        <div className="seg" role="group" aria-label="feed view">
          {(["ledger", "listings"] as FeedView[]).map((v) => (
            <button key={v} className={v === view ? "on" : undefined} onClick={() => setView(v)}>
              {v}
            </button>
          ))}
        </div>
      </div>

      {view === "listings" ? (
        <ListingsPanel />
      ) : (
        <>
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
              <Row
                key={e.key}
                e={e}
                now={now}
                score={e.tile?.kind === "credit" ? scores?.[String(e.tile.id)] : undefined}
                mask={e.tile?.kind === "credit" ? traits?.[String(e.tile.id)]?.mask : undefined}
                scoreWait={e.tile?.kind === "credit" && scoresLoading}
                maskWait={e.tile?.kind === "credit" && traitsLoading}
              />
            ))}
            {shown.length === 0 && (loading ? <LoadingLedger /> : <EmptyLedger />)}
          </div>
          {historyDown && <p className="muted ix-down">history unavailable</p>}
          {total > limit && (
            <button className="action more" onClick={() => setLimit(limit + PAGE)}>
              {`show more (${total - limit} older)`}
            </button>
          )}
        </>
      )}
    </section>
  );
}

// Rows of the ledger's shape while history loads; the empty state shows only once the source answered with no rows.
function LoadingLedger() {
  return (
    <div aria-busy="true">
      {Array.from({ length: 10 }, (_, i) => (
        <div key={i} className="ledger-cols ledger-row ledger-sk" aria-hidden style={{ opacity: 1 - i * 0.07 }}>
          <span className="when">
            <Sk w="5ch" />
          </span>
          <span className="entry">
            <Sk w="13ch" />
          </span>
          <span className="ref">
            <Sk block w="24px" h="24px" />
            <Sk w="12ch" />
          </span>
          <span className="plates">
            <Sk w="7ch" />
          </span>
          <span className="num rate">
            <Sk w="5ch" />
          </span>
          <span className="num">
            <Sk w="6ch" />
          </span>
        </div>
      ))}
    </div>
  );
}

function EmptyLedger() {
  return (
    <>
      {[
        { ink: "m", entry: "first credit", detail: "bought once the pot covers the bid" },
        { ink: "y", entry: "first statement", detail: `composed after ${STATEMENT_SIZE} credits` },
      ].map(({ ink, entry, detail }) => (
        <div key={ink} className="ledger-cols ledger-row ledger-placeholder">
          <span className="when">—</span>
          <span className="entry"><i className={`mark ${ink}`} aria-hidden />{entry}</span>
          <span className="ref"><i className="ledger-placeholder-tile" aria-hidden /><span>{detail}</span></span>
          <span className="plates" />
          <span className="num rate">—</span>
          <span className="num">—</span>
        </div>
      ))}
      <div className="ledger-empty">
        <CCLogo size={72} autoplay />
        <span>no entries yet</span>
      </div>
    </>
  );
}

const LISTINGS_PAGE = 50;

// The listings table inside the feed tab: reads listings only while this tab is mounted, so the ledger view adds no
// listings query. It is a read-only view of the same listings as the listings page, OpenSea included.
function ListingsPanel() {
  const { data, error, isFetching, refetch, dataUpdatedAt } = useListings();
  const [shown, setShown] = useState(LISTINGS_PAGE);
  const rows = data?.rows ?? [];
  return (
    <>
      <ListingsStatus market={data?.market} strategy={data?.strategyStatus} readAt={dataUpdatedAt || undefined} error={error} fetching={isFetching} retry={() => void refetch()} />
      <ListingsTable rows={rows.slice(0, shown)} loading={!data && !error} />
      {data && rows.length === 0 && <p className="lstatus">no listings in the current view.</p>}
      {shown < rows.length && (
        <button className="action more" onClick={() => setShown((n) => n + LISTINGS_PAGE)}>
          {`show more (${rows.length - shown} more)`}
        </button>
      )}
    </>
  );
}

// scoreWait, maskWait: the credit's rating or plates are still being read (a skeleton until they arrive).
function Row({ e, now, score, mask, scoreWait, maskWait }: { e: FeedEvent; now: number; score?: bigint; mask?: number; scoreWait?: boolean; maskWait?: boolean }) {
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
        {mask != null
          ? PLATES.map((l, i) => (
              <b key={l} className={mask & (1 << i) ? "on" : undefined}>
                {l}
              </b>
            ))
          : maskWait && <Sk w="7ch" />}
      </span>
      <span className="num rate">
        {score != null ? rating(score) : stmt && sid != null ? <StatementRating sid={sid} raw={e.rating} /> : scoreWait ? <Sk w="5ch" /> : ""}
      </span>
      <span className="num">{e.eth ?? ""}</span>
    </div>
  );
}

function StatementRating({ sid, raw }: { sid: number; raw?: bigint }) {
  return <>{useStatementRating(sid, raw)}</>;
}
