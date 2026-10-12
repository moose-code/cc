import { statements } from "@/lib/sample";
import { StatementCard } from "@/components/Cards";

// CONNECT: replace `statements` with CoreLens.snapshot().statements (held +
// listed) plus sold statements from StatementSoldTo logs. Each needs id, lane,
// cost, askingPrice (ControllerV1.priceOf / Core), composedAt, status.
export default function StatementsPage() {
  const listed = statements.filter((s) => s.status === "listed").length;
  return (
    <main className="page wide">
      <div className="page-head">
        <h1>statements</h1>
        <span className="muted">
          {`${listed} for sale · ${statements.length} total`}
        </span>
      </div>

      {/* CONNECT: filter/sort (all / for sale / sold / held) — static for now */}
      <div className="grid">
        {statements.map((s) => (
          <StatementCard key={s.id} s={s} />
        ))}
      </div>
    </main>
  );
}
