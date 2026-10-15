"use client";

import { useStats } from "@/lib/engine";
import { useSnapshot } from "@/lib/live";
import { engineDeployed } from "@/lib/config";
import { BALANCE_SYMBOL } from "@/lib/events";
import { commas, ethShort } from "@/lib/format";

// Subtle utility bar under the header: the engine's running totals.
export function StatsBar() {
  const { data: s } = useStats();
  const { data: snap } = useSnapshot();
  const on = engineDeployed;
  const bought = s.creditsEth + s.creditsBalance + s.creditsListing;
  return (
    <div className="statsbar">
      <Stat
        label="credits bought"
        value={
          on
            ? `${commas(bought)} (${commas(s.creditsEth)} eth bid${snap?.balanceOn ? ` · ${commas(s.creditsBalance)} ${BALANCE_SYMBOL} bid` : ""} · ${commas(s.creditsListing)} listing)`
            : "—"
        }
      />
      <Stat label="credits adopted" value={on ? commas(s.creditsAdopted) : "—"} />
      <Stat
        label="statements"
        value={on ? `${commas(s.composed)} composed · ${commas(s.sold)} sold${snap?.balanceOn ? ` · ${commas(s.redeemed)} redeemed` : ""}` : "—"}
      />
      <Stat label="eth into credits" value={on ? s.ethIntoCredits.toLocaleString("en-US", { maximumFractionDigits: 3 }) : "—"} />
      <Stat label="buybacks" value={on ? commas(s.buybacks) : "—"} />
      <Stat label="cc burned" value={on ? commas(s.ccBurned) : "—"} />
      <Stat label="redeem burn pot" value={on && snap ? `${ethShort(snap.ethRedeemBurn, 4)} eth` : "—"} />
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="stat">
      <span className="label">{label}</span>
      <span className="value">{value}</span>
    </div>
  );
}
