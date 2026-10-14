"use client";

import { TradePanel } from "@/components/TradePanel";
import { NotDeployed } from "@/components/NotDeployed";
import { engineDeployed } from "@/lib/config";
import { BALANCE_SYMBOL } from "@/lib/events";
import { useBalanceMarket } from "@/lib/market";

// Swap page of the balance token: the panel on the controller's balance pool.
export default function BalancePage() {
  const { market, loading } = useBalanceMarket();

  if (!engineDeployed) return <NotDeployed />;

  return (
    <main className="page balance">
      {loading ? null : market ? <TradePanel market={market} /> : <p className="muted">{BALANCE_SYMBOL} is not live yet</p>}
    </main>
  );
}
