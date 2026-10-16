"use client";

import { useState } from "react";
import { useAccount, usePublicClient } from "wagmi";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { CreditTile } from "@/components/Tiles";
import { Act } from "@/components/Act";
import { NotDeployed } from "@/components/NotDeployed";
import { PageHead } from "@/components/Shell";
import { core, credits, engineDeployed } from "@/lib/config";
import { coreAbi, creditsAbi } from "@/lib/abis";
import { balanceQuote, sellQuote, useBidsOf, useNow, useSellQuote, useSnapshot, useWalletCredits } from "@/lib/live";
import { BALANCE_SYMBOL, commas, eth } from "@/lib/format";
import type { Write } from "@/lib/tx";

const MIN_OUT_BPS = 9950n; // 0.5% under the batch total quoted at click time

// Holders sell their credits (the external Credits NFT) into the engine:
// Credits.setApprovalForAll(Core, true) once, then Core.sellForEth(ids, minOut),
// or Core.sellForBalance(ids, minOut, expectedToken) while the balance bid is on.
export default function SellPage() {
  const { address, isConnected } = useAccount();
  const { openConnectModal } = useConnectModal();
  const client = usePublicClient();
  const { data: snap } = useSnapshot();
  const [selected, setSelected] = useState<Set<number>>(new Set());

  const bid = snap?.ethRate ?? 0n;
  const pot = snap?.ethPot ?? 0n;
  const buyableNow = bid > 0n ? pot / bid : 0n;
  // the pot scaled multiplier (10_000 is 1x) that scales the ceiling's idle loosening, and the pages the pot covers at
  // the current bid, the same figure as "pot covers" (a page is 80 credits). the bid is flat at the rate cap
  const climbX = Number(snap?.climbMultiplier ?? 10000n) / 10000;
  const potPages = `${buyableNow / 80n}.${(buyableNow % 80n) * 10n / 80n}`;
  const atCap = snap ? bid >= snap.settings.rateCap : false;
  // the module reads can fail; the balance side is then unavailable and the eth side renders alone
  const balanceBid = Boolean(snap?.balanceOn && snap.settings.balanceBidOn && snap.balanceUnit !== undefined);
  const now = useNow(5000);
  const selectedIds = [...selected].map((id) => BigInt(id));
  const quote = useSellQuote(selectedIds, now);

  const { data: wallet, scores } = useWalletCredits(address);
  const mine: number[] = wallet.map((c) => c.id);
  // each credit's own eth bid, ethRate() * score / refScore (one multicall of Core.bidOf)
  const { data: bids } = useBidsOf(mine.map((id) => BigInt(id)), now);
  const bidForId = (id: number): bigint => bids?.[id.toString()] ?? 0n;
  const total = quote.data?.amount ?? mine.filter((id) => selected.has(id)).reduce((t, id) => t + bidForId(id), 0n);
  // the per-credit balance payout, score * unitPerPoint * balanceRate / 10_000, derived from the indexed scores and the
  // snapshot rate and unit (no extra poll). the batch total replays the per-credit drop (balanceQuote)
  const balanceForId = (id: number): bigint =>
    balanceBid && scores ? ((scores[id.toString()] ?? 0n) * (snap?.balanceUnit ?? 0n) * (snap?.balanceRate ?? 0n)) / 10000n : 0n;
  const balanceTotal =
    balanceBid && scores && snap ? balanceQuote(snap, selectedIds.map((id) => scores[id.toString()] ?? 0n)) : 0n;

  const toggle = (id: number) =>
    setSelected((prev) => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  const all = () => setSelected((prev) => (prev.size === mine.length ? new Set() : new Set(mine)));

  // the collection approval to the Core, once
  async function approve(write: Write) {
    if (!address || !client) return;
    const ok = await client.readContract({ address: credits, abi: creditsAbi, functionName: "isApprovedForAll", args: [address, core!] });
    if (!ok) await write({ address: credits, abi: creditsAbi, functionName: "setApprovalForAll", args: [core, true] });
  }

  if (!engineDeployed) return <NotDeployed />;

  const ids = () => [...selected].map(BigInt);
  const n = selected.size;

  return (
    <>
      <PageHead title="sell to the engine" ink="k" />
      <main className="page detail">
        <p className="muted sell-intro">
          the engine buys each credit at its own bid (the rate scaled by the credit&apos;s score) using its eth pot, then composes 80 into a statement. sell yours into the bid below.
        </p>

        <div className="sell-grid">
          <div>
            <div className="bidcard">
              <div className="buybox-price">
                <span className="muted">bid, reference credit</span>
                <span className="big">{eth(bid)} eth</span>
                {atCap ? (
                  <span className="muted">bid at cap</span>
                ) : climbX > 1 ? (
                  <span className="muted">pot covers {potPages} pages, ceiling loosening {climbX.toFixed(1)}x</span>
                ) : null}
              </div>
              <div className="quote">
                <div className="r">
                  <span>reference credit</span>
                  <span>{eth(bid)} eth</span>
                </div>
                <div className="r">
                  <span>pot covers, before eth cap</span>
                  <span>~{commas(buyableNow)} credits</span>
                </div>
                <div className="r">
                  <span>pot</span>
                  <span>{eth(pot, 2)} eth</span>
                </div>
                {snap?.balanceOn && (
                  <div className="r">
                    <span>balance in the module</span>
                    <span>{snap.balanceAvailable === undefined ? "unavailable" : eth(snap.balanceAvailable)}</span>
                  </div>
                )}
              </div>
            </div>
          </div>

          <div>
            {!isConnected ? (
              <div className="sell-connect">
                <p className="muted">connect a wallet to see your credits.</p>
                <button className="action" onClick={openConnectModal}>
                  connect wallet
                </button>
              </div>
            ) : (
              <>
                <div className="sell-head">
                  <span className="muted">your credits ({mine.length})</span>
                  <button className="link-btn" onClick={all}>
                    {selected.size === mine.length ? "clear" : "select all"}
                  </button>
                </div>

                <div className="sell-list">
                  {mine.map((id) => {
                    const on = selected.has(id);
                    return (
                      <button key={id} className={`sell-item${on ? " on" : ""}`} onClick={() => toggle(id)} aria-pressed={on}>
                        <CreditTile id={id} />
                        <span className="rl-id">credit #{id}</span>
                        <span className="muted">{bids ? `${eth(bidForId(id))} eth` : "…"}{balanceBid && scores ? ` \u00b7 ${eth(balanceForId(id))} ${BALANCE_SYMBOL}` : ""}</span>
                        <span className="sell-check">{on ? "✓" : ""}</span>
                      </button>
                    );
                  })}
                </div>

                <div className="sell-summary">
                  <div className="r">
                    <span className="muted">selling</span>
                    <span>{n} credits</span>
                  </div>
                  <div className="r">
                    <span className="muted">you receive</span>
                    <span className="big-sm">about {eth(total)} eth</span>
                  </div>
                  {balanceBid && (
                    <div className="r">
                      <span className="muted">or for {BALANCE_SYMBOL}</span>
                      <span className="big-sm">about {eth(balanceTotal)} {BALANCE_SYMBOL} ({(Number(snap?.balanceRate ?? 0n) / 100).toFixed(1)}% of par)</span>
                    </div>
                  )}
                </div>

                {snap && snap.settings.spendCapBps < 10000 && (
                  <p className="muted small">
                    eth purchase cap: {snap.settings.spendCapBps / 100}% of the bucket&apos;s opening pot per {snap.settings.bucketSeconds} seconds.
                  </p>
                )}
                <Act
                  label={`approve & sell ${n || ""} credits for eth`}
                  disabled={n === 0 || !snap}
                  steps={async (write) => {
                    await approve(write);
                    // each credit pays its own bid (ethRate * score / refScore) and the bid drops per credit sold in one
                    // call: minOut is a share of the whole batch's total, replayed from the contract's rate loop
                    const expected = (await sellQuote(client!, ids(), now)).amount;
                    await write({ address: core, abi: coreAbi, functionName: "sellForEth", args: [ids(), (expected * MIN_OUT_BPS) / 10000n] });
                    setSelected(new Set());
                  }}
                />
                {balanceBid && (
                  <>
                    <p />
                    <Act
                      label={`approve & sell ${n || ""} credits for ${BALANCE_SYMBOL}`}
                      disabled={n === 0}
                      steps={async (write) => {
                        await approve(write);
                        // minOut replays the per-credit drop from the snapshot, like the eth quote, so an ordinary batch
                        // does not trip Slippage
                        const expected = balanceQuote(snap!, ids().map((id) => scores?.[id.toString()] ?? 0n));
                        await write({ address: core, abi: coreAbi, functionName: "sellForBalance", args: [ids(), (expected * MIN_OUT_BPS) / 10000n, snap!.balanceToken] });
                        setSelected(new Set());
                      }}
                    />
                  </>
                )}
                <p className="muted small">
                  the first sale approves the collection to the engine. each credit is paid the rate times its score over the reference score, and the rate
                  drops with each credit sold in one call; the amount shown is the batch total at the current rates and the sale reverts if it pays under 99.5% of it.
                  {snap && snap.settings.spendCapBps < 10000 && " the eth quote does not reserve purchase budget. an eth sale can be blocked until the next budget bucket, even when the pot has funds."}
                  {balanceBid && ` the ${BALANCE_SYMBOL} bid pays by credit score at the rate shown (bps of par), and drops with each credit sold.`}
                </p>
              </>
            )}
          </div>
        </div>
      </main>
    </>
  );
}
