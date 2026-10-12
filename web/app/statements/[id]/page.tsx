import Link from "next/link";
import { notFound } from "next/navigation";
import { getStatement } from "@/lib/sample";
import { StatementTile, CreditTile } from "@/components/Tiles";
import { StatusBadge } from "@/components/Cards";
import { agoLabel } from "@/lib/format";

// CONNECT: load the statement from CoreLens (snapshot/statementsPage) by id, or
// 404. askingPrice falls over time — poll ControllerV1.priceOf(id) / Core.
export default function StatementDetail({ params }: { params: { id: string } }) {
  const s = getStatement(Number(params.id));
  if (!s) notFound();

  const dropPct = Math.round(((s.start - s.ask) / (s.start - s.floor)) * 100);

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
            {s.status === "sold" && (
              <p className="muted small">
                bought by {s.buyer?.slice(0, 10)}
                {"…"}
              </p>
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
