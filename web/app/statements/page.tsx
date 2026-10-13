"use client";

import { StatementCard, type StatementStatus } from "@/components/Cards";
import { NotDeployed } from "@/components/NotDeployed";
import { useSnapshot } from "@/lib/live";
import { useScan } from "@/lib/engine";
import { engineDeployed } from "@/lib/config";

// Every statement the Core composed. For sale: held by the Core, priced by
// ControllerV1 (CoreLens.snapshot().statements). Sold: StatementSoldTo logs.
// Redeemed: StatementExited logs. Not held: composed, with no sale or exit log.
export default function StatementsPage() {
  const { data: snap } = useSnapshot();
  const { data: scan } = useScan();
  if (!engineDeployed) return <NotDeployed />;

  const held = new Map((snap?.statements ?? []).map((s) => [Number(s.id), s]));
  const ids = [...new Set([...held.keys(), ...Object.keys(scan.statements).map(Number)])];
  const rank: Record<StatementStatus, number> = { listed: 0, sold: 1, redeemed: 2, "not held": 3 };
  const items = ids
    .map((id) => {
      const h = held.get(id);
      const r = scan.statements[id];
      if (h) return { id, status: "listed" as const, price: h.askingPrice, priceTag: undefined };
      if (r?.sold) return { id, status: "sold" as const, price: r.sold.price, priceTag: "sold" };
      if (r?.exited) return { id, status: "redeemed" as const, price: r.composed?.cost, priceTag: "cost" };
      return { id, status: "not held" as const, price: r?.composed?.cost, priceTag: "cost" };
    })
    .sort((a, b) => rank[a.status] - rank[b.status] || b.id - a.id);
  const count = (s: StatementStatus) => items.filter((i) => i.status === s).length;

  return (
    <main className="page wide">
      <div className="page-head">
        <h1>statements</h1>
        <span className="muted">
          {`${count("listed")} for sale · ${count("sold")} sold · ${count("redeemed")} redeemed${
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
