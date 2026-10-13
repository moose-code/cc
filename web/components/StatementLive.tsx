"use client";

import { useState } from "react";
import Link from "next/link";
import { useAccount, usePublicClient, useReadContracts } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { StatementTile } from "./Tiles";
import { chain } from "@/lib/config";
import { controllerAbi } from "@/lib/abis";
import { errMsg, useNow, useSnapshot } from "@/lib/live";
import { agoLabel, commas, eth } from "@/lib/format";
import { useWriteWithBuffer } from "@/lib/tx";

const BUFFER_BPS = 100n; // value above the quote; the controller refunds the excess

// Statement detail read from the chain: ControllerV1 price, reference and
// floor state, and buy(sid).
export function LiveStatement({ id }: { id: number }) {
  const { data: snap } = useSnapshot();
  const now = useNow();
  const s = snap?.statements.find((x) => x.id === BigInt(id));
  return (
    <main className="page detail statement-detail">
      <Link href="/statements" className="back">
        {"← statements"}
      </Link>
      <div className="detail-grid">
        <div className="detail-art">
          <StatementTile id={id} linkCredits />
        </div>
        <div className="detail-main">
          <div className="detail-title">
            <h1>statement {id}</h1>
          </div>
          {!snap ? (
            <p className="muted">loading…</p>
          ) : !s ? (
            <p className="muted">this statement is not held by the engine.</p>
          ) : (
            <>
              <StatementBuyBox sid={id} controller={snap.controller} />
              <div className="facts">
                <Fact k="cost" v={`${eth(s.cost)} eth`} />
                <Fact k="credits" v="80" />
                <Fact k="credit score" v={commas(Math.round(Number(s.rating) / 10000))} />
                <Fact k="composed" v={agoLabel(now - Number(s.composedAt))} />
                <Fact k="redeemable" v={s.exitEligible ? "yes" : "no"} />
              </div>
            </>
          )}
        </div>
      </div>
    </main>
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
