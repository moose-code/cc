"use client";

import { useState } from "react";
import Link from "next/link";
import { useAccount, useReadContract } from "wagmi";
import { formatUnits } from "viem";
import { CreditTile } from "@/components/Tiles";
import { Act } from "@/components/Act";
import { NotDeployed } from "@/components/NotDeployed";
import { PageHead } from "@/components/Shell";
import { coinLive, core, engineDeployed, STATEMENT_SIZE } from "@/lib/config";
import { coreAbi, erc20Abi } from "@/lib/abis";
import { usePile, useSnapshot } from "@/lib/live";

const FORMATS = [0, 1, 2, 3, 4, 5, 6, 7];

// The in-progress statement: the engine's pile of bought credits, the empty
// slots left to fill, the permissionless compose() with a random format or
// compose(format) of the controller's page, and composeChosen(ids, format)
// of 80 credits the caller names while the owner has chosen compose on.
export default function ComposePage() {
  const { address } = useAccount();
  const { data: pile } = usePile();
  const { data: snap } = useSnapshot();
  const [sel, setSel] = useState<Set<number>>(new Set());
  const [format, setFormat] = useState<"random" | number>("random");
  const [chosenFormat, setChosenFormat] = useState(0);

  const size = STATEMENT_SIZE;
  const filled = snap ? Number(snap.pileSize) : pile.length;
  const remaining = Math.max(0, size - filled);
  const ready = snap?.page.ready ?? false;
  const slots = Array.from({ length: size }, (_, i) => pile[i] ?? null);

  const chosenOn = snap?.chosenComposeOn ?? false;
  const minCc = snap?.minCcToChoose ?? 0n;
  const { data: ccBal } = useReadContract({
    address: snap?.coin,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(coinLive && snap?.coin && address && minCc > 0n) },
  });
  const ccOk = minCc === 0n || (ccBal ?? 0n) >= minCc;
  const choosable = pile.filter((c) => c.past);

  const toggle = (id: number) =>
    setSel((p) => {
      const n = new Set(p);
      if (n.has(id)) n.delete(id);
      else if (n.size < size) n.add(id);
      return n;
    });

  if (!engineDeployed) return <NotDeployed />;

  return (
    <>
      <PageHead title="composing next statement" ink="k" meta={`${filled} / ${size} credits`} />
      <main className="page compose">
        <div className="compose-bar">
          <i style={{ width: `${Math.min(100, (filled / size) * 100)}%` }} />
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
          {ready ? (
            <>
              <p className="muted">
                {size} credits are ready. composing mints a statement from the {size} oldest and holds it for sale. anyone can do this.
              </p>
              <label className="muted">
                format{" "}
                <select value={format} onChange={(e) => setFormat(e.target.value === "random" ? "random" : Number(e.target.value))}>
                  <option value="random">random</option>
                  {FORMATS.map((f) => (
                    <option key={f} value={f}>
                      {f}
                    </option>
                  ))}
                </select>
              </label>
              <Act
                label="compose statement"
                steps={async (write) =>
                  void (await write(
                    format === "random"
                      ? { address: core, abi: coreAbi, functionName: "compose" }
                      : { address: core, abi: coreAbi, functionName: "compose", args: [format] }
                  ))
                }
              />
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
        </div>

        {chosenOn && (
          <section className="chosen">
            <h2>compose chosen</h2>
            <p className="muted">
              pick {size} credits that are past their sale window and a format (0 to 7).{" "}
              {minCc > 0n
                ? `requires holding at least ${Number(formatUnits(minCc, 18)).toLocaleString("en-US")} cc${
                    address ? ` (you hold ${Number(formatUnits(ccBal ?? 0n, 18)).toLocaleString("en-US")})` : ""
                  }.`
                : "no coin balance required."}
            </p>
            <div className="sell-head">
              <span className="muted">
                {sel.size} / {size} selected
              </span>
              <span>
                <button className="link-btn" onClick={() => setSel(new Set(choosable.slice(0, size).map((c) => c.id)))}>
                  select first {size}
                </button>{" "}
                <button className="link-btn" onClick={() => setSel(new Set())}>
                  clear
                </button>
              </span>
            </div>
            <div className="slot-grid">
              {pile.map((c) => (
                <button
                  key={c.id}
                  className={`slot filled${sel.has(c.id) ? " on" : ""}`}
                  title={c.past ? `credit #${c.id}` : `credit #${c.id} (inside its window)`}
                  disabled={!c.past}
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
                <select value={chosenFormat} onChange={(e) => setChosenFormat(Number(e.target.value))}>
                  {FORMATS.map((f) => (
                    <option key={f} value={f}>
                      {f}
                    </option>
                  ))}
                </select>
              </label>
              <Act
                label="compose chosen"
                disabled={sel.size !== size || !ccOk}
                title={!ccOk ? "coin balance below the minimum" : undefined}
                steps={async (write) => {
                  await write({ address: core, abi: coreAbi, functionName: "composeChosen", args: [[...sel].map(BigInt) as any, chosenFormat] });
                  setSel(new Set());
                }}
              />
            </div>
          </section>
        )}
      </main>
    </>
  );
}
