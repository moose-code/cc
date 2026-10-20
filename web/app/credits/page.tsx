"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { CreditTile } from "@/components/Tiles";
import { Act } from "@/components/Act";
import { ArtFrame, PageHead } from "@/components/Shell";
import { NotDeployed } from "@/components/NotDeployed";
import { engineDeployed, STATEMENT_SIZE } from "@/lib/config";
import { usePile, useScores, useSnapshot, type PileCredit } from "@/lib/live";
import { useMarketView, viewLive, VIEW_STALE_MS } from "@/lib/market-view";
import { compareMarketValue, marketAsks, marketFloor } from "@/lib/credit-market-floor";
import { lsGet, lsSet } from "@/lib/cache";
import { buyCredits } from "@/lib/buy";
import { windowLabel } from "@/lib/compose-eta";
import { agoLabel, eth, rating } from "@/lib/format";

const PAGE = 24;
const STRATEGY_STALE_MS = 20 * 60_000; // twice the keeper's default 10-minute Strategy refresh
type View = "grid" | "table";
type Sort = "value" | "newest" | "price" | "rating";
const SORT_KEY = "cc:credits-sort";

// While the credit sale is on, each held Credit has a falling price (controller.creditPrice).
// Selection feeds the buy box in the rail.
export default function CreditsPage() {
  const { data: pile, loading, pricing } = usePile();
  const { data: snap } = useSnapshot();
  const { data: scores, loading: scoresLoading } = useScores(pile.map((c) => BigInt(c.id)));
  const { data: market, isError: marketError } = useMarketView();
  const [sel, setSel] = useState<Set<number>>(new Set());
  const [view, setView] = useState<View>("grid");
  const [sort, setSortState] = useState<Sort>("value");
  const [shown, setShown] = useState(PAGE);
  const [demo, setDemo] = useState(false);

  useEffect(() => {
    if (process.env.NODE_ENV === "development" && new URLSearchParams(window.location.search).get("demo") === "deals") setDemo(true);
    const saved = lsGet<{ key: Sort }>(SORT_KEY)?.key;
    if (saved === "value" || saved === "newest" || saved === "price" || saved === "rating") setSortState(saved);
  }, []);
  const setSort = (next: Sort) => {
    setSortState(next);
    lsSet(SORT_KEY, { key: next, dir: next === "price" || next === "value" ? 1 : -1 });
  };

  const saleOn = snap?.creditSaleOn ?? false;
  const score = (id: number) => scores?.[id.toString()];
  const now = Date.now();
  const openSeaReady = Boolean(market?.view && market.view.status.source !== "off" && !marketError && viewLive(market, now));
  const strategyReady = Boolean(market?.view?.strategy.publishedAt && !marketError && !market.stale && market.fetchedAt != null && now - market.fetchedAt <= VIEW_STALE_MS && now - market.view.strategy.publishedAt <= STRATEGY_STALE_MS && !(market.view.strategy.lastFailure && market.view.strategy.lastFailure.at > market.view.strategy.publishedAt));
  const asks = useMemo(() => market?.view ? marketAsks(market.view, Math.floor(Date.now() / 1000), { openSea: openSeaReady, strategy: strategyReady }) : [], [market, openSeaReady, strategyReady]);
  const sources = [openSeaReady && "OpenSea", strategyReady && "CreditStrategy"].filter(Boolean).join(" and ");
  const baseFloors = useMemo(() => new Map(pile.map((c) => [c.id, marketFloor(String(c.id), score(c.id) ?? 0n, asks)])), [pile, scores, asks]);
  const floors = useMemo(() => {
    if (!demo) return baseFloors;
    const preview = new Map(baseFloors);
    const factors = [125n, 120n, 110n, 80n, 75n, 70n];
    pile.slice(0, factors.length).forEach((c, i) => { if (c.price > 0n) preview.set(c.id, c.price * factors[i] / 100n); });
    return preview;
  }, [baseFloors, demo, pile]);
  const marketReady = demo || openSeaReady || strategyReady;
  const comparable = (c: PileCredit) => marketReady ? floors.get(c.id) : undefined;
  const below = (c: PileCredit) => saleOn && c.price > 0n && comparable(c) != null && c.price < comparable(c)!;
  const differenceLabel = (c: PileCredit) => {
    const floor = comparable(c);
    if (!floor || c.price <= 0n) return "";
    const gap = c.price > floor ? c.price - floor : floor - c.price;
    if (gap === 0n) return "at similar price";
    const tenths = gap * 1_000n / floor;
    return `${tenths ? `${Number(tenths) / 10}%` : "<0.1%"} ${c.price < floor ? "less here" : "more here"}`;
  };
  const compared = saleOn ? pile.filter((c) => c.price > 0n && comparable(c) != null) : [];
  const belowCount = compared.filter(below).length;
  const rows = useMemo(() => {
    const r = pile.map((c, index) => ({ c, index })).reverse();
    if (sort === "value" && marketReady) r.sort((a, b) => compareMarketValue({ price: a.c.price, floor: floors.get(a.c.id) }, { price: b.c.price, floor: floors.get(b.c.id) }));
    if (sort === "price") r.sort((a, b) => a.c.price < b.c.price ? -1 : a.c.price > b.c.price ? 1 : 0);
    if (sort === "rating") r.sort((a, b) => Number((score(b.c.id) ?? 0n) - (score(a.c.id) ?? 0n)));
    return r;
  }, [pile, sort, scores, floors, marketReady]);
  const ordered = [...rows.filter(({ c }) => below(c)), ...rows.filter(({ c }) => !below(c))];
  const visible = ordered.slice(0, shown);
  const visibleDeals = visible.filter(({ c }) => below(c));
  const visibleOthers = visible.filter(({ c }) => !below(c));
  const bestDeal = [...ordered.filter(({ c }) => below(c))].sort((a, b) => compareMarketValue({ price: a.c.price, floor: floors.get(a.c.id) }, { price: b.c.price, floor: floors.get(b.c.id) }))[0]?.c;
  const selected = pile.filter((c) => sel.has(c.id));
  const selectedPricesReady = selected.length === sel.size && selected.every((c) => c.price > 0n);
  const total = selected.reduce((a, c) => a + c.price, 0n);

  const toggle = (id: number) =>
    setSel((p) => {
      const n = new Set(p);
      n.has(id) ? n.delete(id) : n.add(id);
      return n;
    });
  if (!engineDeployed) return <NotDeployed />;

  const comparisonLoading = loading || pricing || scoresLoading;
  const meta = snap && !loading ? `${pile.length} ${saleOn ? "listed" : "held"} by the engine${demo ? " · design demo" : ""}` : "loading Credits";

  const card = (c: PileCredit) => {
    const on = sel.has(c.id);
    return (
      <div key={c.id} className={`ccard${on ? " on" : ""}${below(c) ? " below-market" : ""}`}>
        <Link href={`/credits/${c.id}`} className="ccard-art" aria-label={`credit #${c.id}`}>
          {below(c) && <span className="credit-deal-badge">{differenceLabel(c)}</span>}
          <ArtFrame>
            <CreditTile id={c.id} />
          </ArtFrame>
        </Link>
        {saleOn && (
          <input
            type="checkbox"
            className="checkbox ccard-check"
            checked={on}
            disabled={demo || c.price === 0n}
            onChange={() => toggle(c.id)}
            aria-label={`select credit #${c.id}`}
          />
        )}
        <div className="ccard-body">
          <div className="ccard-price"><b>{saleOn && c.price > 0n ? eth(c.price) : "—"}</b> <small>{saleOn ? "ETH" : "sale unavailable"}</small></div>
          <div className="ccard-row muted">
            <Link href={`/credits/${c.id}`}>#{c.id}</Link>
            <span>{score(c.id) != null ? `rating ${rating(score(c.id)!)}` : ""}</span>
          </div>
          <div className="ccard-row ccard-eta"><span className="caption">comparable price at this rating</span><span>{comparable(c) != null ? eth(comparable(c)!) : "—"}</span></div>
          {!below(c) && differenceLabel(c) && <div className="price-difference">{differenceLabel(c)}</div>}
        </div>
      </div>
    );
  };

  const listingRows = (items: typeof rows) => view === "grid" ? (
    <div className="cgrid">{items.map(({ c }) => card(c))}</div>
  ) : (
    <div className="ctable">
      <div className="ctable-row ctable-head label">
        <span>{saleOn && <span className="checkbox-ph" />}</span><span /><span>credit</span>
        <span className="num">rating</span><span className="num">price here</span><span className="num">comparable</span>
      </div>
      {items.map(({ c }) => (
        <div key={c.id} className={`ctable-row${sel.has(c.id) ? " on" : ""}${below(c) ? " below-market" : ""}`}>
          <span>{saleOn && <input type="checkbox" className="checkbox" checked={sel.has(c.id)} disabled={demo || c.price === 0n} onChange={() => toggle(c.id)} aria-label={`select credit #${c.id}`} />}</span>
          <span className="ctable-art"><CreditTile id={c.id} /></span>
          <Link href={`/credits/${c.id}`}>credit #{c.id}</Link>
          <span className="num muted">{score(c.id) != null ? rating(score(c.id)!) : ""}</span>
          <span className="num ctable-price">{saleOn && c.price > 0n ? eth(c.price) : "—"}{differenceLabel(c) && <small className={`price-difference${below(c) ? " below-market-label" : ""}`}>{differenceLabel(c)}</small>}</span>
          <span className="num">{comparable(c) != null ? eth(comparable(c)!) : "—"}</span>
        </div>
      ))}
    </div>
  );

  const headline = !snap || loading ? "Loading Credits" : !saleOn ? "Credit sale is unavailable" : !pile.length ? "No Credits for sale yet" : comparisonLoading || !marketReady ? "Checking prices" : !compared.length ? "No similar listings to compare yet" : compared.length < pile.length ? "No confirmed cheaper listings right now." : "No Credits cost less here right now.";

  return (
    <div className={`credits-sale${sel.size ? " has-selection" : ""}`}>
        <PageHead title={saleOn ? "credits for sale" : "credits"} ink="m" meta={meta}>
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
              <option value="value">best value</option>
              <option value="price">lowest price</option>
              <option value="rating">highest rating</option>
              <option value="newest">newest</option>
            </select>
          </label>
        </PageHead>

        <section className={`credit-deals${bestDeal ? " has-best-deal" : ""}`} aria-label="Price comparison">
          <div className="credit-deals-copy">
            {demo && <div className="credit-demo-note">DESIGN DEMO · comparison prices are illustrative</div>}
            <h2>{belowCount && saleOn && !comparisonLoading ? <><span className="credit-count-emphasis">{belowCount}</span> Credit{belowCount === 1 ? "" : "s"} {belowCount === 1 ? "costs" : "cost"} less here.</> : headline}</h2>
            <p>{demo ? "Compared with similarly rated Credits elsewhere. Demo comparison prices are illustrative; buying from this page is disabled." : marketReady ? `Compared with observed ${sources} listings, adjusted to each Credit's rating${market?.fetchedAt ? ` · updated ${agoLabel((now - market.fetchedAt) / 1000)}` : ""}.` : "Browse current engine prices while comparison listings load."}</p>
          </div>
          {bestDeal && !comparisonLoading && <div className="credit-best-deal">
            <span className="label">best value right now</span>
            <div><Link href={`/credits/${bestDeal.id}`}>credit #{bestDeal.id}</Link><strong>{differenceLabel(bestDeal)}</strong></div>
            <p>{eth(bestDeal.price)} ETH here · {eth(comparable(bestDeal)!)} ETH comparable at this rating</p>
          </div>}
        </section>

        <div className="credits-sale-list">
          {loading && <p className="muted" aria-live="polite">Loading listings…</p>}
          {visibleDeals.length > 0 && <section className="credit-list-section" aria-label="Cheaper here">
            <h3><span className="credit-section-mark" />cheaper here <span>{belowCount}</span></h3>
            {listingRows(visibleDeals)}
          </section>}
          {visibleOthers.length > 0 && <section className="credit-list-section" aria-label="Other Credits">
            <h3>{compared.length === pile.length && marketReady ? "same price or more than elsewhere" : "other Credits"} <span>{pile.length - belowCount}</span></h3>
            {listingRows(visibleOthers)}
          </section>}
          <div className="more-row">
            <span className="muted">
              showing {visible.length} of {ordered.length}
            </span>
            {shown < ordered.length && (
              <button className="linkbtn" onClick={() => setShown((n) => n + PAGE)}>
                load more
              </button>
            )}
          </div>
        </div>
        {saleOn && snap && <section className="credit-sale-help">
          <div><span className="label">about these Credits</span><p>Each price falls for {windowLabel(snap.creditWindow)}, then rests at its floor until the Credit is composed. The {STATEMENT_SIZE} oldest Credits make the next statement once the newest leaves its sale window.</p></div>
          <div><Link href="/sell" className="ulink">sell your credits to the engine →</Link><br /><Link href="/listings" className="ulink">credits for sale elsewhere →</Link></div>
        </section>}
        {sel.size > 0 && snap && <div className="credit-buy-bar">
          <div><strong>{sel.size} Credit{sel.size === 1 ? "" : "s"} selected</strong><span>{selectedPricesReady ? `${eth(total)} ETH total · excess refunded if prices fall` : "waiting for current prices"}</span></div>
          <button className="linkbtn" onClick={() => setSel(new Set())}>clear</button>
          <Act label={demo ? "design demo" : snap.paused ? "engine paused" : !selectedPricesReady ? "waiting for prices" : `buy ${selected.length} credit${selected.length === 1 ? "" : "s"}`} disabled={demo || snap.paused || !saleOn || !selectedPricesReady} steps={async (write) => { await buyCredits(write, snap, selected.map((c) => c.id), total); setSel(new Set()); }} />
        </div>}
    </div>
  );
}
