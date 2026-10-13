"use client";

import { useState } from "react";
import Link from "next/link";
import { useAccount, usePublicClient } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { CreditTile } from "@/components/Tiles";
import { engineBid } from "@/lib/sample";
import { chain } from "@/lib/config";
import { controllerAbi } from "@/lib/abis";
import { countdown, errMsg, useNow, usePile, useSnapshot } from "@/lib/live";
import { agoLabel, eth } from "@/lib/format";
import { useWriteWithBuffer } from "@/lib/tx";

const BUFFER_BPS = 200n; // value above the summed quotes; the controller refunds the excess

// The engine's pile of credits. While the credit sale is on, each pile credit
// has a falling price (ControllerV1.creditPrice) and can be bought.
export default function CreditsPage() {
  const { data: pile } = usePile();
  const { data: snap } = useSnapshot();
  const now = useNow();
  const { isConnected } = useAccount();
  const { openConnectModal } = useConnectModal();
  const { writeWithBuffer, isPending } = useWriteWithBuffer();
  const client = usePublicClient();
  const qc = useQueryClient();
  const [sel, setSel] = useState<Set<number>>(new Set());
  const [err, setErr] = useState<string | null>(null);

  const controller = snap?.controller;
  const bid = snap ? eth(snap.ethRate) : String(engineBid);
  const selected = pile.items.filter((c) => sel.has(c.id));
  const total = selected.reduce((a, c) => a + c.price, 0n);

  const toggle = (id: number) =>
    setSel((p) => {
      const n = new Set(p);
      n.has(id) ? n.delete(id) : n.add(id);
      return n;
    });

  async function onBuy() {
    setErr(null);
    try {
      if (!controller || selected.length === 0) return;
      const value = total + (total * BUFFER_BPS) / 10000n;
      const ids = selected.map((c) => BigInt(c.id));
      const hash =
        ids.length === 1
          ? await writeWithBuffer({ address: controller, abi: controllerAbi, functionName: "buyCredit", args: [ids[0]], value, chainId: chain.id })
          : await writeWithBuffer({ address: controller, abi: controllerAbi, functionName: "buyCredits", args: [ids], value, chainId: chain.id });
      await client?.waitForTransactionReceipt({ hash });
      setSel(new Set());
      qc.invalidateQueries();
    } catch (e) {
      setErr(errMsg(e));
    }
  }

  return (
    <main className="page">
      <div className="page-head">
        <h1>credits</h1>
        <span className="muted">
          {`${pile.items.length} held by the engine · bid ${bid} eth`}
          {pile.saleOn && ` · sale window ${countdown(pile.window)}`}
        </span>
      </div>

      <div className="rowlist">
        <div className="rowlist-head">
          {pile.saleOn && <span className="rl-check" />}
          <span className="rl-credit">credit</span>
          <span className="rl-meta">paid</span>
          {pile.saleOn && <span className="rl-price">price</span>}
          {pile.saleOn && <span className="rl-price">window</span>}
          <span className="rl-time">bought</span>
        </div>
        {pile.items.map((c) => {
          const left = c.acquiredAt + pile.window - now;
          return (
            <div key={c.id} className="rowline">
              {pile.saleOn && (
                <input
                  type="checkbox"
                  className="rl-check"
                  checked={sel.has(c.id)}
                  onChange={() => toggle(c.id)}
                  aria-label={`select credit #${c.id}`}
                />
              )}
              <Link href={`/credits/${c.id}`} className="rowlink">
                <span className="rl-credit">
                  <CreditTile id={c.id} />
                  <span className="rl-id">credit #{c.id}</span>
                </span>
                <span className="rl-meta">{eth(c.cost)} eth</span>
                {pile.saleOn && <span className="rl-price">{eth(c.price)} eth</span>}
                {pile.saleOn && (
                  <span className="rl-price muted">{left > 0 ? countdown(left) : "past window"}</span>
                )}
                <span className="rl-time muted">{agoLabel(now - c.acquiredAt)}</span>
              </Link>
            </div>
          );
        })}
      </div>

      {pile.saleOn && (
        <div className="buybar">
          <span className="muted">
            {selected.length} selected · {eth(total)} eth
          </span>
          {isConnected ? (
            <button
              className="action"
              onClick={onBuy}
              disabled={isPending || selected.length === 0 || !controller}
              title={!controller ? "engine not deployed yet" : undefined}
            >
              {isPending ? "confirm in wallet…" : `buy ${selected.length || ""} credit${selected.length === 1 ? "" : "s"}`}
            </button>
          ) : (
            <button className="action" onClick={openConnectModal}>
              connect to buy
            </button>
          )}
          {err && <span style={{ color: "var(--credit)" }}>{err}</span>}
        </div>
      )}
    </main>
  );
}
