import Link from "next/link";
import { StatementTile, CreditTile } from "./Tiles";
import { signedPct } from "@/lib/format";
import type { SampleStatement, SampleCredit } from "@/lib/sample";

export function StatementCard({ s }: { s: SampleStatement }) {
  const overCost = (s.ask / s.cost - 1) * 100;
  return (
    <Link href={`/statements/${s.id}`} className="card card-statement">
      <StatementTile id={s.id} />
      <div className="card-body">
        <div className="card-head">
          <span className="card-id">statement {s.id}</span>
          <StatusBadge status={s.status} />
        </div>
        <div className="card-rows">
          <Row
            k={s.status === "sold" ? "sold for" : s.status === "held" ? "cost" : "price"}
            v={`${s.status === "held" ? s.cost : s.ask} eth`}
          />
          {s.status !== "held" && <Row k="vs cost" v={signedPct(overCost)} />}
          <Row k="credits" v="80" />
        </div>
      </div>
    </Link>
  );
}

export function CreditCard({ c }: { c: SampleCredit }) {
  return (
    <Link href={`/credits/${c.id}`} className="card card-credit">
      <CreditTile id={c.id} />
      <div className="card-body">
        <div className="card-head">
          <span className="card-id">credit #{c.id}</span>
        </div>
        <div className="card-rows">
          <Row k="paid" v={`${c.cost} eth`} />
          <Row
            k="statement"
            v={c.statementId ? `#${c.statementId}` : "pending"}
          />
        </div>
      </div>
    </Link>
  );
}

export function StatusBadge({ status }: { status: SampleStatement["status"] }) {
  return <span className={`badge badge-${status}`}>{status}</span>;
}

function Row({ k, v }: { k: string; v: string }) {
  return (
    <div className="r">
      <span>{k}</span>
      <span>{v}</span>
    </div>
  );
}
