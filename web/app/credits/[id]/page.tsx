import Link from "next/link";
import { getCredit, type SampleCredit } from "@/lib/sample";
import { CreditTile } from "@/components/Tiles";
import { agoLabel } from "@/lib/format";

// A credit the engine owns. Either held in the pile awaiting the next compose,
// or already composed into a statement. No user action here — the engine owns
// it. Selling a credit TO the engine happens on /sell.
//
// CONNECT: load the credit by id. Held credits come from the pile; a composed
// credit maps to its statement via the Core compose record. `cost` is the price
// the engine paid, from the CreditBought event.
export default function CreditDetail({ params }: { params: { id: string } }) {
  const c = resolveCredit(Number(params.id));

  return (
    <main className="page detail">
      <Link href="/credits" className="back">
        {"← credits"}
      </Link>

      <div className="detail-grid">
        <div className="detail-art credit-art">
          <CreditTile id={c.id} />
        </div>

        <div className="detail-main">
          <div className="detail-title">
            <h1>credit #{c.id}</h1>
          </div>

          <div className="statuspanel">
            {c.composed ? (
              <p>
                composed into{" "}
                <Link href={`/statements/${c.statementId}`} className="xlink-inline">
                  statement #{c.statementId}
                </Link>
                .
              </p>
            ) : (
              <p>
                held by the engine, awaiting compose into statement #
                {c.statementId}. the engine composes 80 credits into a
                statement.
              </p>
            )}
          </div>

          <div className="facts">
            <Fact k="owner" v="engine" />
            <Fact k="lane" v={c.lane} />
            <Fact k="paid by engine" v={c.cost ? `${c.cost} eth` : "—"} />
            <Fact
              k={c.composed ? "composed" : "bought"}
              v={agoLabel(c.boughtAgo)}
            />
          </div>

          {c.statementId && (
            <Link href={`/statements/${c.statementId}`} className="xlink">
              {`view statement #${c.statementId} →`}
            </Link>
          )}
        </div>
      </div>
    </main>
  );
}

type ResolvedCredit = Omit<SampleCredit, "cost"> & {
  cost: number | null;
  composed: boolean;
};

// Held credits exist in the sample (awaiting compose). A credit id drawn from a
// statement's grid is synthesized and marked composed, so every tile links to a
// real page.
function resolveCredit(id: number): ResolvedCredit {
  const held = getCredit(id);
  if (held) return { ...held, cost: held.cost, composed: false };
  const sid = id >= 40000 ? Math.floor((id - 40000) / 80) : null;
  return { id, lane: "eth", cost: null, statementId: sid, boughtAgo: 3600, composed: true };
}

function Fact({ k, v }: { k: string; v: string }) {
  return (
    <div className="fact">
      <span className="muted">{k}</span>
      <span>{v}</span>
    </div>
  );
}
