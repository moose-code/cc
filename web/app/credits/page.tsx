import { credits, engineBid } from "@/lib/sample";
import { CreditCard } from "@/components/Cards";

// CONNECT: replace `credits` with the engine's held credits. The pile count is
// CoreLens.snapshot().ethPileSize; enumerate ids via CreditBought logs or the
// credits NFT balanceOf(Core). engineBid = snapshot.ethRate (wei per credit).
export default function CreditsPage() {
  return (
    <main className="page">
      <div className="page-head">
        <h1>credits</h1>
        <span className="muted">
          {`${credits.length} held · bid ${engineBid} eth`}
        </span>
      </div>

      <div className="grid grid-credits">
        {credits.map((c) => (
          <CreditCard key={c.id} c={c} />
        ))}
      </div>
    </main>
  );
}
