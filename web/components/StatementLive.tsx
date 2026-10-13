"use client";

import { useState } from "react";
import Link from "next/link";
import { useAccount, usePublicClient, useReadContracts } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { StatementTile, CreditTile } from "./Tiles";
import { StatusBadge } from "./Cards";
import { HistRow } from "./History";
import { NotDeployed } from "./NotDeployed";
import { chain, engineDeployed } from "@/lib/config";
import { STATEMENT_SIZE, useBlockTs, useExitToken, useScan } from "@/lib/engine";
import { formatExit } from "@/lib/events";
import { useTokenMeta } from "@/lib/art";
import { controllerAbi } from "@/lib/abis";
import { errMsg, useNow, useSnapshot } from "@/lib/live";
import { agoLabel, commas, eth, signedPct } from "@/lib/format";
import { useWriteWithBuffer } from "@/lib/tx";

const BUFFER_BPS = 100n; // value above the quote; the controller refunds the excess

// Statement detail read from the chain: the lens snapshot for a statement the
// Core holds (ControllerV1 price, reference and floor state, buy(sid)), and the
// Core and controller logs for its history: Composed (credits, format, who,
// default or chosen), StatementSoldTo, AnchorMoved and StatementExited.
export function LiveStatement({ id }: { id: number }) {
  const { data: snap } = useSnapshot();
  const { data: scan } = useScan();
  const { data: meta } = useTokenMeta("statement", id);
  const { data: xToken } = useExitToken();
  const now = useNow();
  const s = snap?.statements.find((x) => x.id === BigInt(id));
  const rec = scan.statements[id];
  const composed = rec?.composed;
  const sale = rec?.sold;
  const exited = rec?.exited;
  const { data: composedTs } = useBlockTs(composed?.block);
  if (!engineDeployed) return <NotDeployed />;
  const cost = s?.cost ?? composed?.cost;
  const known = Boolean(s || rec);
  const formatName = meta?.attrs.Format;
  const score = meta?.attrs["Credit Rating"];
  return (
    <main className="page detail statement-detail">
      <Link href="/statements" className="back">
        {"← statements"}
      </Link>
      <div className="detail-grid">
        <div className="detail-art">
          <StatementTile id={id} />
        </div>
        <div className="detail-main">
          <div className="detail-title">
            <h1>statement {id}</h1>
            {s ? <StatusBadge status="listed" /> : sale ? <StatusBadge status="sold" /> : exited ? <StatusBadge status="redeemed" /> : known ? <StatusBadge status="not held" /> : null}
          </div>
          {!snap ? (
            <p className="muted">loading…</p>
          ) : (
            <>
              {s && <StatementBuyBox sid={id} controller={snap.controller} />}
              {!known && <p className="muted">no record of this statement on the engine.</p>}
              {known && (
                <div className="facts">
                  {cost != null && <Fact k="cost" v={`${eth(cost)} eth`} />}
                  <Fact k="credits" v={String(composed?.ids.length ?? STATEMENT_SIZE)} />
                  {score != null && <Fact k="credit score" v={commas(Number(score))} />}
                  {composed && <Fact k="format" v={`${formatName ?? "—"} (${composed.format})`} />}
                  {composed && (
                    <Fact
                      k="composed"
                      v={`${composedTs != null ? agoLabel(now - composedTs) : "—"} · ${
                        composed.mode === "chosen" ? "chosen compose" : composed.mode === "default" ? "default compose" : "compose"
                      }`}
                    />
                  )}
                  {s && <Fact k="redeemable" v={s.exitEligible ? "yes" : "no"} />}
                </div>
              )}
              {known && (
                <section className="section history-section">
                  <h2>history</h2>
                  <div className="history">
                    {composed && (
                      <HistRow
                        label="composed"
                        value={`${eth(composed.cost)} eth cost`}
                        note={composed.mode ? `${composed.mode} compose, format ${formatName ?? composed.format}` : `format ${formatName ?? composed.format}`}
                        block={composed.block}
                        tx={composed.tx}
                        addr={composed.caller}
                      />
                    )}
                    {s && (
                      <HistRow
                        label="for sale"
                        value={`${eth(s.askingPrice)} eth now`}
                        note={cost ? `${signedPct(overCost(s.askingPrice, cost))} over cost` : undefined}
                      />
                    )}
                    {sale && (
                      <HistRow
                        label="sold"
                        value={`${eth(sale.price)} eth`}
                        note={[cost ? `${signedPct(overCost(sale.price, cost))} over cost` : "", sale.toBuyback != null ? `${eth(sale.toBuyback)} eth to buyback` : ""].filter(Boolean).join(", ")}
                        block={sale.block}
                        tx={sale.tx}
                        addr={sale.buyer}
                      />
                    )}
                    {rec?.anchor.map((m) => (
                      <HistRow
                        key={m.tx}
                        label="anchor moved"
                        value={`sale at ${pct(m.saleBps)} of reference, anchor now ${pct(m.anchorBps)}`}
                        block={m.block}
                        tx={m.tx}
                      />
                    ))}
                    {exited && (
                      <HistRow
                        label="redeemed"
                        value="by redemption"
                        note={`received ${formatExit(exited.received, xToken)}`}
                        block={exited.block}
                        tx={exited.tx}
                      />
                    )}
                  </div>
                </section>
              )}
              {composed && (
                <section className="section">
                  <h2>{composed.ids.length} credits</h2>
                  <div className="credit-mini-grid">
                    {composed.ids.map((cid) => (
                      <Link key={cid} href={`/credits/${cid}`} title={`credit #${cid}`}>
                        <CreditTile id={cid} />
                      </Link>
                    ))}
                  </div>
                </section>
              )}
            </>
          )}
        </div>
      </div>
    </main>
  );
}

// price over cost, in percent
const overCost = (price: bigint, cost: bigint) => (Number(price) / Number(cost) - 1) * 100;
const pct = (bps: bigint | number) => `${(Number(bps) / 100).toLocaleString("en-US", { maximumFractionDigits: 2 })}%`;

function StatementBuyBox({ sid, controller }: { sid: number; controller: `0x${string}` }) {
  const { isConnected } = useAccount();
  const { openConnectModal } = useConnectModal();
  const { writeWithBuffer, isPending } = useWriteWithBuffer();
  const client = usePublicClient();
  const qc = useQueryClient();
  const [err, setErr] = useState<string | null>(null);
  const c = { address: controller, abi: controllerAbi, args: [BigInt(sid)] } as const;
  const { data } = useReadContracts({
    contracts: [
      { ...c, functionName: "priceOf" },
      { ...c, functionName: "referenceOf" },
      { ...c, functionName: "atFloor" },
      { address: controller, abi: controllerAbi, functionName: "paused" },
    ],
    query: { refetchInterval: 12000 },
  });
  const price = data?.[0].result as bigint | undefined;
  const reference = data?.[1].result as bigint | undefined;
  const atFloor = data?.[2].result as boolean | undefined;
  const paused = data?.[3].result as boolean | undefined;

  async function onBuy() {
    setErr(null);
    try {
      if (price == null) return;
      const hash = await writeWithBuffer({
        ...c,
        functionName: "buy",
        value: price + (price * BUFFER_BPS) / 10000n,
        chainId: chain.id,
      });
      await client?.waitForTransactionReceipt({ hash });
      qc.invalidateQueries();
    } catch (e) {
      setErr(errMsg(e));
    }
  }

  return (
    <div className="buybox">
      <div className="buybox-price">
        <span className="muted">current price</span>
        <span className="big">{price != null ? `${eth(price)} eth` : "—"}</span>
      </div>
      <div className="price-ends muted">
        <span>reference {reference != null ? eth(reference) : "—"}</span>
        <span>{atFloor ? "at floor" : "falling"}</span>
      </div>
      {isConnected ? (
        <button className="action" onClick={onBuy} disabled={isPending || price == null || paused}>
          {isPending ? "confirm in wallet…" : paused ? "sales paused" : "buy statement"}
        </button>
      ) : (
        <button className="action" onClick={openConnectModal}>
          connect to buy
        </button>
      )}
      <p className="muted small">
        the price falls toward its floor and rises if the engine bid peak rises. the excess of your payment is refunded.
      </p>
      {err && <p className="panel-note" style={{ color: "var(--credit)" }}>{err}</p>}
    </div>
  );
}

function Fact({ k, v }: { k: string; v: string }) {
  return (
    <div className="fact">
      <span className="muted">{k}</span>
      <span>{v}</span>
    </div>
  );
}
