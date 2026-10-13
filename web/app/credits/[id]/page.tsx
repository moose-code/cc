"use client";

import Link from "next/link";
import { notFound } from "next/navigation";
import { useReadContract, useReadContracts } from "wagmi";
import { CreditTile } from "@/components/Tiles";
import { Addr } from "@/components/Addr";
import { HistRow } from "@/components/History";
import { NotDeployed } from "@/components/NotDeployed";
import { addresses, engineDeployed } from "@/lib/config";
import { coreAbi, coreLensAbi } from "@/lib/abis";
import { useBlockTs, useScan, type CreditEvt } from "@/lib/engine";
import { countdown, useNow, useSnapshot } from "@/lib/live";
import { agoLabel, eth, shortAddr } from "@/lib/format";

// A credit the engine bought. State comes from Core.creditInfo (in the pile),
// the lens (sale window, sale price, chosen compose eligibility) and the logs:
// CreditBought, ListingBought, CreditAdopted (how the engine got it),
// CreditSold (sold through the credit sale) and Composed (composed into a
// statement). Selling a credit to the engine happens on /sell.
export default function CreditDetail({ params }: { params: { id: string } }) {
  const id = Number(params.id);
  if (!Number.isInteger(id) || id < 0) notFound();
  const { data: scan } = useScan();
  const { data: snap } = useSnapshot();
  const now = useNow();
  const { data: info } = useReadContract({
    address: addresses.core,
    abi: coreAbi,
    functionName: "creditInfo",
    args: [BigInt(id)],
    query: { enabled: engineDeployed, refetchInterval: 15000 },
  });
  const inPile = info?.[0] ?? false;
  const lens = { address: addresses.coreLens, abi: coreLensAbi, args: [BigInt(id)] } as const;
  const { data: sale } = useReadContracts({
    contracts: [
      { ...lens, functionName: "choosable" },
      { ...lens, functionName: "creditPriceOf" },
    ],
    query: { enabled: engineDeployed && inPile, refetchInterval: 15000 },
  });
  const choosable = sale?.[0].result as boolean | undefined;
  const price = sale?.[1].result as bigint | undefined;

  const evts = scan.credits[id] ?? [];
  const last = evts[evts.length - 1];
  const lastBought = [...evts].reverse().find((e): e is Extract<CreditEvt, { t: "bought" }> => e.t === "bought");
  const { data: boughtTs } = useBlockTs(inPile ? undefined : lastBought?.block);
  if (!engineDeployed) return <NotDeployed />;

  const cost = info && inPile ? info[1] : lastBought?.cost;
  const acquiredAt = info && inPile ? Number(info[2]) : boughtTs;
  const window = snap ? Number(snap.creditWindow) : 0;
  const left = acquiredAt != null ? acquiredAt + window - now : 0;
  const known = inPile || evts.length > 0;

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
              <p>
                held by the engine in the pile.{" "}
                {!snap ? null : !snap.creditSaleOn ? (
                  "the credit sale is off."
                ) : left > 0 ? (
                  `in its sale window, ${countdown(left)} left${price != null ? `, for sale at ${eth(price)} eth and falling` : ""}.`
                ) : (
                  `past its sale window${price != null ? `, for sale at ${eth(price)} eth` : ""}${choosable ? ", eligible for compose" : ""}.`
                )}
              </p>
            ) : last?.t === "composed" ? (
              <p>
                composed into{" "}
                <Link href={`/statements/${last.sid}`} className="xlink-inline">
                  statement {last.sid}
                </Link>
                .
              </p>
            ) : last?.t === "sold" ? (
              <p>
                sold through the credit sale to <Addr address={last.buyer} /> for {eth(last.price)} eth.
              </p>
            ) : info ? (
              <p className="muted">no record of this credit on the engine.</p>
            ) : null}
          </div>

          {known && (
            <div className="facts">
              {inPile && <Fact k="owner" v="engine" />}
              <Fact k="recorded cost" v={cost != null ? `${eth(cost)} eth` : "—"} />
              <Fact k="got by" v={lastBought ? lastBought.how : "—"} />
              <Fact k="acquired" v={acquiredAt != null ? agoLabel(now - acquiredAt) : "—"} />
              {inPile && snap?.creditSaleOn && (
                <Fact k="sale window" v={left > 0 ? `${countdown(left)} left` : "past window"} />
              )}
              {inPile && price != null && <Fact k="sale price" v={`${eth(price)} eth`} />}
            </div>
          )}

          {evts.length > 0 && (
            <section className="section history-section">
              <h2>history</h2>
              <div className="history">
                {evts.map((e, i) => (
                  <Step key={`${e.tx}-${i}`} e={e} />
                ))}
              </div>
            </section>
          )}

          {last?.t === "composed" && (
            <Link href={`/statements/${last.sid}`} className="xlink">
              {`view statement ${last.sid} →`}
            </Link>
          )}
        </div>
      </div>
    </main>
  );
}

function Step({ e }: { e: CreditEvt }) {
  if (e.t === "composed")
    return (
      <HistRow
        label="composed"
        value={
          <>
            into{" "}
            <Link href={`/statements/${e.sid}`} className="xlink-inline">
              statement {e.sid}
            </Link>
          </>
        }
        block={e.block}
        tx={e.tx}
      />
    );
  if (e.t === "sold")
    return <HistRow label="sold" value={`credit sale, ${eth(e.price)} eth`} block={e.block} tx={e.tx} addr={e.buyer} />;
  const note =
    e.how === "eth bid"
      ? `rate after ${e.rate != null ? eth(e.rate) : "—"} eth, pot ${e.pot != null ? eth(e.pot) : "—"} eth`
      : e.how === "listing"
        ? `listing at ${e.target ? shortAddr(e.target) : "—"}, keeper paid ${e.paid != null ? eth(e.paid) : "—"} eth`
        : undefined;
  return (
    <HistRow
      label={e.how === "adopted" ? "adopted" : "bought"}
      value={e.how === "adopted" ? `cost basis ${eth(e.cost)} eth` : `${e.how}, cost ${eth(e.cost)} eth`}
      note={note}
      block={e.block}
      tx={e.tx}
      addr={e.from}
    />
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
