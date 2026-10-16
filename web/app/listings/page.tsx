"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import { CreditTile } from "@/components/Tiles";
import { PageHead } from "@/components/Shell";
import { NotDeployed } from "@/components/NotDeployed";
import { engineDeployed, SCORE_PER_100_POINTS } from "@/lib/config";
import { countdown, useBalanceToken, useHead, useNow, useSnapshot } from "@/lib/live";
import { useAcquireTx } from "@/lib/useAcquire";
import { useListings, type ListingRow, type ListingsData } from "@/lib/useListings";
import { useBalanceInEth } from "@/lib/market";
import { nextRise } from "@/lib/climb";
import { etaLabel } from "@/lib/compose-eta";
import { BALANCE_SYMBOL, eth, evmNowTx, formatBalance, rating } from "@/lib/format";
import { useFillsTodayIx } from "@/lib/indexer";

const PAGE = 50;
const BUCKETS = [
  { label: "at bid", max: 0 },
  { label: "0 to 10%", max: 0.1 },
  { label: "10 to 25%", max: 0.25 },
  { label: "25 to 50%", max: 0.5 },
  { label: "50 to 100%", max: 1 },
  { label: "over 100%", max: Infinity },
];

const gapLabel = (r: ListingRow) =>
  r.clears ? "clears" : r.wait != null ? "at bid" : r.gap === Infinity ? "—" : `+${(r.gap * 100).toFixed(r.gap < 0.1 ? 1 : 0)}%`;

// "~3h 20m", "~4d"; a pot below the price has no time
function etaText(r: ListingRow): string {
  const e = r.eta;
  if (r.wait != null) return `next bucket · ${r.wait}s`;
  if (e.kind === "now") return "now";
  if (e.kind === "pot") return "needs a bigger pot";
  if (e.kind === "cap") return "above rate cap";
  if (e.kind === "far") return "over 30d";
  return e.seconds >= 72 * 3600 ? `~${Math.round(e.seconds / 86400)}d` : etaLabel({ seconds: e.seconds, estimated: true });
}

// The next move of the eth bid (lib/climb.ts nextRise) from the chain clock, ticking each second. Only this line
// re-renders on the tick; the figures come from the listings query, which refetches on every new head block.
function RiseLine({ data }: { data: ListingsData }) {
  const now = useNow(1000);
  const w = (x: number) => BigInt(Math.floor(x));
  const e = nextRise(data.climb, now);
  const first = data.rows[0];
  const after = first && first.score > 0n ? ` · #${first.id} bid ${eth((w(e.rate) * first.score) / SCORE_PER_100_POINTS)} ETH after` : "";
  const per100 = `${eth(w(e.rate), 5)} ETH / 100 pts`;
  const text =
    e.kind === "climb"
      ? `bid rises to ${per100} in ${countdown(e.seconds)}${after}`
      : e.kind === "ceiling"
        ? `ceiling loosens to ${per100} in ${countdown(e.seconds)} (+${(e.loosenBps / 100).toFixed(1)}% x ${e.multiplier.toFixed(1)})${after}`
        : e.kind === "cap"
          ? `bid at cap ${per100}`
          : `bid held at the pot ${per100}`;
  return <div className="rise-line">{text}</div>;
}

// Every Credit listed on the CreditStrategy or OpenSea, closest to the engine's bid first. A row whose price is at or
// under its bid and the pot can be acquired through Core.buyListing, the way the header button does.
export default function ListingsPage() {
  const { data, isLoading } = useListings();
  const { data: snap } = useSnapshot();
  const { data: head } = useHead();
  const { buy, available, pending, err, done } = useAcquireTx(head?.n);
  const [shown, setShown] = useState(PAGE);
  const bal = useBalanceToken();
  const balanceEth = useBalanceInEth();
  const { data: fills } = useFillsTodayIx(head?.ts);

  const rows = data?.rows ?? [];
  const counts = useMemo(() => {
    const n = BUCKETS.map(() => 0);
    for (const r of rows) n[BUCKETS.findIndex((b) => r.gap <= b.max)]++;
    return n;
  }, [rows]);

  if (!engineDeployed) return <NotDeployed />;

  const atBid = rows.filter((r) => r.gap <= 0).length;
  const within = (f: number) => rows.filter((r) => r.gap <= f).length;
  const meta = data
    ? `${rows.length} listed · ${atBid} at bid · ${within(0.1)} within 10% · ${within(0.25)} within 25%` +
      (data.covers > 0 ? ` · pot covers ${data.covers}${data.capped ? `, this ${data.bucketSeconds === 60 ? "minute" : "bucket"} ${data.fits}` : ""}` : "")
    : isLoading
      ? "reading listings…"
      : "listings unavailable";
  // the bid range of the listed credits: the rate at the lowest and the highest listed score
  const scores = rows.map((r) => r.score).filter((s) => s > 0n);
  const lo = scores.length ? scores.reduce((a, b) => (b < a ? b : a)) : undefined;
  const hi = scores.length ? scores.reduce((a, b) => (b > a ? b : a)) : undefined;
  const pts = (s: bigint) => Math.round(Number(s) / 10_000);
  const offers =
    data && snap && lo != null && hi != null
      ? `offers ${eth((snap.ethRate * lo) / SCORE_PER_100_POINTS)} to ${eth((snap.ethRate * hi) / SCORE_PER_100_POINTS)} ETH for ${pts(lo)} to ${pts(hi)} pts`
      : undefined;
  const metaFull = (
    <>
      {meta}
      {offers && <div className="rise-line">{offers}</div>}
      {data && <RiseLine data={data} />}
      {snap?.balanceOn && snap.settings.balanceBidOn && snap.balanceUnit !== undefined && (
        <div className="rise-line">balance bid {(Number(snap.balanceRate) / 100).toFixed(1)}% of par</div>
      )}
      {fills && (
        <div className="rise-line">
          fills today: {fills.eth} eth · {fills.balance} {BALANCE_SYMBOL}
        </div>
      )}
    </>
  );
  const max = Math.max(1, ...counts);
  const osCount = rows.filter((r) => r.source === "opensea").length;

  return (
    <div>
      <PageHead title="listings" ink="m" meta={metaFull}>
        {done ? (
          <a className="hdr-acq-done" href={evmNowTx(done.hash)} target="_blank" rel="noreferrer">
            acquired #{done.id.toString()} ↗
          </a>
        ) : (
          err && <span className="hdr-acq-err">{err}</span>
        )}
      </PageHead>

      <div className="split-pad">
        {rows.length > 0 && (
          <div className="lhist" aria-label="listings by price over bid">
            {BUCKETS.map((b, i) => (
              <div key={b.label} className="lhist-col">
                <div className="lhist-bar">
                  <i style={{ height: `${(counts[i] / max) * 100}%` }} />
                </div>
                <b>{counts[i]}</b>
                <span className="caption">{b.label}</span>
              </div>
            ))}
          </div>
        )}

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
          {rows.slice(0, shown).map((r) => (
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
                {r.clears && available([r]).length > 0 && (
                  <button className="hdr-acq" onClick={() => buy([r])} disabled={pending}>
                    <i aria-hidden />
                    {pending ? "…" : "acquire"}
                  </button>
                )}
              </span>
            </div>
          ))}
          {data && rows.length === 0 && <p className="caption">no credits are listed.</p>}
        </div>

        <div className="more-row">
          <span className="muted">
            showing {Math.min(shown, rows.length)} of {rows.length}
          </span>
          {shown < rows.length && (
            <button className="linkbtn" onClick={() => setShown((n) => n + PAGE)}>
              load more
            </button>
          )}
        </div>
        <p className="caption lnote">
          gap is price over bid. bids marked ~ are estimated from the current rate and the rating; the closest 100 rows are
          read from the chain. clears in assumes no sales into the bid and a constant pot.
          {data && data.osMax > 0 && osCount > 0 && ` showing the cheapest ${data.osMax} OpenSea listings.`}
          {snap && ` bid ${eth(snap.ethRate, 5)} ETH / 100 pts.`}
        </p>
      </div>
    </div>
  );
}
