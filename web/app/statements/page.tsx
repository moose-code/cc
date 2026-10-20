"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import { FormingCard, StatementCard, StateMark, useStatementRating, type StatementState } from "@/components/Cards";
import { StatementTile } from "@/components/Tiles";
import { PageHead } from "@/components/Shell";
import { NotDeployed } from "@/components/NotDeployed";
import { EmptyNote, Sk, SkCard } from "@/components/Skeleton";
import { useComposeEta } from "@/components/ComposeEta";
import { engineDeployed, STATEMENT_SIZE } from "@/lib/config";
import { useHistoryDown, useStatementIndex, useStats } from "@/lib/data";
import { useBlockTs } from "@/lib/engine";
import { useTokenMeta } from "@/lib/art";
import { useNow, usePile, useSnapshot, useStatements } from "@/lib/live";
import { etaLabel } from "@/lib/compose-eta";
import { formingPages, formingWhen } from "@/lib/forming";
import { agoLabel, eth, signedPct } from "@/lib/format";

const PAGE = 24;
type View = "grid" | "table";
type Sort = "newest" | "price";

interface Item {
  id: number;
  state: StatementState;
  price?: bigint; // asking price while held, sale price once sold
  cost?: bigint;
  raw?: bigint; // on-chain rating while held
  composedAt?: number;
  block?: bigint; // compose block (chain mode), for the time when the statement is no longer held
  format?: number;
  formatName?: string | null;
}

// Every statement the Core composed. Held: asking price from the controller (priceOf), "for sale" until the price
// reaches its floor. Sold, redeemed and not held: the indexer's statement rows.
export default function StatementsPage() {
  const { data: snap } = useSnapshot();
  const { data: held, isPending: heldPending } = useStatements();
  const { data: index, loading: indexLoading } = useStatementIndex();
  const historyDown = useHistoryDown();
  const { data: stats } = useStats();
  const { data: pile, loading: pileLoading } = usePile();
  const eta = useComposeEta(pile, 15000);
  const [view, setView] = useState<View>("grid");
  const [sort, setSort] = useState<Sort>("newest");
  const [shown, setShown] = useState(PAGE);

  const items = useMemo(() => {
    const heldBy = new Map(held.map((s) => [s.sid, s]));
    const rows = new Map(index.map((r) => [r.id, r]));
    const ids = [...new Set([...heldBy.keys(), ...rows.keys()])];
    const out: Item[] = ids.map((id) => {
      const h = heldBy.get(id);
      const r = rows.get(id);
      const base = { id, format: r?.format, formatName: r?.formatName, composedAt: h?.composedAt ?? r?.composedAt, block: r?.block };
      if (h) return { ...base, state: h.atFloor ? "at floor" : "for sale", price: h.price, cost: h.cost, raw: h.rating };
      if (r?.soldPrice != null) return { ...base, state: "sold", price: r.soldPrice, cost: r.cost, raw: r.rating };
      if (r?.redeemed) return { ...base, state: "redeemed", cost: r.cost, raw: r.rating };
      return { ...base, state: "not held", cost: r?.cost, raw: r?.rating };
    });
    out.sort((a, b) => {
      if (sort === "price") return Number((a.price ?? 2n ** 255n) - (b.price ?? 2n ** 255n)) || b.id - a.id;
      return b.id - a.id;
    });
    return out;
  }, [held, index, sort]);

  if (!engineDeployed) return <NotDeployed />;

  const forSale = items.filter((i) => i.state === "for sale" || i.state === "at floor");
  const rest = items.filter((i) => i.state !== "for sale" && i.state !== "at floor");
  const count = (s: StatementState) => items.filter((i) => i.state === s).length;
  const next = eta.at(0);
  // statements forming in the pile, before they compose: page k of the pile is statement nextStatementId + k
  const { pages: forming, incomplete: pileIncomplete } = formingPages({
    ids: (pile ?? []).map((c) => c.id),
    pileSize: snap ? Number(snap.pileSize) : 0,
    size: STATEMENT_SIZE,
    nextSid: snap?.nextStatementId,
    ready: snap?.page.ready ?? false,
  });

  // held statements come from the snapshot and its multicall, the rest from history: each part shows once it answered
  const heldLoading = !snap || heldPending;
  const loading = heldLoading || indexLoading;
  const meta = loading ? undefined : [
    `${forSale.length} for sale`,
    `${count("sold")} sold`,
    (snap?.balanceOn || count("redeemed") > 0) && `${count("redeemed")} redeemed`,
    count("not held") > 0 && `${count("not held")} not held`,
    stats && `${stats.composed} composed`,
    historyDown && "history unavailable",
    snap?.paused ? "composition paused" : next && `next composes in ${etaLabel(next)}`,
  ].filter(Boolean).join(" · ");
  // skeleton cards: as many as the snapshot holds for sale; the history count is not known before it loads
  const skCards = (n: number) => Array.from({ length: n }, (_, i) => <SkCard key={i} rows={2} />);
  const restCount = stats ? Math.max(0, stats.composed - (snap?.held.length ?? 0)) : 6;

  const more = (total: number) => total > 0 && (
    <div className="more-row">
      <span className="muted">
        showing {Math.min(shown, total)} of {total}
      </span>
      {shown < total && (
        <button className="linkbtn" onClick={() => setShown((n) => n + PAGE)}>
          load more
        </button>
      )}
    </div>
  );

  return (
    <div>
      <PageHead title="statements" ink="y" meta={meta} metaW="52ch" metaLines={2}>
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
          </select>
        </label>
      </PageHead>

      <div className="split-pad">
        {pileLoading && (
          <section className="sect" aria-busy="true">
            <div className="sect-head">
              <b>forming</b>
              <Sk w="40ch" className="caption" />
            </div>
            <div className="cgrid">{skCards(Math.max(1, Math.ceil(Number(snap?.pileSize ?? 80n) / STATEMENT_SIZE)))}</div>
          </section>
        )}
        {!pileLoading && (forming.length > 0 || pileIncomplete) && (
          <section className="sect">
            <div className="sect-head">
              <b>forming</b>
              <span className="caption">
                {pileIncomplete
                  ? "Additional forming pages are unavailable until the full pile loads."
                  : `Credits compose into Statements ${STATEMENT_SIZE} at a time, oldest first, once a page's newest Credit clears the sale window.`}
              </span>
            </div>
            <div className="cgrid">
              {forming.map((f) => (
                <FormingCard
                  key={f.k}
                  kind={f.kind}
                  sid={f.sid}
                  ids={f.ids}
                  size={STATEMENT_SIZE}
                  foot={formingWhen(f, eta.at(f.k * STATEMENT_SIZE), Boolean(snap?.paused), STATEMENT_SIZE)}
                />
              ))}
            </div>
          </section>
        )}
        {view === "grid" ? (
          <>
            <section className="sect">
              <div className="sect-head">
                <b>for sale</b>
                {snap?.statementDecayHours != null && <span className="caption">price falls over {snap.statementDecayHours}h to its floor</span>}
              </div>
              {heldLoading ? (
                snap?.held.length === 0 ? null : <div className="cgrid">{skCards(snap?.held.length ?? 6)}</div>
              ) : forSale.length === 0 ? (
                <EmptyNote>no statements for sale right now. each one lists here as soon as it composes.</EmptyNote>
              ) : (
                <div className="cgrid">
                  {forSale.map((i) => (
                    <StatementCard key={i.id} id={i.id} state={i.state} price={i.price} raw={i.raw} />
                  ))}
                </div>
              )}
              {heldLoading && snap?.held.length === 0 && <EmptyNote>no statements for sale right now. each one lists here as soon as it composes.</EmptyNote>}
            </section>
            <section className="sect">
              <div className="sect-head">
                <b>sold &amp; redeemed</b>
                <span className="caption">
                  {loading ? (
                    <Sk w="18ch" />
                  ) : (
                    <>
                      {count("sold")} sold · {count("redeemed")} redeemed
                    </>
                  )}
                </span>
              </div>
              {loading ? (
                restCount > 0 && <div className="cgrid">{skCards(Math.min(PAGE, restCount))}</div>
              ) : rest.length === 0 ? (
                <EmptyNote>none yet. statements sold or redeemed by the engine are kept here.</EmptyNote>
              ) : (
                <div className="cgrid">
                  {rest.slice(0, shown).map((i) => (
                    <StatementCard key={i.id} id={i.id} state={i.state} price={i.price} raw={i.raw} />
                  ))}
                </div>
              )}
              {loading && restCount === 0 && <EmptyNote>none yet. statements sold or redeemed by the engine are kept here.</EmptyNote>}
              {!loading && more(rest.length)}
            </section>
          </>
        ) : (
          <>
            <div className="stable">
              <div className="stable-row stable-head label">
                <span />
                <span>statement</span>
                <span className="num hide-xs">rating</span>
                <span className="hide-sm">format</span>
                <span className="num">price ETH</span>
                <span className="num hide-sm">vs cost</span>
                <span>state</span>
                <span className="num hide-sm">composed</span>
              </div>
              {loading
                ? Array.from({ length: 8 }, (_, i) => (
                    <div key={i} className="stable-row" aria-hidden>
                      <Sk block w="40px" h="40px" />
                      <Sk w="12ch" />
                      <Sk w="6ch" className="hide-xs" />
                      <Sk w="10ch" className="hide-sm" />
                      <Sk w="7ch" />
                      <Sk w="5ch" className="hide-sm" />
                      <Sk w="8ch" />
                      <Sk w="6ch" className="hide-sm" />
                    </div>
                  ))
                : items.slice(0, shown).map((i) => <Row key={i.id} i={i} />)}
              {!loading && items.length === 0 && <EmptyNote>the engine has not composed a statement yet.</EmptyNote>}
            </div>
            {!loading && more(items.length)}
          </>
        )}
      </div>
    </div>
  );
}

function Row({ i }: { i: Item }) {
  const r = useStatementRating(i.id, i.raw);
  const metaName = useTokenMeta("statement", i.id, i.formatName == null).data?.attrs.Format;
  const name = i.formatName ?? metaName;
  const { data: ts } = useBlockTs(i.composedAt == null ? i.block : undefined);
  const now = useNow(15000);
  const at = i.composedAt ?? ts;
  return (
    <div className="stable-row">
      <span className="stable-art">
        <StatementTile id={i.id} />
      </span>
      <Link href={`/statements/${i.id}`}>statement {i.id}</Link>
      <span className="num muted hide-xs">{r}</span>
      {/* format names come from statement.formatName, the Format attribute of the indexed tokenURI */}
      <span className="muted hide-sm">{i.format != null ? `${i.format} · ${name ? String(name).toLowerCase() : ""}` : ""}</span>
      <span className="num stable-price">{i.price != null ? eth(i.price) : "—"}</span>
      <span className="num muted hide-sm">
        {i.price != null && i.cost ? signedPct((Number(i.price) / Number(i.cost) - 1) * 100) : "—"}
      </span>
      <StateMark state={i.state} />
      <span className="num muted hide-sm" suppressHydrationWarning>
        {at != null ? agoLabel(now - at) : ""}
      </span>
    </div>
  );
}
