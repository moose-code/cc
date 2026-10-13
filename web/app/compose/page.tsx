"use client";

import { useState } from "react";
import Link from "next/link";
import { useAccount, usePublicClient, useReadContract } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { formatUnits } from "viem";
import { CreditTile } from "@/components/Tiles";
import { NotDeployed } from "@/components/NotDeployed";
import { STATEMENT_SIZE } from "@/lib/engine";
import { addresses, chain, engineDeployed } from "@/lib/config";
import { coreAbi, erc20Abi } from "@/lib/abis";
import { errMsg, usePile, useSnapshot } from "@/lib/live";
import { useWriteWithBuffer } from "@/lib/tx";

const FORMATS = [0, 1, 2, 3, 4, 5, 6, 7];

// The in-progress statement: the engine's pile of bought credits, the empty
// slots left to fill, the permissionless compose() of the 80 oldest, and
// composeChosen(ids, format) when the owner has switched chosen compose on.
export default function ComposePage() {
  const { address, isConnected } = useAccount();
  const { openConnectModal } = useConnectModal();
  const { writeWithBuffer, isPending } = useWriteWithBuffer();
  const client = usePublicClient();
  const qc = useQueryClient();
  const { data: pile } = usePile();
  const { data: snap } = useSnapshot();
  const [err, setErr] = useState<string | null>(null);
  const [sel, setSel] = useState<Set<number>>(new Set());
  const [format, setFormat] = useState(0);

  const size = STATEMENT_SIZE;
  const items = pile.items;
  const filled = snap ? Number(snap.pileSize) : items.length;
  const remaining = Math.max(0, size - filled);
  const full = snap ? snap.pageReady : false;
  const pct = Math.min(100, (filled / size) * 100);
  const slots = Array.from({ length: size }, (_, i) => items[i] ?? null);

  const chosenOn = snap ? snap.chosenComposeOn : false;
  const minCc = snap?.minCcToChoose ?? 0n;
  const { data: ccBal } = useReadContract({
    address: addresses.cc,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(addresses.cc && address && minCc > 0n) },
  });
  const ccOk = minCc === 0n || (ccBal ?? 0n) >= minCc;
  const choosableIds = items.filter((c) => c.choosable).map((c) => c.id);

  const toggle = (id: number) =>
    setSel((p) => {
      const n = new Set(p);
      if (n.has(id)) n.delete(id);
      else if (n.size < size) n.add(id);
      return n;
    });

  async function send(fn: () => Promise<`0x${string}`>) {
    setErr(null);
    try {
      const hash = await fn();
      await client?.waitForTransactionReceipt({ hash });
      setSel(new Set());
      qc.invalidateQueries();
    } catch (e) {
      setErr(errMsg(e));
    }
  }

  const onCompose = () =>
    send(() =>
      writeWithBuffer({ address: addresses.core!, abi: coreAbi, functionName: "compose", chainId: chain.id })
    );

  const onComposeChosen = () =>
    send(() =>
      writeWithBuffer({
        address: addresses.core!,
        abi: coreAbi,
        functionName: "composeChosen",
        args: [[...sel].map(BigInt) as any, format],
        chainId: chain.id,
      })
    );

  if (!engineDeployed) return <NotDeployed />;

  return (
    <main className="page compose">
      <div className="page-head">
        <h1>composing next statement</h1>
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
            <Link key={c.id} href={`/credits/${c.id}`} className="slot filled" title={`credit #${c.id}`}>
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
              {size} credits are ready. composing mints a statement from the {size} oldest and lists it for sale.
              anyone can do this.
            </p>
            {isConnected ? (
              <button className="action" onClick={onCompose} disabled={isPending || !addresses.core}
                title={!addresses.core ? "core address not set" : undefined}>
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
              {!snap
                ? "loading…"
                : filled >= size
                ? `the newest of the ${size} oldest credits is still inside its sale window.`
                : `${remaining} more ${remaining === 1 ? "credit" : "credits"} needed. the engine buys credits from swap fees until the statement is full, then anyone can compose it.`}
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

      {chosenOn && (
        <section className="chosen">
          <h2>compose chosen</h2>
          <p className="muted">
            pick {size} credits that are past their sale window and a format (0 to 7).{" "}
            {minCc > 0n
              ? `requires holding at least ${Number(formatUnits(minCc, 18)).toLocaleString("en-US")} cc${
                  isConnected && addresses.cc ? ` (you hold ${Number(formatUnits(ccBal ?? 0n, 18)).toLocaleString("en-US")})` : ""
                }.`
              : "no coin balance required."}
          </p>
          <div className="sell-head">
            <span className="muted">
              {sel.size} / {size} selected
            </span>
            <span>
              <button className="link-btn" onClick={() => setSel(new Set(choosableIds.slice(0, size)))}>
                select first {size}
              </button>{" "}
              <button className="link-btn" onClick={() => setSel(new Set())}>
                clear
              </button>
            </span>
          </div>
          <div className="slot-grid">
            {items.map((c) => (
              <button
                key={c.id}
                className={`slot filled${sel.has(c.id) ? " on" : ""}`}
                title={c.choosable ? `credit #${c.id}` : `credit #${c.id} (inside its window)`}
                disabled={!c.choosable}
                onClick={() => toggle(c.id)}
                aria-pressed={sel.has(c.id)}
              >
                <CreditTile id={c.id} />
              </button>
            ))}
          </div>
          <div className="compose-action">
            <label className="muted">
              format{" "}
              <select value={format} onChange={(e) => setFormat(Number(e.target.value))}>
                {FORMATS.map((f) => (
                  <option key={f} value={f}>
                    {f}
                  </option>
                ))}
              </select>
            </label>
            {isConnected ? (
              <button
                className="action"
                onClick={onComposeChosen}
                disabled={isPending || sel.size !== size || !ccOk || !addresses.core}
                title={!addresses.core ? "core address not set" : !ccOk ? "coin balance below the minimum" : undefined}
              >
                {isPending ? "confirm in wallet…" : "compose chosen"}
              </button>
            ) : (
              <button className="action" onClick={openConnectModal}>
                connect to compose
              </button>
            )}
          </div>
        </section>
      )}
    </main>
  );
}
