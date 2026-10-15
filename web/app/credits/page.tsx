"use client";

import { useState } from "react";
import Link from "next/link";
import { CreditTile } from "@/components/Tiles";
import { Act } from "@/components/Act";
import { NotDeployed } from "@/components/NotDeployed";
import { engineDeployed } from "@/lib/config";
import { controllerAbi } from "@/lib/abis";
import { countdown, useNow, usePile, useSnapshot } from "@/lib/live";
import { useScan, type CreditEvt } from "@/lib/engine";
import { agoLabel, eth } from "@/lib/format";

const BUFFER_BPS = 200n; // value above the summed prices; the controller refunds the excess

// The engine's pile of credits. While the credit sale is on, each pile credit
// has a falling price (controller.creditPrice) and can be bought.
export default function CreditsPage() {
  const { data: pile } = usePile();
  const { data: snap } = useSnapshot();
  const { data: scan } = useScan();
  const now = useNow();
  const [sel, setSel] = useState<Set<number>>(new Set());

  const saleOn = snap?.creditSaleOn ?? false;
  const window = snap?.creditWindow ?? 0;
  const selected = pile.filter((c) => sel.has(c.id));
  const price = selected.reduce((a, c) => a + c.price, 0n);

  const toggle = (id: number) =>
    setSel((p) => {
      const n = new Set(p);
      n.has(id) ? n.delete(id) : n.add(id);
      return n;
    });

  if (!engineDeployed) return <NotDeployed />;

  return (
    <main className="page">
      <div className="page-head">
        <h1>credits</h1>
        <span className="muted">
          {`${pile.length} held by the engine · bid ${snap ? eth(snap.ethRate) : "—"} eth`}
          {saleOn && ` · sale window ${countdown(window)}`}
        </span>
      </div>

      <div className="rowlist">
        <div className="rowlist-head">
          {saleOn && <span className="rl-check" />}
          <span className="rl-credit">credit</span>
          <span className="rl-meta">paid</span>
          <span className="rl-meta">got by</span>
          {saleOn && <span className="rl-price">price</span>}
          {saleOn && <span className="rl-price">window</span>}
          <span className="rl-time">bought</span>
        </div>
        {pile.map((c) => {
          const left = c.acquiredAt + window - now;
          return (
            <div key={c.id} className="rowline">
              {saleOn && (
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
                <span className="rl-meta muted">{gotBy(scan.credits[c.id])}</span>
                {saleOn && <span className="rl-price">{eth(c.price)} eth</span>}
                {saleOn && <span className="rl-price muted">{left > 0 ? countdown(left) : "past window"}</span>}
                <span className="rl-time muted">{agoLabel(now - c.acquiredAt)}</span>
              </Link>
            </div>
          );
        })}
      </div>

      {saleOn && (
        <div className="buybar">
          <span className="muted">
            {selected.length} selected · {eth(price)} eth
          </span>
          <Act
            label={`buy ${selected.length || ""} credit${selected.length === 1 ? "" : "s"}`}
            disabled={selected.length === 0 || !snap}
            steps={async (write) => {
              const value = price + (price * BUFFER_BPS) / 10000n;
              const ids = selected.map((c) => BigInt(c.id));
              await write(
                ids.length === 1
                  ? { address: snap!.controller, abi: controllerAbi, functionName: "buyCredit", args: [ids[0]], value }
                  : { address: snap!.controller, abi: controllerAbi, functionName: "buyCredits", args: [ids], value }
              );
              setSel(new Set());
            }}
          />
        </div>
      )}
    </main>
  );
}

// How the engine got a credit: the latest bought step in its history.
function gotBy(evts?: CreditEvt[]): string {
  const b = [...(evts ?? [])].reverse().find((e) => e.t === "bought");
  return b && b.t === "bought" ? b.how : "—";
}
