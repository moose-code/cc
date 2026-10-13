"use client";

import { useState } from "react";
import Link from "next/link";
import { useAccount, usePublicClient, useReadContracts } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { StatementTile } from "./Tiles";
import { StatusBadge } from "./Cards";
import { Addr } from "./Addr";
import { NotDeployed } from "./NotDeployed";
import { chain, engineDeployed } from "@/lib/config";
import { STATEMENT_SIZE, useBlockTs, useStatementHistory } from "@/lib/engine";
import { controllerAbi } from "@/lib/abis";
import { errMsg, useNow, useSnapshot } from "@/lib/live";
import { agoLabel, commas, eth, signedPct } from "@/lib/format";
import { useWriteWithBuffer } from "@/lib/tx";

const BUFFER_BPS = 100n; // value above the quote; the controller refunds the excess

// Statement detail read from the chain: the lens snapshot for a statement the
// Core holds (ControllerV1 price, reference and floor state, buy(sid)), and the
// Composed, StatementSoldTo and StatementExited logs for its history.
export function LiveStatement({ id }: { id: number }) {
  const { data: snap } = useSnapshot();
  const { data: hist } = useStatementHistory();
  const now = useNow();
  const s = snap?.statements.find((x) => x.id === BigInt(id));
  const rec = hist.composed[id];
  const sale = hist.sold.find((x) => x.id === id);
  const exited = hist.exited.includes(id);
  const { data: composedTs } = useBlockTs(rec?.block);
  const { data: soldTs } = useBlockTs(sale?.block);
  if (!engineDeployed) return <NotDeployed />;
  const cost = s?.cost ?? rec?.cost;
  const known = Boolean(s || rec || sale || exited);
  return (
    <main className="page detail statement-detail">
      <Link href="/statements" className="back">
        {"← statements"}
      </Link>
      <div className="detail-grid">
        <div className="detail-art">
          <StatementTile ids={rec?.ids ?? []} linkCredits />
        </div>
        <div className="detail-main">
          <div className="detail-title">
            <h1>statement {id}</h1>
            {s ? <StatusBadge status="listed" /> : sale ? <StatusBadge status="sold" /> : null}
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
                  <Fact k="credits" v={String(STATEMENT_SIZE)} />
                  {s && <Fact k="credit score" v={commas(Math.round(Number(s.rating) / 10000))} />}
                  {s ? (
                    <Fact k="composed" v={agoLabel(now - Number(s.composedAt))} />
                  ) : (
                    composedTs != null && <Fact k="composed" v={agoLabel(now - composedTs)} />
                  )}
                  {s && <Fact k="redeemable" v={s.exitEligible ? "yes" : "no"} />}
                </div>
              )}
              {known && (
                <section className="section history-section">
                  <h2>history</h2>
                  <div className="history">
                    {cost != null && (
                      <HistRow
                        label="composed"
                        value={`${eth(cost)} eth cost`}
                        ago={composedTs != null ? agoLabel(now - composedTs) : undefined}
                      />
                    )}
                    {s && (
                      <HistRow
                        label="listed"
                        value={`${eth(s.askingPrice)} eth now`}
                        note={cost ? `${signedPct(overCost(s.askingPrice, cost))} over cost` : undefined}
                      />
                    )}
                    {sale && (
                      <HistRow
                        label="sold"
                        value={`${eth(sale.price)} eth`}
                        note={cost ? `${signedPct(overCost(sale.price, cost))} over cost` : undefined}
                        ago={soldTs != null ? agoLabel(now - soldTs) : undefined}
                        addr={sale.buyer}
                      />
                    )}
                    {exited && <HistRow label="redeemed" value="through the exit module" />}
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

function HistRow({
  label,
  value,
  note,
  ago,
  addr,
}: {
  label: string;
  value: string;
  note?: string;
  ago?: string;
  addr?: string;
}) {
  return (
    <div className="hrow">
      <span className="hlabel">{label}</span>
      <span className="hval">
        {value}
        {note && <span className="muted"> ({note})</span>}
        {addr && (
          <>
            {" by "}
            <Addr address={addr} />
          </>
        )}
      </span>
      {ago && <span className="muted hago">{ago}</span>}
    </div>
  );
}

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
