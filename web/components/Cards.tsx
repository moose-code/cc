import Link from "next/link";
import { StatementTile } from "./Tiles";
import { commas, eth } from "@/lib/format";

export type StatementStatus = "listed" | "sold";

export function StatementCard({
  id,
  ids,
  status,
  price,
  score,
}: {
  id: number;
  ids: number[]; // the statement's composed credit ids
  status: StatementStatus;
  price: bigint; // asking price while listed, sale price once sold
  score: number; // credit score, 0 when not stored
}) {
  return (
    <Link href={`/statements/${id}`} className="card card-statement">
      <StatementTile ids={ids} />
      <div className="card-body">
        <div className="card-head">
          <span className="card-id">statement {id}</span>
          <StatusBadge status={status} />
        </div>
        <div className="card-price">
          {status === "sold" && <span className="card-price-tag">sold</span>}
          {eth(price)} eth
        </div>
        {score > 0 && (
          <div className="card-sub">
            <span>credit score</span>
            <span>{commas(score)}</span>
          </div>
        )}
      </div>
    </Link>
  );
}

export function StatusBadge({ status }: { status: StatementStatus }) {
  return <span className={`badge badge-${status}`}>{status}</span>;
}
