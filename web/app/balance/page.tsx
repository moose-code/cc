"use client";

import { TradePanel } from "@/components/TradePanel";
import { NotDeployed } from "@/components/NotDeployed";
import { Sk } from "@/components/Skeleton";
import { engineDeployed } from "@/lib/config";
import { BALANCE_SYMBOL, eth, formatBalance } from "@/lib/format";
import { useBalanceMarket } from "@/lib/market";
import { useBalanceToken, useSnapshot } from "@/lib/live";

// Swap page of the balance token: the panel on the controller's balance pool. the balance bid pot is the module's
// holding (the Core holds none); the bid is paused while balanceBidOn is false. the controller's reference of the token
// shows against the pool spot once the pool key is set.
export default function BalancePage() {
  const { market, loading } = useBalanceMarket();
  const { data: snap } = useSnapshot();
  const bal = useBalanceToken();

  if (!engineDeployed) return <NotDeployed />;

  return (
    <main className="page balance">
      {snap?.balanceOn && (
        <p className="muted">
          {BALANCE_SYMBOL} in the module: {snap.balanceAvailable === undefined ? "unavailable" : formatBalance(snap.balanceAvailable, bal)}
          {snap.balanceAvailable === undefined
            ? " · balance bid unavailable"
            : snap.settings.balanceBidOn
            ? ` · balance bid ${(Number(snap.balanceRate) / 100).toFixed(1)}% of par`
            : " · balance bid paused"}
        </p>
      )}
      {snap?.value.referencePrice !== undefined && snap.value.referencePrice > 0n && (
        // the protected price (decision 148): the controller's rate limited reference against the pool spot, eth per
        // whole token (1e18 base units). value mode prices the eth bid and the engine's sales off the two
        <p className="muted">
          {BALANCE_SYMBOL} reference {eth(snap.value.referencePrice, 6)} eth · spot {snap.value.spot === undefined ? "unavailable" : `${eth(snap.value.spot, 6)} eth`}
          {snap.value.spot !== undefined && ` (${((Number(snap.value.spot) / Number(snap.value.referencePrice) - 1) * 100).toFixed(1)}% from the reference)`}
          {snap.value.on ? (snap.value.usable ? " · value mode on, quote usable" : " · value mode on, quote unavailable: eth sales wait") : " · value mode off"}
        </p>
      )}
      {loading || !snap ? (
        <p className="muted" aria-busy="true">
          <Sk w="26ch" />
        </p>
      ) : market ? (
        <div className="fx-in">
          <TradePanel market={market} />
        </div>
      ) : (
        <p className="muted fx-in">{BALANCE_SYMBOL} is not live yet</p>
      )}
    </main>
  );
}
