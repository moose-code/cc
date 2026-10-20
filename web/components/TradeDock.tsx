"use client";

import { engineDeployed } from "@/lib/config";
import { useCoinLive } from "@/lib/live";
import { useCcMarket, useMarketStats } from "@/lib/market";
import { PriceText, pctChange } from "./TradePanel";
import { Sk } from "./Skeleton";

// The mobile trade bar, fixed to the bottom of the home (shown at 860px and below): the $CC price and its change, and
// a buy | sell toggle that opens the trade panel as a bottom sheet on that side.
export function TradeDock({ open }: { open: (side: "buy" | "sell") => void }) {
  const live = useCoinLive();
  const { market } = useCcMarket();
  const m = engineDeployed && live === true ? market : undefined;
  const { priceUsd, change, loading } = useMarketStats(m);
  const wait = engineDeployed && live !== false && (m == null || loading);
  return (
    <div className="dock">
      <div className="dock-price">
        <span className="label">$CC</span>
        <span className="dock-big">
          {priceUsd != null ? (
            <span className="fx-in">
              <PriceText usd={priceUsd} />
            </span>
          ) : wait ? (
            <Sk w="6ch" />
          ) : (
            "—"
          )}
          {change != null && <span className={`tp-chg fx-in ${change >= 0 ? "up" : "down"}`}>{pctChange(change)}</span>}
        </span>
      </div>
      <div className="seg dock-seg">
        <button className="on" onClick={() => open("buy")}>
          buy
        </button>
        <button onClick={() => open("sell")}>sell</button>
      </div>
    </div>
  );
}
