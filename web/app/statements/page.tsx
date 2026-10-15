"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import { StatementCard, StateMark, useStatementRating, type StatementState } from "@/components/Cards";
import { StatementTile } from "@/components/Tiles";
import { PageHead } from "@/components/Shell";
import { NotDeployed } from "@/components/NotDeployed";
import { useComposeEta } from "@/components/ComposeEta";
import { engineDeployed } from "@/lib/config";
import { useBlockTs, useScan, type StatementRecord } from "@/lib/engine";
import { useNow, usePile, useSnapshot, useStatements } from "@/lib/live";
import { useTokenMeta } from "@/lib/art";
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
  block?: bigint; // compose block, for the time when the statement is no longer held
  format?: number;
}

// Every statement the Core composed. Held: asking price from the controller (priceOf), "for sale" until the price
// reaches its floor. Sold: StatementSoldTo logs. Redeemed: StatementRedeemed logs. Not held: composed, with neither log.
export default function StatementsPage() {
  const { data: snap } = useSnapshot();
  const { data: held } = useStatements();
  const { data: scan } = useScan();
  const { data: pile } = usePile();
  const eta = useComposeEta(pile, 15000);
  const [view, setView] = useState<View>("grid");
  const [sort, setSort] = useState<Sort>("newest");
  const [shown, setShown] = useState(PAGE);

  const items = useMemo(() => {
    const heldBy = new Map(held.map((s) => [s.sid, s]));
    const ids = [...new Set([...heldBy.keys(), ...Object.keys(scan.statements).map(Number)])];
    const out: Item[] = ids.map((id) => {
      const h = heldBy.get(id);
      const r: StatementRecord | undefined = scan.statements[id];
      const base = { id, format: r?.restyled.at(-1)?.format ?? r?.composed?.format, block: r?.composed?.block };
      if (h) return { ...base, state: h.atFloor ? "at floor" : "for sale", price: h.price, cost: h.cost, raw: h.rating, composedAt: h.composedAt };
      const cost = r?.composed?.cost;
      if (r?.sold) return { ...base, state: "sold", price: r.sold.price, cost };
      if (r?.redeemed) return { ...base, state: "redeemed", cost };
      return { ...base, state: "not held", cost };
    });
    out.sort((a, b) => {
      if (sort === "price") return Number((a.price ?? 2n ** 255n) - (b.price ?? 2n ** 255n)) || b.id - a.id;
      return b.id - a.id;
    });
    return out;
  }, [held, scan.statements, sort]);

  if (!engineDeployed) return <NotDeployed />;

  const forSale = items.filter((i) => i.state === "for sale" || i.state === "at floor");
  const rest = items.filter((i) => i.state !== "for sale" && i.state !== "at floor");
  const count = (s: StatementState) => items.filter((i) => i.state === s).length;
  const next = eta.at(0);
  const meta = [
    `${forSale.length} for sale`,
    `${count("sold")} sold`,
    (snap?.balanceOn || count("redeemed") > 0) && `${count("redeemed")} redeemed`,
    count("not held") > 0 && `${count("not held")} not held`,
    `${scan.stats.composed} composed`,
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
  const name = useTokenMeta("statement", i.id).data?.attrs.Format;
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
      {/* TODO(design README open item "Statement format names"): names come from the tokenURI Format attribute. */}
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
