"use client";

import { useMemo, useState } from "react";
import { useReadContract, useReadContracts } from "wagmi";
import { formatUnits, parseUnits, type Address } from "viem";
import { core, credits, isLocal } from "@/lib/config";
import { coreAbi, erc20Abi } from "@/lib/abis";
import { useSnapshot } from "@/lib/live";
import { useBalanceMarket, useEthUsd, useQuote, useTokensPerEth, type Market } from "@/lib/market";
import { useMarketView, viewLines, viewLive } from "@/lib/market-view";
import { makePoolKey } from "@/lib/v4core";
import {
  parseAsks, postedBalance, grossBalance, workingSurplus,
  ethPerPoint, ethValueAtSpot, relativeGap, type CreditAsk,
} from "@/lib/credit-balance-compare";
import "./market-compare.css";

const PERCENT_BPS = 8000; // Selected Stage B settings; preview only until Core BALANCE bids are enabled.
const READ_ROWS = 40;
const MAX_VIEW_ROWS = 1000;
const KNOWN_MAINNET_BALANCE = "0x3620540c994433D7B4a628C46d2ED5F92572eA07" as Address;
const formattedEth = (wei?: bigint) => wei == null ? "—" :
  Number(formatUnits(wei, 18)).toLocaleString("en-US", { maximumFractionDigits: 6 });
const formattedBal = (amount?: bigint) => amount == null ? "—" :
  Number(formatUnits(amount, 18)).toLocaleString("en-US", { maximumFractionDigits: 2 });
const digits = (v: number | undefined, n = 5) => v == null || !Number.isFinite(v) ? "—" :
  v.toLocaleString("en-US", { maximumFractionDigits: n });
const signed = (v?: number) => v == null || !Number.isFinite(v) ? "—" :
  (v > 0 ? "+" : "") + digits(v, 1) + "%";
const validAddress = (v?: string): v is Address => Boolean(v && /^0x[0-9a-fA-F]{40}$/.test(v));

// Pre-Stage C operator preview: prefer the ControllerV2 onchain pool key once configured.
// Before it is wired, require a VERIFIED v4 pool tuple from explicit web environment.
// Never silently assume a hook / tick spacing / fee from a market cap.
function useComparisonPool(): { market?: Market; source: string; error?: string } {
  const live = useBalanceMarket();
  const rawToken = process.env.NEXT_PUBLIC_COMPARE_BALANCE_TOKEN;
  const rawFee = process.env.NEXT_PUBLIC_COMPARE_POOL_FEE;
  const rawTick = process.env.NEXT_PUBLIC_COMPARE_POOL_TICK_SPACING;
  const rawHook = process.env.NEXT_PUBLIC_COMPARE_POOL_HOOK;
  const token = rawToken ? validAddress(rawToken) ? rawToken : undefined : isLocal ? undefined : KNOWN_MAINNET_BALANCE;
  const valid = Boolean(token && rawFee && rawTick && validAddress(rawHook) &&
    /^\d+$/.test(rawFee) && /^-?\d+$/.test(rawTick) &&
    Number.isSafeInteger(Number(rawFee)) && Number.isSafeInteger(Number(rawTick)) &&
    Number(rawFee) >= 0 && Number(rawFee) <= 0xffffff &&
    Number(rawTick) > 0 && Number(rawTick) <= 887272);
  const metadata = useReadContract({
    address: token,
    abi: erc20Abi,
    functionName: "decimals",
    query: { enabled: valid, staleTime: Infinity },
  });
  const fallback = useMemo<Market | undefined>(() => {
    if (!valid || !token || !rawHook || metadata.data !== 18) return undefined;
    return {
      token, symbol: "BALANCE", decimals: 18,
      key: makePoolKey(token, Number(rawFee), Number(rawTick), rawHook as Address),
    };
  }, [valid, token, rawHook, rawFee, rawTick, metadata.data]);

  if (live.market) return { market: live.market, source: "controller pool (onchain)" };
  if (fallback) return { market: fallback, source: "configured v4 pool (operator)" };
  if (metadata.isError) return { source: "unavailable", error: "Configured BALANCE token could not be verified." };
  return { source: "unavailable", error: "Set a verified BALANCE pool tuple or wire ControllerV2 Stage C." };
}

type Prepared = { key: string; row: CreditAsk; bid?: bigint; executable: boolean };

export default function MarketComparisonPage() {
  const { data: snap } = useSnapshot();
  const marketView = useMarketView();
  const marketData = marketView.data;
  const observed = marketData?.view;
  const pool = useComparisonPool();
  const spot = useTokensPerEth(pool.market);
  const usd = useEthUsd();
  const [focus, setFocus] = useState("manual");
  const [manualRating, setManualRating] = useState("300");
  const [manualAsk, setManualAsk] = useState("0.017");
  const [shown, setShown] = useState(20);
  const now = Date.now();
  const fresh = viewLive(marketData, now);

  const asks = useMemo(() => {
    const os = (observed?.rows ?? []).filter((r) => r.endTime > Math.floor(now / 1000));
    return parseAsks(os, observed?.strategy.rows ?? []).slice(0, MAX_VIEW_ROWS);
  // Listings identity and status are updated by useMarketView's 10-second poll.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [observed]);
  const visible = asks.slice(0, Math.min(shown, READ_ROWS));
  const hasBid = Boolean(core && snap?.balanceOn && snap?.settings.balanceBidOn);
  const bidReads = useReadContracts({
    contracts: visible.map((r) => ({
      address: core!, abi: coreAbi, functionName: "balanceBidOf" as const, args: [BigInt(r.id)] as const,
    })),
    query: { enabled: hasBid && visible.length > 0, refetchInterval: 15_000 },
  });
  const prepared: Prepared[] = visible.map((row, i) => {
    const result = bidReads.data?.[i];
    const actual = hasBid && result?.status === "success" ? result.result as bigint : undefined;
    return {
      key: row.source + ":" + row.id,
      row,
      // Preview cannot be confused with a live Core quote.
      bid: hasBid ? actual : postedBalance(row.score, PERCENT_BPS),
      executable: hasBid && actual !== undefined && actual > 0n,
    };
  });

  const manualScore = useMemo(() => {
    try {
      return /^\d+(\.\d{0,4})?$/.test(manualRating) ? parseUnits(manualRating, 4) : 0n;
    } catch { return 0n; }
  }, [manualRating]);
  const manualWei = useMemo(() => {
    try {
      return /^\d+(\.\d{0,18})?$/.test(manualAsk) ? parseUnits(manualAsk, 18) : 0n;
    } catch { return 0n; }
  }, [manualAsk]);
  const manual: Prepared = {
    key: "manual",
    row: { id: "manual", source: "OpenSea", priceWei: manualWei, score: manualScore },
    bid: manualScore > 0n ? postedBalance(manualScore, PERCENT_BPS) : undefined,
    executable: false,
  };
  const selected = prepared.find((v) => v.key === focus) ?? manual;
  const selectedAsk = selected.row.priceWei;
  const selectedBid = selected.bid;
  const exact = useQuote(pool.market, "sell", selectedBid ?? 0n);
  const spotPerEth = spot.data;
  const selectedSpotEth = selectedBid != null ? ethValueAtSpot(selectedBid, spotPerEth) : undefined;
  const exactGap = exact.data != null ? relativeGap(Number(formatUnits(exact.data, 18)), selectedAsk) : undefined;
  const atOffer = prepared.filter((r) => r.bid !== undefined &&
    (relativeGap(ethValueAtSpot(r.bid, spotPerEth), r.row.priceWei) ?? -Infinity) >= 0).length;

  return (
    <main className="compare">
      <div className="compare-heading">
        <span className="compare-eyebrow">CC / OPERATOR · READ ONLY</span>
        <h1>credits / balance</h1>
        <p>Compare NFT asking prices with their rating value in $BALANCE. This page does not buy, sell or change engine settings.</p>
      </div>

      <div className="compare-stats" aria-label="market reference">
        <div><span>BALANCE per ETH</span><strong>{digits(spotPerEth, 2)}</strong><small>{pool.source}</small></div>
        <div><span>BALANCE in ETH</span><strong>{spotPerEth ? digits(1 / spotPerEth, 8) : "—"}</strong><small>v4 spot, not a sale quote</small></div>
        <div><span>BALANCE in USD</span><strong>{spotPerEth && usd.data ? "$" + digits(usd.data / spotPerEth, 4) : "—"}</strong><small>Chainlink ETH/USD × pool spot</small></div>
        <div><span>Credit payout</span><strong>{hasBid ? digits(Number(snap!.balanceRate) / 100, 2) + "%" : "80% preview"}</strong><small>{hasBid ? "live Core; may clamp by ID" : "not an active CC offer"}</small></div>
      </div>

      {(!pool.market || !spotPerEth) && (
        <p className="compare-warning" role="status">
          {pool.error ?? "No initialized BALANCE v4 pool price is available for this key."}
          {" "}ETH/BALANCE equivalences are hidden until a valid pool is available.
        </p>
      )}
      {!hasBid && <p className="compare-note">The Credit → BALANCE exchange is not live. The 80% column below is a hypothetical payout, not a redeemable offer.</p>}
      {!fresh && <p className="compare-warning" role="status">Listings are unavailable or stale. Displayed asks must not be treated as fillable. {viewLines(marketData, now).join(" ")}</p>}

      <section className="compare-section">
        <div className="compare-section-head">
          <div><h2>compare any credit</h2><p>Rating and ETH asking price, independent of marketplace availability.</p></div>
          <span>select a row below to inspect it</span>
        </div>
        <div className="compare-manual">
          <label>rating (points)<input inputMode="decimal" value={manualRating} onChange={(e) => { setManualRating(e.target.value); setFocus("manual"); }} aria-label="credit rating in points" /></label>
          <label>listing price (ETH)<input inputMode="decimal" value={manualAsk} onChange={(e) => { setManualAsk(e.target.value); setFocus("manual"); }} aria-label="credit asking price in ETH" /></label>
          <button type="button" className={focus === "manual" ? "selected" : ""} onClick={() => setFocus("manual")}>compare →</button>
        </div>
        <div className="compare-detail" aria-live="polite">
          <div className="compare-detail-label">
            <span>{selected.key === "manual" ? "manual example" : selected.row.source + " · #" + selected.row.id}</span>
            {selected.key !== "manual" && <a href={"https://opensea.io/assets/ethereum/" + credits + "/" + selected.row.id} target="_blank" rel="noreferrer">view Credit ↗</a>}
            <span>{selected.executable ? "onchain CC bid" : "hypothetical 80% payout"}</span>
          </div>
          <div className="compare-detail-grid">
            <div><span>ETH ask</span><strong>{formattedEth(selectedAsk)}</strong></div>
            <div><span>rating value</span><strong>{formattedBal(grossBalance(selected.row.score))} BAL</strong></div>
            <div><span>{selected.executable ? "CC live payout" : "80% preview"}</span><strong>{formattedBal(selectedBid)} BAL</strong></div>
            <div><span>payout at pool spot</span><strong>{selectedSpotEth != null ? digits(selectedSpotEth, 6) + " ETH" : "—"}</strong></div>
          </div>
          <div className="compare-execution">
            <div>
              <span>Exact-input BALANCE → ETH pool quote</span>
              <strong>{exact.data != null ? formattedEth(exact.data) + " ETH" : exact.isFetching ? "quoting…" : "unavailable"}</strong>
            </div>
            <div>
              <span>quoted ETH less listing ask</span>
              <strong className={exactGap != null ? exactGap >= 0 ? "compare-up" : "compare-down" : ""}>
                {exact.data != null ? signed(exactGap) + " · " + digits(Number(formatUnits(exact.data - selectedAsk, 18)), 6) + " ETH" : "—"}
              </strong>
            </div>
          </div>
          <p className="compare-footnote">
            Uniswap v4 quote includes pool fee/price impact at this size. Excludes gas, marketplace order execution costs
            and quote movement. {selected.executable && fresh ? "CC's bid was read from balanceBidOf; this is still not an atomic arbitrage." :
              "This is a scenario, not a claim that CC will pay this amount."}
          </p>
        </div>
      </section>

      <section className="compare-section">
        <div className="compare-section-head">
          <div><h2>market asks by ETH / point</h2><p>Lowest asking price per rating point first, not simply the lowest NFT floor.</p></div>
          <span>{observed ? observed.catalog.total.toLocaleString() + " OpenSea catalogued" : "waiting for keeper feed"}</span>
        </div>
        <div className="compare-line">
          <span>{asks.length} scored asks in available view</span>
          <span>{spotPerEth ? atOffer + " of displayed asks at or below payout spot" : "BALANCE comparison unavailable"}</span>
        </div>
        <div className="compare-scroll">
          <table className="compare-table">
            <thead><tr><th>Credit</th><th>Rating</th><th>Ask ETH</th><th>ETH / pt</th><th>{hasBid ? "CC payout BAL" : "80% preview BAL"}</th><th>payout spot ETH</th><th>gap vs ask</th></tr></thead>
            <tbody>
              {prepared.map(({ key, row, bid, executable }) => {
                const spotEth = bid != null ? ethValueAtSpot(bid, spotPerEth) : undefined;
                const gap = relativeGap(spotEth, row.priceWei);
                return (
                  <tr key={key} className={focus === key ? "compare-active-row" : ""}>
                    <td><button type="button" className="compare-row-btn" onClick={() => setFocus(key)} aria-pressed={focus === key}>
                      #{row.id}<small>{row.source}</small>
                    </button></td>
                    <td>{digits(Number(row.score) / 10_000, 2)}</td>
                    <td>{formattedEth(row.priceWei)}</td>
                    <td>{digits(ethPerPoint(row.priceWei, row.score), 8)}</td>
                    <td>{bid == null ? "—" : formattedBal(bid)}{executable ? <sup>live</sup> : null}</td>
                    <td>{spotEth != null ? digits(spotEth, 6) : "—"}</td>
                    <td className={gap != null ? gap >= 0 ? "compare-up" : "compare-down" : ""}>{signed(gap)}</td>
                  </tr>
                );
              })}
              {prepared.length === 0 && <tr><td colSpan={7}>No rated active asks in the current keeper view. The manual comparison above still works if the BALANCE pool is configured.</td></tr>}
            </tbody>
          </table>
        </div>
        <div className="compare-table-footer">
          <span>Price feed: {fresh ? "current" : "not verified current"} · {observed ? "OpenSea " + observed.rows.length + " shown / Strategy " + observed.strategy.rows.length : "not available"}</span>
          {shown < Math.min(asks.length, READ_ROWS) && <button type="button" onClick={() => setShown(READ_ROWS)}>show more</button>}
        </div>
        <p className="compare-footnote">{viewLines(marketData, now).join(" ")} Asks are observations, not guaranteed executable listings. Table equivalences use spot, not trade quotes. Click an ID for a size-specific pool quote.</p>
      </section>

      <section className="compare-section compare-economics">
        <h2>working treasury economics</h2>
        <p>For a Credit acquired using BALANCE at 80% of its rating, then successfully composed and converted at par:</p>
        <div className="compare-econ-grid">
          <div><span>seller</span><strong>80%</strong></div>
          <div><span>artist + operator</span><strong>2.4%</strong></div>
          <div><span>claim backing</span><strong>10%</strong></div>
          <div><span>working surplus</span><strong>+7.6%</strong></div>
        </div>
        <p className="compare-footnote">Per 100 points of converted value, excluding ETH gas and overhead. This is not the P&amp;L of buying an NFT for ETH. At the current BALANCE spot, any ETH acquisition must be judged against conversion value and resale opportunities separately. For the selected row, the modeled BALANCE-funded working surplus is {selectedBid != null ? formattedBal(workingSurplus(selected.row.score, selectedBid)) + " BAL" : "unavailable"}; a price clamp or a different payout changes the result.</p>
      </section>

      <footer className="compare-disclosure">Private operator analysis · read only · source: Ethereum + keeper listings · not an oracle, trade signal or transaction simulation.</footer>
    </main>
  );
}
