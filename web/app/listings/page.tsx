"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import { CreditTile } from "@/components/Tiles";
import { PageHead } from "@/components/Shell";
import { NotDeployed } from "@/components/NotDeployed";
import { engineDeployed } from "@/lib/config";
import { useHead, useSnapshot } from "@/lib/live";
import { useAcquireTx } from "@/lib/useAcquire";
import { useListings, type ListingRow } from "@/lib/useListings";
import { etaLabel } from "@/lib/compose-eta";
import { eth, evmNowTx, rating } from "@/lib/format";

const PAGE = 50;
const BUCKETS = [
  { label: "at bid", max: 0 },
  { label: "0 to 10%", max: 0.1 },
  { label: "10 to 25%", max: 0.25 },
  { label: "25 to 50%", max: 0.5 },
  { label: "50 to 100%", max: 1 },
  { label: "over 100%", max: Infinity },
];

const gapLabel = (r: ListingRow) => (r.clears ? "clears" : r.gap === Infinity ? "—" : `+${(r.gap * 100).toFixed(r.gap < 0.1 ? 1 : 0)}%`);

// "~3h 20m", "~4d"; a pot below the price has no time
function etaText(r: ListingRow): string {
  const e = r.eta;
  if (e.kind === "now") return "now";
  if (e.kind === "pot") return "needs a bigger pot";
  if (e.kind === "cap") return "above rate cap";
  if (e.kind === "far") return "over 30d";
  return e.seconds >= 72 * 3600 ? `~${Math.round(e.seconds / 86400)}d` : etaLabel({ seconds: e.seconds, estimated: true });
}

// Every Credit listed on the CreditStrategy or OpenSea, closest to the engine's bid first. A row whose price is at or
// under its bid and the pot can be acquired through Core.buyListing, the way the header button does.
export default function ListingsPage() {
  const { data, isLoading } = useListings();
  const { data: snap } = useSnapshot();
  const { data: head } = useHead();
  const { buy, available, pending, err, done } = useAcquireTx(head?.n);
  const [shown, setShown] = useState(PAGE);

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
    ? `${rows.length} listed · ${atBid} at bid · ${within(0.1)} within 10% · ${within(0.25)} within 25%`
    : isLoading
      ? "reading listings…"
      : "listings unavailable";
  const max = Math.max(1, ...counts);
  const osCount = rows.filter((r) => r.source === "opensea").length;

  return (
    <div>
      <PageHead title="listings" ink="m" meta={meta}>
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
          {snap && ` bid ${eth(snap.ethRate)} ETH at rating ${rating(snap.settings.refScore)}.`}
        </p>
      </div>
    </div>
  );
}
