"use client";

import { TradePanel } from "@/components/TradePanel";
import { NotDeployed } from "@/components/NotDeployed";
import { engineDeployed } from "@/lib/config";
import { BALANCE_SYMBOL } from "@/lib/events";
import { useBalanceMarket } from "@/lib/market";
import { useSnapshot } from "@/lib/live";
import { eth } from "@/lib/format";

// Swap page of the balance token: the panel on the controller's balance pool. the balance bid pot is the module's
// holding (the Core holds none); the bid is paused while balanceBidOn is false.
export default function BalancePage() {
  const { market, loading } = useBalanceMarket();
  const { data: snap } = useSnapshot();

  if (!engineDeployed) return <NotDeployed />;

  return (
    <main className="page balance">
      {snap?.balanceOn && (
        <p className="muted">
          {BALANCE_SYMBOL} in the module: {eth(snap.balancePot)}
          {snap.settings.balanceBidOn ? "" : " · balance bid paused"}
        </p>
      )}
      {loading ? null : market ? <TradePanel market={market} /> : <p className="muted">{BALANCE_SYMBOL} is not live yet</p>}
    </main>
  );
}
