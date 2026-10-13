"use client";

import { useState } from "react";
import Link from "next/link";
import { useAccount, useWriteContract } from "wagmi";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { CreditTile } from "@/components/Tiles";
import { credits, statementSize, nextStatementId } from "@/lib/sample";
import { addresses, chain } from "@/lib/config";
import { coreAbi } from "@/lib/abis";

// The in-progress statement: the engine's pile of bought credits, the empty
// slots left to fill, and (when 80 are ready) the permissionless compose.
//
// CONNECT:
//   - filled slots -> the pile's credit ids (CreditBought logs not yet composed,
//     or the Core pile view). count = CoreLens.snapshot().ethPileSize.
//   - next statement id -> the id the next compose will mint.
//   - compose (button) -> Core.compose(). Permissionless: anyone can call it
//     once >= 80 credits are in the pile. (Exit lane: composeExit.)
export default function ComposePage() {
  const { isConnected } = useAccount();
  const { openConnectModal } = useConnectModal();
  const { writeContractAsync, isPending } = useWriteContract();
  const [err, setErr] = useState<string | null>(null);

  const filled = credits.length; // CONNECT: snapshot().ethPileSize
  const size = statementSize;
  const remaining = Math.max(0, size - filled);
  const full = filled >= size;
  const pct = Math.min(100, (filled / size) * 100);

  const slots = Array.from({ length: size }, (_, i) =>
    i < credits.length ? credits[i] : null
  );

  async function onCompose() {
    setErr(null);
    try {
      if (!addresses.core) return;
      await writeContractAsync({
        address: addresses.core,
        abi: coreAbi,
        functionName: "compose",
        chainId: chain.id,
      });
    } catch (e: any) {
      setErr(e?.shortMessage || e?.message || "transaction failed");
    }
  }

  return (
    <main className="page compose">
      <div className="page-head">
        <h1>composing statement #{nextStatementId}</h1>
        <span className="muted">
          {filled} / {size} credits
        </span>
      </div>

      <div className="compose-bar">
        <i style={{ width: `${pct}%` }} />
      </div>

      <div className="slot-grid">
        {slots.map((c, i) =>
          c ? (
            <Link
              key={c.id}
              href={`/credits/${c.id}`}
              className="slot filled"
              title={`credit #${c.id}`}
            >
              <CreditTile id={c.id} />
            </Link>
          ) : (
            <span key={`e${i}`} className="slot empty" aria-hidden />
          )
        )}
      </div>

      <div className="compose-action">
        {full ? (
          <>
            <p className="muted">
              80 credits are ready. composing mints statement #{nextStatementId}
              {" "}
              and lists it for sale. anyone can do this.
            </p>
            {isConnected ? (
              <button
                className="action"
                onClick={onCompose}
                disabled={isPending || !addresses.core}
                title={!addresses.core ? "engine not deployed yet" : undefined}
              >
                {isPending ? "confirm in wallet…" : "compose statement"}
              </button>
            ) : (
              <button className="action" onClick={openConnectModal}>
                connect to compose
              </button>
            )}
          </>
        ) : (
          <>
            <p className="muted">
              {remaining} more {remaining === 1 ? "credit" : "credits"} needed.
              the engine buys credits from swap fees until the statement is full,
              then anyone can compose it.
            </p>
            <button className="action" disabled>
              compose (needs {size})
            </button>
          </>
        )}
        {err && (
          <p className="panel-note" style={{ color: "var(--credit)" }}>
            {err}
          </p>
        )}
      </div>
    </main>
  );
}
