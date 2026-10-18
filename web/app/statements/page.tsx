"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import { FormingCard, StatementCard, StateMark, useStatementRating, type StatementState } from "@/components/Cards";
import { StatementTile } from "@/components/Tiles";
import { PageHead } from "@/components/Shell";
import { NotDeployed } from "@/components/NotDeployed";
import { useComposeEta } from "@/components/ComposeEta";
import { engineDeployed, STATEMENT_SIZE } from "@/lib/config";
import { useHistoryDown, useStatementIndex, useStats } from "@/lib/data";
import { useBlockTs } from "@/lib/engine";
import { useTokenMeta } from "@/lib/art";
import { useNow, usePile, useSnapshot, useStatements } from "@/lib/live";
import { etaLabel } from "@/lib/compose-eta";
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
  const { data: held } = useStatements();
  const { data: index } = useStatementIndex();
  const historyDown = useHistoryDown();
  const { data: stats } = useStats();
  const { data: pile } = usePile();
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
  // statements forming in the pile, before they compose: full pages of credits are "upcoming" (waiting for the newest
  // credit to clear the sale window), the partial page is still "building". FIFO, so page k is credits k*size..(k+1)*size.
  const pileIds = (pile ?? []).map((c) => c.id);
  const fullPages = Math.floor(pileIds.length / STATEMENT_SIZE);
  const forming: { kind: "upcoming" | "building"; ids: number[]; foot: string }[] = [];
  for (let k = 0; k < fullPages; k++) {
    const e = eta.at(k * STATEMENT_SIZE);
    forming.push({
      kind: "upcoming",
      ids: pileIds.slice(k * STATEMENT_SIZE, (k + 1) * STATEMENT_SIZE),
      foot: e == null ? "composes next" : e.seconds <= 0 ? "ready to compose" : `composes in ${etaLabel(e)}`,
    });
  }
  const remainder = pileIds.length % STATEMENT_SIZE;
  if (remainder > 0)
    forming.push({ kind: "building", ids: pileIds.slice(fullPages * STATEMENT_SIZE), foot: `${STATEMENT_SIZE - remainder} more to compose` });

  const meta = [
    `${forSale.length} for sale`,
    `${count("sold")} sold`,
    (snap?.balanceOn || count("redeemed") > 0) && `${count("redeemed")} redeemed`,
    count("not held") > 0 && `${count("not held")} not held`,
    stats && `${stats.composed} composed`,
    historyDown && "history unavailable",
    next && `next composes in ${etaLabel(next)}`,
  ].filter(Boolean);

  const more = (total: number) => (
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
      <PageHead title="statements" ink="y" meta={meta.join(" · ")}>
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
        {forming.length > 0 && (
          <section className="sect">
            <div className="sect-head">
              <b>forming</b>
              <span className="caption">
                credits compose into statements {STATEMENT_SIZE} at a time, oldest first, once a page&apos;s newest credit clears the sale window
              </span>
            </div>
            <div className="cgrid">
              {forming.map((f, i) => (
                <FormingCard key={i} kind={f.kind} ids={f.ids} size={STATEMENT_SIZE} foot={f.foot} />
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
              <div className="cgrid">
                {forSale.map((i) => (
                  <StatementCard key={i.id} id={i.id} state={i.state} price={i.price} raw={i.raw} />
                ))}
              </div>
            </section>
            <section className="sect">
              <div className="sect-head">
                <b>sold &amp; redeemed</b>
                <span className="caption">
                  {count("sold")} sold · {count("redeemed")} redeemed
                </span>
              </div>
              <div className="cgrid">
                {rest.slice(0, shown).map((i) => (
                  <StatementCard key={i.id} id={i.id} state={i.state} price={i.price} raw={i.raw} />
                ))}
              </div>
              {more(rest.length)}
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
              {items.slice(0, shown).map((i) => (
                <Row key={i.id} i={i} />
              ))}
            </div>
            {more(items.length)}
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
