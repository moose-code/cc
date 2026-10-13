"use client";

import { formatEther } from "viem";
import { statements } from "@/lib/sample";
import { StatementCard } from "@/components/Cards";
import { useSnapshot } from "@/lib/live";
import { useStatementHistory } from "@/lib/engine";
import { isLive } from "@/lib/config";

const RANK = { listed: 0, held: 1, sold: 2 } as const;

// Live: the statements the Core holds (CoreLens.snapshot().statements), all for
// sale through ControllerV1, plus the sold ones (StatementSoldTo logs). The
// total is the Composed count and the redeemed ones (StatementExited) are
// counted only. Sample: the static list.
export default function StatementsPage() {
  const { data: snap } = useSnapshot();
  const { data: hist } = useStatementHistory();
  const held = (snap?.statements ?? []).map((s) => ({
    id: Number(s.id),
    status: "listed" as const,
    ask: Number(Number(formatEther(s.askingPrice)).toFixed(4)),
    score: Math.round(Number(s.rating) / 10000),
  }));
  const sold = hist.sold.map((s) => ({
    id: s.id,
    status: "sold" as const,
    ask: Number(Number(formatEther(s.price)).toFixed(4)),
    score: 0, // not stored once the statement left the engine
  }));
  const rows = isLive ? [...held, ...sold] : statements;
  const listed = rows.filter((s) => s.status === "listed").length;
  const counts = isLive
    ? `${listed} for sale · ${sold.length} sold · ${hist.exited.length} redeemed · ${hist.total} total`
    : `${listed} for sale · ${rows.length} total`;
  // listed first, then composing, then sold
  const ordered = [...rows].sort((a, b) => RANK[a.status] - RANK[b.status]);
  return (
    <main className="page wide">
      <div className="page-head">
        <h1>statements</h1>
        <span className="muted">{counts}</span>
      </div>

      <div className="grid">
        {ordered.map((s) => (
          <StatementCard key={s.id} s={s} />
        ))}
      </div>
    </main>
  );
}
