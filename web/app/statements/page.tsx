"use client";

import { StatementCard, type StatementStatus } from "@/components/Cards";
import { NotDeployed } from "@/components/NotDeployed";
import { useSnapshot, useStatements } from "@/lib/live";
import { useScan } from "@/lib/engine";
import { engineDeployed } from "@/lib/config";

// Every statement the Core composed. For sale: held by the Core, with the gross
// price the controller asks (grossPriceOf). Sold: StatementSoldTo logs.
// Redeemed: StatementRedeemed logs. Not held: composed, with no sale or redemption log.
export default function StatementsPage() {
  const { data: snap } = useSnapshot();
  const { data: held } = useStatements();
  const { data: scan } = useScan();
  if (!engineDeployed) return <NotDeployed />;

  const heldBy = new Map(held.map((s) => [s.sid, s]));
  const ids = [...new Set([...heldBy.keys(), ...Object.keys(scan.statements).map(Number)])];
  const rank: Record<StatementStatus, number> = { listed: 0, sold: 1, redeemed: 2, "not held": 3 };
  const items = ids
    .map((id) => {
      const h = heldBy.get(id);
      const r = scan.statements[id];
      if (h) return { id, status: "listed" as const, price: h.gross, priceTag: undefined };
      if (r?.sold) return { id, status: "sold" as const, price: r.sold.price, priceTag: "sold" };
      if (r?.redeemed) return { id, status: "redeemed" as const, price: r.composed?.cost, priceTag: "cost" };
      return { id, status: "not held" as const, price: r?.composed?.cost, priceTag: "cost" };
    })
    .sort((a, b) => rank[a.status] - rank[b.status] || b.id - a.id);
  const count = (s: StatementStatus) => items.filter((i) => i.status === s).length;

  return (
    <main className="page wide">
      <div className="page-head">
        <h1>statements</h1>
        <span className="muted">
          {`${count("listed")} for sale · ${count("sold")} sold${snap?.balanceOn ? ` · ${count("redeemed")} redeemed` : ""}${
            count("not held") ? ` · ${count("not held")} not held` : ""
          } · ${scan.stats.composed} composed`}
        </span>
      </div>

      <div className="grid">
        {items.map((s) => (
          <StatementCard key={s.id} {...s} />
        ))}
      </div>
    </main>
  );
}
