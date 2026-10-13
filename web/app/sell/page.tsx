"use client";

import { useState } from "react";
import { useAccount, usePublicClient, useReadContract } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { CreditTile } from "@/components/Tiles";
import { NotDeployed } from "@/components/NotDeployed";
import { addresses, chain, engineDeployed } from "@/lib/config";
import { coreAbi, creditsAbi } from "@/lib/abis";
import { errMsg, sellQuote, useNow, useSellQuote, useSnapshot } from "@/lib/live";
import { commas, eth } from "@/lib/format";
import { useWriteWithBuffer } from "@/lib/tx";

const MIN_OUT_BPS = 9950n; // 0.5% under the batch total quoted at click time

// Holders sell their credits (the external Credits NFT) into the engine's bid:
// Credits.setApprovalForAll(Core, true) once, then Core.sellForEth(ids, minOut).
export default function SellPage() {
  const { address, isConnected } = useAccount();
  const { openConnectModal } = useConnectModal();
  const { writeWithBuffer, isPending } = useWriteWithBuffer();
  const client = usePublicClient();
  const qc = useQueryClient();
  const { data: snap } = useSnapshot();
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [err, setErr] = useState<string | null>(null);

  const bid = snap?.ethRate ?? 0n;
  const pot = snap?.ethPot ?? 0n;
  const buyableNow = bid > 0n ? Number(pot / bid) : 0;
  const now = useNow(5000);
  const quote = useSellQuote(selected.size, now);
  const total = quote.data ?? bid * BigInt(selected.size);

  const { data: held } = useReadContract({
    address: addresses.credits,
    abi: creditsAbi,
    functionName: "tokensOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(addresses.credits && address) },
  });
  const mine: number[] = (held ?? []).map(Number);

  const toggle = (id: number) =>
    setSelected((prev) => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  const all = () =>
    setSelected((prev) => (prev.size === mine.length ? new Set() : new Set(mine)));

  async function onSell() {
    setErr(null);
    try {
      const { core, credits } = addresses;
      if (!core || !credits || !address || !client || selected.size === 0) return;
      const approved = await client.readContract({
        address: credits,
        abi: creditsAbi,
        functionName: "isApprovedForAll",
        args: [address, core],
      });
      if (!approved) {
        const h = await writeWithBuffer({
          address: credits,
          abi: creditsAbi,
          functionName: "setApprovalForAll",
          args: [core, true],
          chainId: chain.id,
        });
        await client.waitForTransactionReceipt({ hash: h });
      }
      // The bid drops with each credit sold in one call: minOut is a share of
      // the whole batch's total, replayed from the contract's rate loop.
      const expected = await sellQuote(client, selected.size, now);
      const h = await writeWithBuffer({
        address: core,
        abi: coreAbi,
        functionName: "sellForEth",
        args: [[...selected].map(BigInt), (expected * MIN_OUT_BPS) / 10000n],
        chainId: chain.id,
      });
      await client.waitForTransactionReceipt({ hash: h });
      setSelected(new Set());
      qc.invalidateQueries();
    } catch (e) {
      setErr(errMsg(e));
    }
  }

  if (!engineDeployed) return <NotDeployed />;

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
                  your credits ({mine.length})
                </span>
                <button className="link-btn" onClick={all}>
                  {selected.size === mine.length ? "clear" : "select all"}
                </button>
              </div>

              <div className="sell-list">
                {mine.map((id) => {
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
                      <span className="muted">{eth(bid)} eth</span>
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
                  <span className="big-sm">up to {eth(total)} eth</span>
                </div>
              </div>

              <button
                className="action"
                onClick={onSell}
                disabled={isPending || selected.size === 0 || !addresses.core || !addresses.credits}
                title={!addresses.core ? "core address not set" : undefined}
              >
                {isPending ? "confirm in wallet…" : `approve & sell ${selected.size || ""} credits`}
              </button>
              <p className="muted small">
                first sale approves the collection to the engine, then sells at
                the bid. the bid drops with each credit sold in one call.
              </p>
              {err && <p className="panel-note" style={{ color: "var(--credit)" }}>{err}</p>}
            </>
          )}
        </div>
      </div>
    </main>
  );
}
