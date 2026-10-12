"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { CreditTile } from "@/components/Tiles";
import { engineBid, enginePot, yourSampleCredits } from "@/lib/sample";
import { commas } from "@/lib/format";

// Holders sell their credits (the external Credits NFT) into the engine's bid.
//
// CONNECT:
//   - your credits -> enumerate the connected wallet's Credits NFTs
//     (balanceOf + tokenOfOwnerByIndex, or Transfer logs). addresses.credits.
//   - bid -> CoreLens.snapshot().ethRate (wei per credit).
//   - buyable now -> ethPot / rate (the pot caps how many it can buy this call;
//     there may also be a per-call pace bound).
//   - approve -> Credits.setApprovalForAll(Core, true) once.
//   - sell -> Core.sellForEth(ids, minOut). minOut guards the rate moving down
//     between build and mine. Show total received = count * rate.
export default function SellPage() {
  const { isConnected } = useAccount();
  const { openConnectModal } = useConnectModal();
  const [selected, setSelected] = useState<Set<number>>(new Set());

  const buyableNow = Math.floor(enginePot / engineBid);
  const total = selected.size * engineBid;

  const toggle = (id: number) =>
    setSelected((prev) => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  const all = () =>
    setSelected((prev) =>
      prev.size === yourSampleCredits.length ? new Set() : new Set(yourSampleCredits)
    );

  return (
    <main className="page detail">
      <div className="page-head">
        <h1>sell to the engine</h1>
      </div>
      <p className="muted sell-intro">
        the engine buys credits at the bid using its eth pot, then composes 80
        into a statement. sell yours into the bid below.
      </p>

      <div className="sell-grid">
        <div>
          <div className="bidcard">
            <div className="buybox-price">
              <span className="muted">current bid</span>
              <span className="big">{engineBid} eth</span>
            </div>
            <div className="quote">
              <div className="r">
                <span>per credit</span>
                <span>{engineBid} eth</span>
              </div>
              <div className="r">
                <span>engine can buy now</span>
                {/* CONNECT: pot / rate */}
                <span>~{commas(buyableNow)} credits</span>
              </div>
              <div className="r">
                <span>pot</span>
                <span>{enginePot} eth</span>
              </div>
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
                <span className="muted">
                  {/* CONNECT: real holdings */}
                  your credits ({yourSampleCredits.length})
                </span>
                <button className="link-btn" onClick={all}>
                  {selected.size === yourSampleCredits.length
                    ? "clear"
                    : "select all"}
                </button>
              </div>

              <div className="sell-list">
                {yourSampleCredits.map((id) => {
                  const on = selected.has(id);
                  return (
                    <button
                      key={id}
                      className={`sell-item${on ? " on" : ""}`}
                      onClick={() => toggle(id)}
                      aria-pressed={on}
                    >
                      <CreditTile id={id} />
                      <span className="rl-id">credit #{id}</span>
                      <span className="muted">{engineBid} eth</span>
                      <span className="sell-check">{on ? "✓" : ""}</span>
                    </button>
                  );
                })}
              </div>

              <div className="sell-summary">
                <div className="r">
                  <span className="muted">selling</span>
                  <span>{selected.size} credits</span>
                </div>
                <div className="r">
                  <span className="muted">you receive</span>
                  <span className="big-sm">{total.toFixed(4)} eth</span>
                </div>
              </div>

              {/* CONNECT: setApprovalForAll(Core) then sellForEth(ids, minOut) */}
              <button className="action" disabled={selected.size === 0}>
                approve &amp; sell {selected.size || ""} credits
              </button>
              <p className="muted small">
                first sale approves the collection to the engine, then sells at
                the bid.
              </p>
            </>
          )}
        </div>
      </div>
    </main>
  );
}
