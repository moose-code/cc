import Link from "next/link";
import { StatementTile, CreditTile } from "./Tiles";
import type { SampleStatement, SampleCredit } from "@/lib/sample";

export function StatementCard({ s }: { s: SampleStatement }) {
  return (
    <Link href={`/statements/${s.id}`} className="card">
      <StatementTile id={s.id} />
      <div className="card-body">
        <div className="card-head">
          <span className="card-id">statement {s.id}</span>
          <StatusBadge status={s.status} />
        </div>
        <div className="card-rows">
          <Row k={s.status === "sold" ? "sold for" : "price"} v={`${s.ask} eth`} />
          <Row k="cost" v={`${s.cost} eth`} />
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
