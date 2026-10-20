"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import { CreditTile } from "@/components/Tiles";
import { Act } from "@/components/Act";
import { ArtFrame, PageHead } from "@/components/Shell";
import { NotDeployed } from "@/components/NotDeployed";
import { EmptyNote, Sk, SkCard, SkSideSec } from "@/components/Skeleton";
import { MarketReport } from "@/components/MarketReport";
import { useComposeEta } from "@/components/ComposeEta";
import { engineDeployed, STATEMENT_SIZE } from "@/lib/config";
import { howLabel } from "@/lib/indexer";
import { useHistoryDown, useMarketReport } from "@/lib/data";
import { bandOf, vsMedian } from "@/lib/market-report";
import { useScan } from "@/lib/engine";
import type { CreditEvt } from "@/lib/events";
import { usePile, useScores, useSnapshot, type PileCredit } from "@/lib/live";
import { buyCredits } from "@/lib/buy";
import { etaLabel, floorIn, windowLabel } from "@/lib/compose-eta";
import { agoLabel, commas, eth, leftLabel, rating, signedPct } from "@/lib/format";

const PAGE = 24;
type View = "grid" | "table";
type Sort = "newest" | "price" | "rating";

// Credits held by the engine, newest first. While the credit sale is on, each has a falling price
// (controller.creditPrice) and can be bought. Selection feeds the buy box in the rail.
export default function CreditsPage() {
  const { data: pile, loading, pricing } = usePile();
  const historyDown = useHistoryDown();
  const { data: snap } = useSnapshot();
  const { data: scan } = useScan();
  const { data: scores, loading: scoresLoading } = useScores(pile.map((c) => BigInt(c.id)));
  const report = useMarketReport();
  const [band, setBand] = useState<number | undefined>();
  const eta = useComposeEta(pile, 15000);
  const [sel, setSel] = useState<Set<number>>(new Set());
  const [view, setView] = useState<View>("grid");
  const [sort, setSort] = useState<Sort>("newest");
  const [shown, setShown] = useState(PAGE);

  const saleOn = snap?.creditSaleOn ?? false;
  // per credit: time until its sale window ends. at zero its price rests at the floor and compose can take it
  const floorLabel = (c: PileCredit) => {
    const s = floorIn(c.acquiredAt, saleOn ? snap!.creditWindow : 0, eta.now);
    return s > 0 ? leftLabel(s) : "now";
  };
  const score = (id: number) => scores?.[id.toString()];
  // while the sale is on a credit's price is above zero: a zero is a price not read yet (a skeleton) or a read that
  // failed (a dash)
  const priceText = (c: PileCredit) => (c.price > 0n ? eth(c.price) : pricing ? <Sk w="6ch" /> : "—");
  // a listing against its band's median of the last 7 days: a skeleton while the price, score or report loads, a
  // dash when the band had no sales
  const vsMarket = (c: PileCredit) => {
    const sc = score(c.id);
    const median = sc != null ? report.bands[bandOf(sc).key]?.median : undefined;
    if (c.price > 0n && median != null) return signedPct(vsMedian(c.price, median));
    return pricing || report.loading || (sc == null && scoresLoading) ? <Sk w="4ch" /> : "—";
  };
  // the cheapest credit listed now in each band, for the report
  const listedFrom = useMemo(() => {
    const m = new Map<number, bigint>();
    if (!saleOn) return m;
    for (const c of pile) {
      const sc = scores?.[c.id.toString()];
      if (sc == null || c.price === 0n) continue;
      const k = bandOf(sc).key;
      const cur = m.get(k);
      if (cur == null || c.price < cur) m.set(k, c.price);
    }
    return m;
  }, [pile, scores, saleOn]);
  // queue position (oldest = 0) is the index in the pile, which the list order keeps; a picked band filters it
  const rows = useMemo(() => {
    const r = pile
      .map((c, index) => ({ c, index }))
      .filter(({ c }) => band == null || (score(c.id) != null && bandOf(score(c.id)!).key === band))
      .reverse();
    if (sort === "price") r.sort((a, b) => Number(a.c.price - b.c.price));
    if (sort === "rating") r.sort((a, b) => Number((score(b.c.id) ?? 0n) - (score(a.c.id) ?? 0n)));
    return r;
  }, [pile, sort, scores, band]);
  const visible = rows.slice(0, shown);
  const selected = pile.filter((c) => sel.has(c.id));
  const total = selected.reduce((a, c) => a + c.price, 0n);

  const toggle = (id: number) =>
    setSel((p) => {
      const n = new Set(p);
      n.has(id) ? n.delete(id) : n.add(id);
      return n;
    });

  if (!engineDeployed) return <NotDeployed />;

  // nothing about the pile is shown until it has loaded: no "0 held" while it is read. The bid is in the site header
  // and what credits trade for is in the market report, so the line keeps to the pile
  const meta = loading
    ? undefined
    : [
        `${commas(pile.length)} held by engine`,
        snap?.paused ? "composition paused" : eta.at(0) && `next statement composes in ${etaLabel(eta.at(0))}`,
        historyDown && "history unavailable",
      ]
        .filter(Boolean)
        .join(" · ");

  const card = (c: PileCredit, index: number) => {
    const on = sel.has(c.id);
    return (
      <div key={c.id} className={`ccard${on ? " on" : ""}`}>
        <Link href={`/credits/${c.id}`} className="ccard-art" aria-label={`credit #${c.id}`}>
          <ArtFrame>
            <CreditTile id={c.id} />
          </ArtFrame>
        </Link>
        {saleOn && (
          <input
            type="checkbox"
            className="checkbox ccard-check"
            checked={on}
            onChange={() => toggle(c.id)}
            aria-label={`select credit #${c.id}`}
          />
        )}
        <div className="ccard-body">
          <div className="ccard-price">
            <b>{saleOn ? priceText(c) : eth(c.cost)}</b> <small>{saleOn ? "ETH" : "ETH paid"}</small>
          </div>
          <div className="ccard-row muted">
            <Link href={`/credits/${c.id}`}>#{c.id}</Link>
            <span>{score(c.id) != null ? `rating ${rating(score(c.id)!)}` : ""}</span>
          </div>
          {saleOn && (
            <div className="ccard-row ccard-eta" title="the price against the median the engine paid in its rating band, last 7 days">
              <span className="caption">vs market</span>
              <span>{vsMarket(c)}</span>
            </div>
          )}
          <div className="ccard-row ccard-eta ccard-eta-next">
            <span className="caption">floor in</span>
            <span>{floorLabel(c)}</span>
          </div>
        </div>
      </div>
    );
  };

  return (
    <div className="split">
      <div className="split-main">
        <PageHead title="credits" ink="m" meta={meta} metaW="44ch" metaLines={1} inline>
          <div className="seg" role="group" aria-label="view">
            {(["grid", "table"] as View[]).map((v) => (
              <button key={v} className={view === v ? "on" : ""} onClick={() => setView(v)}>
                {v}
              </button>
            ))}
          </div>
          <label className="sort">
            sort:{" "}
            <select value={sort} onChange={(e) => setSort(e.target.value as Sort)}>
              <option value="newest">newest</option>
              <option value="price">price</option>
              <option value="rating">rating</option>
            </select>
          </label>
        </PageHead>

        <div className="split-pad">
          <MarketReport report={report} listedFrom={listedFrom} listedLoading={loading || pricing || scoresLoading} active={band} onPick={setBand} />
          {loading ? (
            view === "grid" ? (
              <div className="cgrid" aria-busy="true">
                {Array.from({ length: 12 }, (_, i) => (
                  <SkCard key={i} rows={saleOn || !snap ? 4 : 3} />
                ))}
              </div>
            ) : (
              <div className="ctable" aria-busy="true">
                {Array.from({ length: 12 }, (_, i) => (
                  <div key={i} className="ctable-row" aria-hidden>
                    <span />
                    <Sk block w="28px" h="28px" />
                    <Sk w="12ch" />
                    <Sk w="5ch" />
                    <Sk w="6ch" />
                    <Sk w="6ch" />
                    <Sk w="8ch" className="hide-sm" />
                    <Sk w="6ch" className="hide-sm" />
                    <Sk w="6ch" />
                  </div>
                ))}
              </div>
            )
          ) : pile.length === 0 ? (
            <EmptyNote>the engine holds no credits right now. credits it buys queue here until they compose.</EmptyNote>
          ) : rows.length === 0 ? (
            <EmptyNote>no credits listed in this band right now.</EmptyNote>
          ) : view === "grid" ? (
            <div className="cgrid">{visible.map(({ c, index }) => card(c, index))}</div>
          ) : (
            <div className="ctable">
              <div className="ctable-row ctable-head label">
                <span>{saleOn && <span className="checkbox-ph" />}</span>
                <span />
                <span>credit</span>
                <span className="num">rating</span>
                <span className="num">{saleOn ? "price ETH" : ""}</span>
                <span className="num">paid ETH</span>
                <span className="hide-sm">got by</span>
                <span className="num hide-sm">bought</span>
                <span className="num">floor in</span>
              </div>
              {visible.map(({ c, index }) => {
                const on = sel.has(c.id);
                return (
                  <div key={c.id} className={`ctable-row${on ? " on" : ""}`}>
                    <span>
                      {saleOn && (
                        <input
                          type="checkbox"
                          className="checkbox"
                          checked={on}
                          onChange={() => toggle(c.id)}
                          aria-label={`select credit #${c.id}`}
                        />
                      )}
                    </span>
                    <span className="ctable-art">
                      <CreditTile id={c.id} />
                    </span>
                    <Link href={`/credits/${c.id}`}>credit #{c.id}</Link>
                    <span className="num muted">{score(c.id) != null ? rating(score(c.id)!) : ""}</span>
                    <span className="num ctable-price">
                      {saleOn ? priceText(c) : ""}
                      {saleOn && <small className="ctable-vs">{vsMarket(c)} vs mkt</small>}
                    </span>
                    <span className="num muted">{eth(c.cost)}</span>
                    <span className="muted hide-sm">{c.how ? howLabel(c.how) : gotBy(scan.credits[c.id])}</span>
                    <span className="num muted hide-sm">{agoLabel(eta.now - c.acquiredAt)}</span>
                    <span className="num">{floorLabel(c)}</span>
                  </div>
                );
              })}
            </div>
          )}
          {!loading && rows.length > 0 && (
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
          )}
        </div>
      </div>

      <aside className="side">
        {!snap && <SkSideSec label="buy credits" lines={3} kv={2} action />}
        {saleOn && snap && (
          <section className="side-sec">
            <div className="label">buy credits</div>
            <p className="side-copy">
              every credit the engine buys is for sale. the price falls for {windowLabel(snap.creditWindow)}, then rests at its
              floor until the credit is composed.
            </p>
            {selected.length > 0 && (
              <ul className="sel-list">
                {selected.map((c) => (
                  <li key={c.id}>
                    <CreditTile id={c.id} />
                    <span className="sel-id">
                      credit #{c.id}
                      <small className="muted">{score(c.id) != null ? `rating ${rating(score(c.id)!)}` : ""}</small>
                    </span>
                    <span>{priceText(c)} ETH</span>
                    <button className="x" onClick={() => toggle(c.id)} aria-label={`remove credit #${c.id}`}>
                      ×
                    </button>
                  </li>
                ))}
              </ul>
            )}
            <div className="kv">
              <span className="muted">selected</span>
              <span>
                {selected.length} credit{selected.length === 1 ? "" : "s"}
              </span>
            </div>
            <div className="kv">
              <span className="muted">total</span>
              <span>{eth(total)} ETH</span>
            </div>
            <div className="side-act">
              <Act
                label={snap.paused ? "engine paused" : selected.length ? `buy ${selected.length} credit${selected.length === 1 ? "" : "s"}` : "select credits"}
                disabled={snap.paused || selected.length === 0 || selected.some((c) => c.price === 0n)}
                steps={async (write) => {
                  await buyCredits(write, snap, selected.map((c) => c.id), total);
                  setSel(new Set());
                }}
              />
            </div>
            <p className="caption">prices keep falling while in window · excess refunded</p>
          </section>
        )}
        <section className="side-sec">
          <div className="label">how compose timing works</div>
          <ol className="steps">
            <li>credits queue in the order the engine bought them.</li>
            <li>the {STATEMENT_SIZE} oldest make the next statement.</li>
            <li>it composes once the newest of the {STATEMENT_SIZE} leaves its sale window.</li>
          </ol>
          <Link href="/sell" className="ulink">
            sell your credits to the engine →
          </Link>
          <div>
            <Link href="/listings" className="ulink">
              credits listed for sale elsewhere →
            </Link>
          </div>
        </section>
      </aside>
    </div>
  );
}

// How the engine got a credit in chain mode: the latest bought step in its history.
function gotBy(evts?: CreditEvt[]): string {
  const b = [...(evts ?? [])].reverse().find((e) => e.t === "bought");
  return b && b.t === "bought" ? b.how : "—";
}
