import Link from "next/link";
import { getCredit, engineBid, type SampleCredit } from "@/lib/sample";
import { CreditTile } from "@/components/Tiles";
import { agoLabel } from "@/lib/format";

// CONNECT: load the credit by id. A held credit comes from the engine's pile;
// a composed one maps to its statement. The user action is selling a credit to
// the engine: Core.sellForEth([ids]) pays the bid (snapshot.ethRate), or the
// engine takes a listing via buyListing. Gate on who owns the credit.
export default function CreditDetail({ params }: { params: { id: string } }) {
  const id = Number(params.id);
  const c = resolveCredit(id);

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

          {/* CONNECT: sell-to-engine -> Core.sellForEth([id]) for the bid, or
              buyListing for a listed credit. Show the bid, min out, who owns it. */}
          <div className="buybox">
            <div className="buybox-price">
              <span className="muted">engine bid</span>
              <span className="big">{engineBid} eth</span>
            </div>
            <button className="action" disabled>
              sell to engine
            </button>
            <p className="muted small">
              the engine buys every credit at the bid, then composes 80 into a
              statement.
            </p>
          </div>

          <div className="facts">
            <Fact k="lane" v={c.lane} />
            <Fact k="paid by engine" v={c.cost ? `${c.cost} eth` : "—"} />
            <Fact
              k="statement"
              v={c.statementId ? `#${c.statementId}` : "pending"}
            />
            <Fact k="bought" v={agoLabel(c.boughtAgo)} />
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

// Held credits exist in the sample; a composed credit is synthesized from its
// id so any tile in a statement's grid links somewhere real.
function resolveCredit(id: number): Omit<SampleCredit, "cost"> & { cost: number | null } {
  const held = getCredit(id);
  if (held) return { ...held, cost: held.cost };
  const sid = id >= 40000 ? Math.floor((id - 40000) / 80) : null;
  return { id, lane: "eth", cost: null, statementId: sid, boughtAgo: 3600 };
}

function Fact({ k, v }: { k: string; v: string }) {
  return (
    <div className="fact">
      <span className="muted">{k}</span>
      <span>{v}</span>
    </div>
  );
}
