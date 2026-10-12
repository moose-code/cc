import Link from "next/link";
import { credits, engineBid } from "@/lib/sample";
import { CreditTile } from "@/components/Tiles";
import { agoLabel } from "@/lib/format";

// CONNECT: replace `credits` with the engine's held credits. Count is
// CoreLens.snapshot().ethPileSize; enumerate ids from CreditBought logs or the
// credits NFT balanceOf(Core). engineBid = snapshot.ethRate (wei per credit).
export default function CreditsPage() {
  return (
    <main className="page">
      <div className="page-head">
        <h1>credits</h1>
        <span className="muted">
          {`${credits.length} held by the engine · bid ${engineBid} eth`}
        </span>
      </div>

      <div className="rowlist">
        <div className="rowlist-head">
          <span className="rl-credit">credit</span>
          <span className="rl-meta">paid</span>
          <span className="rl-lane">lane</span>
          <span className="rl-time">bought</span>
        </div>
        {credits.map((c) => (
          <Link key={c.id} href={`/credits/${c.id}`} className="rowlink">
            <span className="rl-credit">
              <CreditTile id={c.id} />
              <span className="rl-id">credit #{c.id}</span>
            </span>
            <span className="rl-meta">{c.cost} eth</span>
            <span className="rl-lane">{c.lane}</span>
            <span className="rl-time muted">{agoLabel(c.boughtAgo)}</span>
          </Link>
        ))}
      </div>
    </main>
  );
}
