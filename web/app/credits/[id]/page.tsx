"use client";

import { useState } from "react";
import Link from "next/link";
import { notFound } from "next/navigation";
import { useAccount, usePublicClient, useReadContract } from "wagmi";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { CreditTile } from "@/components/Tiles";
import { Act } from "@/components/Act";
import { Addr } from "@/components/Addr";
import { HistRow } from "@/components/History";
import { NotDeployed } from "@/components/NotDeployed";
import { core, credits, engineDeployed } from "@/lib/config";
import { coreAbi, creditsAbi, erc20Abi } from "@/lib/abis";
import { useBlockTs, useScan, type CreditEvt } from "@/lib/engine";
import { countdown, useCredit, useNow, useScores, useSnapshot, type Snapshot } from "@/lib/live";
import { agoLabel, eth, shortAddr } from "@/lib/format";
import type { Write } from "@/lib/tx";

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
            ) : last?.t === "swapped" && last.dir === "out" ? (
              <p>
                swapped out of the pile by <Addr address={last.caller} /> for{" "}
                <Link href={`/credits/${last.other}`} className="xlink-inline">
                  credit {last.other}
                </Link>
                .
              </p>
            ) : c ? (
              <p className="muted">no record of this credit on the engine.</p>
            ) : null}
          </div>

          {inPile && snap && <SwapPanel outId={id} snap={snap} />}

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
  if (e.t === "swapped")
    return (
      <HistRow
        label={e.dir === "in" ? "swapped in" : "swapped out"}
        value={
          <>
            {e.dir === "in" ? "for pile credit " : "replaced by "}
            <Link href={`/credits/${e.other}`} className="xlink-inline">
              credit {e.other}
            </Link>
            {` · fee ${eth(e.fee)} CC`}
          </>
        }
        block={e.block}
        tx={e.tx}
        addr={e.caller}
      />
    );
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

// Swap this pile credit for one the connected wallet owns of equal or higher
// score, for the swapFeeCc coin fee (Core.swapCredit). The wallet credits are
// filtered to those scoring at least the pile credit; the caller approves the
// coin for the fee and the Credits collection for the Core once, then one tx.
function SwapPanel({ outId, snap }: { outId: number; snap: Snapshot }) {
  const { address, isConnected } = useAccount();
  const { openConnectModal } = useConnectModal();
  const client = usePublicClient();
  const [inId, setInId] = useState<number | null>(null);
  const fee = snap.settings.swapFeeCc;

  const { data: held } = useReadContract({
    address: credits,
    abi: creditsAbi,
    functionName: "tokensOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address && engineDeployed) },
  });
  const mine: number[] = (held ?? []).map(Number);
  const { data: scores } = useScores([BigInt(outId), ...mine.map(BigInt)]);
  const outScore = scores?.[outId.toString()];
  const eligible = mine.filter((id) => scores && outScore != null && scores[id.toString()] >= outScore);

  async function swap(write: Write) {
    if (!address || !client || inId == null) return;
    if (fee > 0n) {
      const allowance = await client.readContract({ address: snap.coin, abi: erc20Abi, functionName: "allowance", args: [address, core!] });
      if (allowance < fee) await write({ address: snap.coin, abi: erc20Abi, functionName: "approve", args: [core, fee] });
    }
    const ok = await client.readContract({ address: credits, abi: creditsAbi, functionName: "isApprovedForAll", args: [address, core!] });
    if (!ok) await write({ address: credits, abi: creditsAbi, functionName: "setApprovalForAll", args: [core, true] });
    await write({ address: core, abi: coreAbi, functionName: "swapCredit", args: [BigInt(inId), BigInt(outId)] });
    setInId(null);
  }

  return (
    <div className="section">
      <h2>swap</h2>
      <p className="muted">
        swap this credit for one you own of equal or higher score, for a {eth(fee)} CC fee the engine burns.
      </p>
      {!isConnected ? (
        <button className="action" onClick={openConnectModal}>
          connect to swap
        </button>
      ) : eligible.length === 0 ? (
        <p className="muted">
          {scores == null ? "reading scores…" : "none of your credits scores at or above this one."}
        </p>
      ) : (
        <>
          <div className="rowlist">
            {eligible.map((id) => (
              <label key={id} className="rowline swap-pick">
                <input type="radio" name="swap-in" checked={inId === id} onChange={() => setInId(id)} />
                <CreditTile id={id} />
                <span className="rl-id">credit #{id}</span>
                <span className="rl-meta muted">score {scores![id.toString()].toString()}</span>
              </label>
            ))}
          </div>
          <Act
            label={inId == null ? "pick a credit" : `swap in credit #${inId}`}
            disabled={inId == null}
            steps={swap}
          />
        </>
      )}
    </div>
  );
}
