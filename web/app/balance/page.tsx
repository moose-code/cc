"use client";

import { TradePanel } from "@/components/TradePanel";
import { NotDeployed } from "@/components/NotDeployed";
import { engineDeployed } from "@/lib/config";
import { BALANCE_SYMBOL } from "@/lib/events";
import { useBalanceMarket, useTokensPerEth } from "@/lib/market";

// Swap page of the balance token: the panel on the controller's balance pool.
export default function BalancePage() {
  const { market, loading } = useBalanceMarket();
  const { data: perEth } = useTokensPerEth(market);

  if (!engineDeployed) return <NotDeployed />;

  return (
    <main className="page balance">
      <div className="page-head">
        <h1>{BALANCE_SYMBOL}</h1>
      </div>
      {loading ? null : market ? (
        <>
          <p className="muted">1 {BALANCE_SYMBOL} = {perEth ? (1 / perEth).toFixed(9) : "—"} eth</p>
          <TradePanel market={market} />
        </>
      ) : (
        <p className="muted">{BALANCE_SYMBOL} is not live yet</p>
      )}
    </main>
  );
}
