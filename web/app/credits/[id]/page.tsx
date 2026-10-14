"use client";

import Link from "next/link";
import { notFound } from "next/navigation";
import { CreditTile } from "@/components/Tiles";
import { Addr } from "@/components/Addr";
import { HistRow } from "@/components/History";
import { NotDeployed } from "@/components/NotDeployed";
import { engineDeployed } from "@/lib/config";
import { useBlockTs, useScan, type CreditEvt } from "@/lib/engine";
import { countdown, useCredit, useNow, useSnapshot } from "@/lib/live";
import { agoLabel, eth, shortAddr } from "@/lib/format";

// A credit the engine bought. State comes from the multicall reads (creditInfo,
// the controller's credit prices and pastWindow) and the logs: CreditBought,
// ListingBought, CreditAdopted (how the engine got it), CreditSold (sold
// through the credit sale) and Composed (composed into a statement). Buying a
// credit is on /credits, selling one to the engine on /sell.
export default function CreditDetail({ params }: { params: { id: string } }) {
  const id = Number(params.id);
  if (!Number.isInteger(id) || id < 0) notFound();
  const { data: scan } = useScan();
  const { data: snap } = useSnapshot();
  const now = useNow();
  const { data: c } = useCredit(id);
  const inPile = c?.inPile ?? false;

  const evts = scan.credits[id] ?? [];
  const last = evts[evts.length - 1];
  const lastBought = [...evts].reverse().find((e): e is Extract<CreditEvt, { t: "bought" }> => e.t === "bought");
  const { data: boughtTs } = useBlockTs(inPile ? undefined : lastBought?.block);
  if (!engineDeployed) return <NotDeployed />;

  const cost = inPile ? c?.cost : lastBought?.cost;
  const acquiredAt = inPile ? c?.acquiredAt : boughtTs;
  const window = snap?.creditWindow ?? 0;
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
                {!snap ? null : !snap.creditSaleOn
                  ? "the credit sale is off."
                  : left > 0
                    ? `in its sale window, ${countdown(left)} left, for sale at ${eth(c!.gross)} eth and falling (${eth(c!.price)} engine price plus royalty).`
                    : `past its sale window, for sale at ${eth(c!.gross)} eth (${eth(c!.price)} engine price plus royalty)${c!.past ? ", eligible for compose" : ""}.`}
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
            ) : c ? (
              <p className="muted">no record of this credit on the engine.</p>
            ) : null}
          </div>

          {known && (
            <div className="facts">
              {inPile && <Fact k="owner" v="engine" />}
              <Fact k="recorded cost" v={cost != null ? `${eth(cost)} eth` : "—"} />
              <Fact k="got by" v={lastBought ? lastBought.how : "—"} />
              <Fact k="acquired" v={acquiredAt != null ? agoLabel(now - acquiredAt) : "—"} />
              {inPile && snap?.creditSaleOn && <Fact k="sale window" v={left > 0 ? `${countdown(left)} left` : "past window"} />}
              {inPile && snap?.creditSaleOn && <Fact k="sale price" v={`${eth(c!.gross)} eth`} />}
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
  if (e.t === "sold") return <HistRow label="sold" value={`credit sale, ${eth(e.price)} eth`} block={e.block} tx={e.tx} addr={e.buyer} />;
  const note =
    e.how === "eth bid"
      ? `rate after ${e.rate != null ? eth(e.rate) : "—"} eth, pot ${e.pot != null ? eth(e.pot) : "—"} eth`
      : e.how === "listing"
        ? `adapter ${e.adapter ? shortAddr(e.adapter) : "—"}, keeper paid ${e.paid != null ? eth(e.paid) : "—"} eth`
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
