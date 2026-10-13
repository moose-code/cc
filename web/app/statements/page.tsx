"use client";

import { StatementCard } from "@/components/Cards";
import { NotDeployed } from "@/components/NotDeployed";
import { useSnapshot } from "@/lib/live";
import { useStatementHistory } from "@/lib/engine";
import { engineDeployed } from "@/lib/config";

// The statements the Core holds (CoreLens.snapshot().statements), all for sale
// through ControllerV1, then the sold ones (StatementSoldTo logs). The total is
// the Composed count; redeemed ones (StatementExited) are counted only. Credit
// ids per statement come from the Composed logs.
export default function StatementsPage() {
  const { data: snap } = useSnapshot();
  const { data: hist } = useStatementHistory();
  if (!engineDeployed) return <NotDeployed />;

  const listed = (snap?.statements ?? []).map((s) => ({
    id: Number(s.id),
    status: "listed" as const,
    price: s.askingPrice,
    score: Math.round(Number(s.rating) / 10000),
  }));
  const sold = hist.sold.map((s) => ({
    id: s.id,
    status: "sold" as const,
    price: s.price,
    score: 0, // not stored once the statement left the engine
  }));
  return (
    <main className="page wide">
      <div className="page-head">
        <h1>statements</h1>
        <span className="muted">
          {`${listed.length} for sale · ${sold.length} sold · ${hist.exited.length} redeemed · ${hist.total} total`}
        </span>
      </div>

      <div className="grid">
        {[...listed, ...sold].map((s) => (
          <StatementCard key={s.id} {...s} ids={hist.composed[s.id]?.ids ?? []} />
        ))}
      </div>
    </main>
  );
}
