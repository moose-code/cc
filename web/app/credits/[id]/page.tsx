"use client";

import Link from "next/link";
import { notFound } from "next/navigation";
import { useReadContract } from "wagmi";
import { CreditTile } from "@/components/Tiles";
import { Addr } from "@/components/Addr";
import { NotDeployed } from "@/components/NotDeployed";
import { addresses, engineDeployed } from "@/lib/config";
import { coreAbi } from "@/lib/abis";
import { useBlockTs, useScan } from "@/lib/engine";
import { useNow } from "@/lib/live";
import { agoLabel, eth } from "@/lib/format";

// A credit the engine bought. State comes from Core.creditInfo (in the pile),
// the Composed logs (composed into a statement) and the CreditSold logs (sold
// by the engine). Cost and purchase time come from creditInfo or the
// CreditBought log. Selling a credit to the engine happens on /sell.
export default function CreditDetail({ params }: { params: { id: string } }) {
  const id = Number(params.id);
  if (!Number.isInteger(id) || id < 0) notFound();
  const { data: scan } = useScan();
  const now = useNow();
  const { data: info } = useReadContract({
    address: addresses.core,
    abi: coreAbi,
    functionName: "creditInfo",
    args: [BigInt(id)],
    query: { enabled: engineDeployed, refetchInterval: 15000 },
  });
  const inPile = info?.[0] ?? false;
  const log = scan.bought[id];
  const statementId = scan.creditStatement[id];
  const sale = scan.creditSold[id];
  const { data: boughtTs } = useBlockTs(inPile ? undefined : log?.block);
  if (!engineDeployed) return <NotDeployed />;

  const cost = info && inPile ? info[1] : log?.cost;
  const acquiredAt = info && inPile ? Number(info[2]) : boughtTs;

  return (
    <main className="page detail">
      <Link href="/credits" className="back">
        {"← credits"}
      </Link>

      <div className="detail-grid">
        <div className="detail-art credit-art">
          <CreditTile id={id} />
        </div>

        <div className="detail-main">
          <div className="detail-title">
            <h1>credit #{id}</h1>
          </div>

          <div className="statuspanel">
            {inPile ? (
              <p>held by the engine, awaiting compose into the next statement.</p>
            ) : statementId != null ? (
              <p>
                composed into{" "}
                <Link href={`/statements/${statementId}`} className="xlink-inline">
                  statement #{statementId}
                </Link>
                .
              </p>
            ) : sale ? (
              <p>
                sold by the engine to <Addr address={sale.buyer} /> for {eth(sale.price)} eth.
              </p>
            ) : info ? (
              <p className="muted">no record of this credit on the engine.</p>
            ) : null}
          </div>

          {(inPile || statementId != null || sale) && (
            <div className="facts">
              {inPile && <Fact k="owner" v="engine" />}
              <Fact k="paid by engine" v={cost != null ? `${eth(cost)} eth` : "—"} />
              <Fact k="bought" v={acquiredAt != null ? agoLabel(now - acquiredAt) : "—"} />
            </div>
          )}

          {statementId != null && (
            <Link href={`/statements/${statementId}`} className="xlink">
              {`view statement #${statementId} →`}
            </Link>
          )}
        </div>
      </div>
    </main>
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
