import Link from "next/link";
import { notFound } from "next/navigation";
import { getStatement } from "@/lib/sample";
import { StatementTile, CreditTile } from "@/components/Tiles";
import { StatusBadge } from "@/components/Cards";
import { Addr } from "@/components/Addr";
import { agoLabel, signedPct } from "@/lib/format";

// CONNECT: load the statement from CoreLens (snapshot/statementsPage) by id, or
// 404. askingPrice falls over time — poll ControllerV1.priceOf(id) / Core.
export default function StatementDetail({ params }: { params: { id: string } }) {
  const s = getStatement(Number(params.id));
  if (!s) notFound();

  const dropPct = Math.round(((s.start - s.ask) / (s.start - s.floor)) * 100);
  const overCostNow = (s.ask / s.cost - 1) * 100;
  const overCostList = (s.start / s.cost - 1) * 100;

  return (
    <main className="page detail">
      <Link href="/statements" className="back">
        {"← statements"}
      </Link>

      <div className="detail-grid">
        <div className="detail-art">
          <StatementTile id={s.id} size={12} />
        </div>

        <div className="detail-main">
          <div className="detail-title">
            <h1>statement {s.id}</h1>
            <StatusBadge status={s.status} />
          </div>

          {/* CONNECT: buy -> ControllerV1.buy(id) payable at priceOf(id), or
              Core buy path. Show live price, min received, wallet balance. */}
          <div className="buybox">
            <div className="buybox-price">
              <span className="muted">
                {s.status === "sold" ? "sold for" : "current price"}
              </span>
              <span className="big">{s.ask} eth</span>
            </div>
            {s.status === "listed" && (
              <>
                <div className="price-bar">
                  <i style={{ width: `${100 - dropPct}%` }} />
                </div>
                <div className="price-ends muted">
                  <span>floor {s.floor}</span>
                  <span>start {s.start}</span>
                </div>
                <button className="action" disabled>
                  buy statement
                </button>
                <p className="muted small">
                  price falls from start toward the floor until someone buys.
                </p>
              </>
            )}
            {s.status === "held" && (
              <p className="muted small">
                {"composing · not yet listed for sale."}
              </p>
            )}
          </div>

          <div className="facts">
            <Fact k="lane" v={s.lane} />
            <Fact k="cost" v={`${s.cost} eth`} />
            <Fact k="credits" v="80" />
            <Fact k="composed" v={agoLabel(s.composedAgo)} />
          </div>

          <section className="section history-section">
            <h2>history</h2>
            {/* CONNECT: build from events — Composed, the listing, StatementSoldTo
                (price + buyer). % over cost = price / cost - 1. */}
            <div className="history">
              <HistRow
                label="composed"
                value={`${s.cost} eth cost`}
                ago={agoLabel(s.composedAgo)}
              />
              {s.status !== "held" && (
                <HistRow
                  label="listed"
                  value={`${s.start} eth`}
                  note={`${signedPct(overCostList)} over cost`}
                />
              )}
              {s.status === "listed" && (
                <HistRow
                  label="current price"
                  value={`${s.ask} eth`}
                  note={`${signedPct(overCostNow)} over cost`}
                />
              )}
              {s.status === "sold" && (
                <HistRow
                  label="sold"
                  value={`${s.ask} eth`}
                  note={`${signedPct(overCostNow)} over cost`}
                  addr={s.buyer}
                />
              )}
              {s.status === "held" && (
                <HistRow label="awaiting listing" value={"—"} />
              )}
            </div>
          </section>
        </div>
      </div>

      <section className="section">
        <h2>composed credits</h2>
        <span className="muted">the 80 credits in this statement</span>
        {/* CONNECT: the actual composed credit ids (Core compose record). */}
        <div className="credit-mini-grid">
          {s.creditIds.map((id) => (
            <Link key={id} href={`/credits/${id}`} title={`credit #${id}`}>
              <CreditTile id={id} />
            </Link>
          ))}
        </div>
      </section>
    </main>
  );
}

function Fact({ k, v }: { k: string; v: string }) {
  return (
    <div className="fact">
      <span className="muted">{k}</span>
      <span>{v}</span>
    </div>
  );
}

function HistRow({
  label,
  value,
  note,
  ago,
  addr,
}: {
  label: string;
  value: string;
  note?: string;
  ago?: string;
  addr?: string;
}) {
  return (
    <div className="hrow">
      <span className="hlabel">{label}</span>
      <span className="hval">
        {value}
        {note && <span className="muted"> ({note})</span>}
        {addr && (
          <>
            {" by "}
            <Addr address={addr} />
          </>
        )}
      </span>
      {ago && <span className="muted hago">{ago}</span>}
    </div>
  );
}
