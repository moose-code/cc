import type { Metadata } from "next";
import { claimEnabled } from "@/lib/exchange-access";
import "../exchange/exchange.css";

export const metadata: Metadata = {
  title: "claim",
  description: "Burn $CC for a proportional share of the treasury's claim reserve, with a protected minimum payout.",
  robots: { index: false, follow: false },
};

// The server gate of /claim: closed in production and deploy previews unless CLAIM_ENABLED is exactly "true", open in
// local development. While closed the route renders this notice alone; the client page, and with it every read of the
// treasury's claim views, is never rendered.
export default function ClaimLayout({ children }: { children: React.ReactNode }) {
  if (!claimEnabled(process.env.NODE_ENV, process.env.CLAIM_ENABLED)) {
    return (
      <div className="claim-page">
        <section className="claim-panel claim-panel-notice" aria-labelledby="claim-title">
          <h2 id="claim-title">Burn $CC for $BALANCE</h2>
          <p role="status">$CC burns are not open yet. The claim reserve accumulates from each Statement conversion; this page opens when the owner turns the treasury&apos;s redemption switch on.</p>
        </section>
      </div>
    );
  }
  return children;
}
