"use client";

import { useState } from "react";
import { useAccount, usePublicClient, useReadContract } from "wagmi";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { CreditTile } from "@/components/Tiles";
import { Act } from "@/components/Act";
import { NotDeployed } from "@/components/NotDeployed";
import { core, credits, engineDeployed } from "@/lib/config";
import { coreAbi, creditsAbi } from "@/lib/abis";
import { useSnapshot } from "@/lib/live";
import { estimateSell } from "@/lib/sell";
import { BALANCE_SYMBOL } from "@/lib/events";
import { commas, eth } from "@/lib/format";
import type { Write } from "@/lib/tx";

const MIN_OUT_BPS = 9800n; // 2% under the batch estimate, which can sit above the contract's total (lib/sell.ts)

// Holders sell their credits (the external Credits NFT) into the engine:
// Credits.setApprovalForAll(Core, true) once, then Core.sellForEth(ids, minOut),
// or Core.sellForBalance(ids, minOut) while the balance bid is on.
export default function SellPage() {
  const { address, isConnected } = useAccount();
  const { openConnectModal } = useConnectModal();
  const client = usePublicClient();
  const { data: snap } = useSnapshot();
  const [selected, setSelected] = useState<Set<number>>(new Set());

  const bid = snap?.ethRate ?? 0n;
  const pot = snap?.ethPot ?? 0n;
  const buyableNow = bid > 0n ? Number(pot / bid) : 0;
  const balanceBid = Boolean(snap?.balanceOn && snap.settings.balanceBidOn);
  const total = snap
    ? estimateSell(selected.size, { ...snap, dropPerCreditBps: snap.settings.dropPerCreditBps, dropFloorBps: snap.settings.dropFloorBps })
    : 0n;

  const { data: held } = useReadContract({
    address: credits,
    abi: creditsAbi,
    functionName: "tokensOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address && engineDeployed) },
  });
  const mine: number[] = (held ?? []).map(Number);

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
    <main className="page detail">
      <div className="page-head">
        <h1>sell to the engine</h1>
      </div>
      <p className="muted sell-intro">
        the engine buys credits at the bid using its eth pot, then composes 80 into a statement. sell yours into the bid below.
      </p>

      <div className="sell-grid">
        <div>
          <div className="bidcard">
            <div className="buybox-price">
              <span className="muted">current bid</span>
              <span className="big">{eth(bid)} eth</span>
            </div>
            <div className="quote">
              <div className="r">
                <span>per credit</span>
                <span>{eth(bid)} eth</span>
              </div>
              <div className="r">
                <span>engine can buy now</span>
                <span>~{commas(buyableNow)} credits</span>
              </div>
              <div className="r">
                <span>pot</span>
                <span>{eth(pot, 2)} eth</span>
              </div>
              {snap?.balanceOn && (
                <div className="r">
                  <span>balance pot</span>
                  <span>{eth(snap.balancePot)}</span>
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
                      <span className="muted">{eth(bid)} eth</span>
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
              </div>

              <Act
                label={`approve & sell ${n || ""} credits for eth`}
                disabled={n === 0 || !snap}
                steps={async (write) => {
                  await approve(write);
                  await write({ address: core, abi: coreAbi, functionName: "sellForEth", args: [ids(), (total * MIN_OUT_BPS) / 10000n] });
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
                      // the payout is score times the module unit; minOut 1 only refuses an empty payout
                      await write({ address: core, abi: coreAbi, functionName: "sellForBalance", args: [ids(), 1n] });
                      setSelected(new Set());
                    }}
                  />
                </>
              )}
              <p className="muted small">
                the first sale approves the collection to the engine. the eth bid drops with each credit sold in one call; the amount shown is an
                estimate and the sale reverts if it pays under 98% of it.
                {balanceBid && ` the ${BALANCE_SYMBOL} bid pays by credit score.`}
              </p>
            </>
          )}
        </div>
      </div>
    </main>
  );
}
