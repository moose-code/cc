"use client";

import { useState, type ReactNode } from "react";
import Link from "next/link";
import { notFound } from "next/navigation";
import { useAccount, usePublicClient } from "wagmi";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { CreditTile, StatementTile } from "@/components/Tiles";
import { Act } from "@/components/Act";
import { Addr } from "@/components/Addr";
import { Breadcrumb } from "@/components/Shell";
import { Fact, HeroArt, HistLine, SkFacts, SkHistory, type Ink } from "@/components/Detail";
import { Sk } from "@/components/Skeleton";
import { NotDeployed } from "@/components/NotDeployed";
import { useComposeEta } from "@/components/ComposeEta";
import { core, credits, engineDeployed, STATEMENT_SIZE } from "@/lib/config";
import { coreAbi, creditsAbi, erc20Abi } from "@/lib/abis";
import { useCreditDetail, useHistoryDown, useStatementView, type CreditSale } from "@/lib/data";
import type { CreditEvt } from "@/lib/events";
import {
  countdown,
  useCreditValues,
  useNow,
  usePile,
  useSnapshot,
  useStatements,
  useWalletCredits,
  type PileCredit,
  type Snapshot,
} from "@/lib/live";
import { useTokenMeta } from "@/lib/art";
import { buyCredits } from "@/lib/buy";
import { etaLabel, windowLabel } from "@/lib/compose-eta";
import { eth, evmNowTx, rating, shortAddr, tokens } from "@/lib/format";
import type { Write } from "@/lib/tx";

const PLATES: { letter: string; bit: number }[] = [
  { letter: "C", bit: 1 },
  { letter: "M", bit: 2 },
  { letter: "Y", bit: 4 },
  { letter: "K", bit: 8 },
];

// A credit the engine bought. Facts (cost, time, score, plates, owner, sale split) are the indexer's credit row; the
// price now comes from the live pile read. The history is the indexer's activity rows: how the engine got it,
// swaps, the credit sale and the statement it composed into.
export default function CreditDetail({ params }: { params: { id: string } }) {
  const id = Number(params.id);
  if (!Number.isInteger(id) || id < 0) notFound();
  const { data: snap } = useSnapshot();
  const { data: pile } = usePile();
  const now = useNow();
  const d = useCreditDetail(id);
  const { data: meta, isPending: metaPending } = useTokenMeta("credit", id);
  const historyDown = useHistoryDown();
  if (!engineDeployed) return <NotDeployed />;

  const { c, evts, last, inPile, known, cost, acquiredAt, how, score, mask, owner } = d;
  const window = snap?.creditWindow ?? 0;
  const left = acquiredAt != null ? acquiredAt + window - now : 0;
  const saleOn = snap?.creditSaleOn ?? false;

  // prev and next among the credits the engine holds, newest first
  const held = [...pile].reverse();
  const at = held.findIndex((p) => p.id === id);
  const prevHref = at > 0 ? `/credits/${held[at - 1].id}` : undefined;
  const nextHref = at >= 0 && at < held.length - 1 ? `/credits/${held[at + 1].id}` : undefined;

  const state: "sale" | "floor" | "held" | "composed" | "sold" | "other" = inPile
    ? !saleOn
      ? "held"
      : left > 0
        ? "sale"
        : "floor"
    : d.state === "held"
      ? "held"
      : d.state;
  const ink: Ink = { sale: "m", floor: "k", held: "k", composed: "y", sold: "c", other: "k" }[state] as Ink;

  const holder: ReactNode = inPile ? (
    "engine"
  ) : last?.t === "composed" ? (
    <Link href={`/statements/${last.sid}`}>statement {last.sid}</Link>
  ) : owner ? (
    owner.toLowerCase() === core?.toLowerCase() ? (
      "engine"
    ) : (
      <Addr address={owner} />
    )
  ) : last?.t === "sold" ? (
    <Addr address={last.buyer} />
  ) : (
    "—"
  );

  return (
    <div className="detail-page">
      <Breadcrumb parent="credits" parentHref="/credits" id={id} prevHref={prevHref} nextHref={nextHref} />

      <div className="detail-split">
        <div className="detail-body">
          <HeroArt tile={<CreditTile id={id} />} image={meta?.image} file={`credit-${id}.svg`} address={credits} loading={metaPending} />

          <div className="detail-right">
            <div className="label">credit</div>
            <h1 className="detail-id">#{id}</h1>

            {d.loading && <SkFacts keys={["credit rating", "plates", "holder", "paid by engine", "got by", "acquired", "transaction id"]} />}
            {d.loading && <SkHistory n={2} />}
            {!d.loading && known && (
              <dl className="dfacts fx-in">
                <Fact k="credit rating" v={score != null ? rating(score) : "—"} />
                {mask != null && (
                  <Fact
                    k="plates"
                    v={
                      <span className="plate-letters">
                        {PLATES.map((p) => (
                          <b key={p.letter} className={mask & p.bit ? "on" : ""}>
                            {p.letter}
                          </b>
                        ))}
                      </span>
                    }
                  />
                )}
                <Fact k="holder" v={holder} />
                <Fact k="paid by engine" v={cost != null ? `${eth(cost)} ETH` : "—"} />
                <Fact k="got by" v={how ?? "—"} />
                <Fact k="acquired" v={acquiredAt != null ? utc(acquiredAt) : "—"} />
                <Fact
                  k="transaction id"
                  v={
                    d.tx ? (
                      <a href={evmNowTx(d.tx)} target="_blank" rel="noreferrer">
                        {d.tx}
                      </a>
                    ) : (
                      "—"
                    )
                  }
                />
              </dl>
            )}

            {historyDown && <p className="muted ix-down">history unavailable</p>}
            {!d.loading && (evts.length > 0 || state === "sale" || state === "floor") && (
              <section className="dhist fx-in">
                <div className="label">history</div>
                <div className="dhist-rows">
                  {state === "sale" && c && (
                    <HistLine mark="m" text="for sale, price falling" value={c.price > 0n ? `${eth(c.price)} ETH` : <Sk w="9ch" />} when="now" />
                  )}
                  {state === "floor" && c && <HistLine mark="k" text="at floor" value={c.price > 0n ? `${eth(c.price)} ETH` : <Sk w="9ch" />} when="now" />}
                  {[...evts].reverse().map((e, i) => (
                    <Step key={`${e.tx}-${i}`} e={e} />
                  ))}
                </div>
              </section>
            )}
            {/* TODO(plate breakdown band): hidden. Per-plate 8x8 bitmaps (SHA-256 of the transaction id split into four
                64-bit plates) are not derivable from the contract reads; only the printed plate mask is. */}
          </div>
        </div>

        <aside className={`side ink-${ink}`}>
          <section className="side-sec">
            <div className="label">status</div>
            {d.loading ? (
              <>
                <div className="status-line">
                  <Sk w="14ch" />
                </div>
                <p className="side-copy">
                  <Sk w="80%" />
                </p>
              </>
            ) : (
              <div className="fx-in">
                <Status state={state} last={last} window={window} />
              </div>
            )}
          </section>
          {inPile && snap && <ComposeBox id={id} pile={pile} snap={snap} />}
          {inPile && snap && saleOn && c && (
            <PriceBox id={id} c={c} snap={snap} left={left} now={now} acquiredAt={c.acquiredAt} />
          )}
          {state === "composed" && last?.t === "composed" && <StatementCard sid={last.sid} />}
          {state === "sold" && d.sale && <SoldSplit sale={d.sale} />}
          {inPile && snap && <SwapPanel outId={id} outScore={score} snap={snap} />}
        </aside>
      </div>
    </div>
  );
}

// "Oct 15, 2026 · 13:46 UTC"
function utc(ts: number): string {
  const d = new Date(ts * 1000);
  const date = d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
  const time = d.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", timeZone: "UTC" });
  return `${date} · ${time} UTC`;
}

function Status({
  state,
  last,
  window,
}: {
  state: "sale" | "floor" | "held" | "composed" | "sold" | "other";
  last?: CreditEvt;
  window: number;
}) {
  const ink = { sale: "m", floor: "k", held: "k", composed: "y", sold: "c", other: "k" }[state];
  const title = {
    sale: "for sale",
    floor: "at floor, waiting to compose",
    held: "held by engine",
    composed: "composed",
    sold: "sold",
    other: last?.t === "swapped" ? "swapped out" : "not held by engine",
  }[state];
  let text: ReactNode = null;
  if (state === "sale") text = `listed by the engine. the price falls for ${windowLabel(window)} from purchase, then rests at its floor.`;
  else if (state === "floor") text = "the price rests at its floor until the credit composes.";
  else if (state === "held") text = "the credit sale is off.";
  else if (last?.t === "composed")
    text = (
      <>
        composed into <Link href={`/statements/${last.sid}`}>statement {last.sid}</Link>.
      </>
    );
  else if (last?.t === "sold")
    text = (
      <>
        bought out of the credit sale by <Addr address={last.buyer} />.
      </>
    );
  else if (last?.t === "swapped" && last.dir === "out")
    text = (
      <>
        swapped out by <Addr address={last.caller} /> for <Link href={`/credits/${last.other}`}>credit #{last.other}</Link>.
      </>
    );
  return (
    <>
      <div className="status-line">
        <span className={`mark ${ink}`} />
        {title}
      </div>
      {text && <p className="side-copy">{text}</p>}
    </>
  );
}

// Compose estimate: statement id, countdown, queue position and an 8x10 map of the page.
function ComposeBox({ id, pile, snap }: { id: number; pile: PileCredit[]; snap: Snapshot }) {
  const eta = useComposeEta(pile);
  const index = pile.findIndex((p) => p.id === id);
  if (index < 0) return null;
  const k = Math.floor(index / STATEMENT_SIZE);
  const inPage = Math.min(STATEMENT_SIZE, Number(snap.pileSize) - k * STATEMENT_SIZE);
  const e = eta.at(index);
  return (
    <section className="side-sec">
      <div className="compose-box">
        <div>
          <div className="caption">composes into statement {snap.nextStatementId != null ? snap.nextStatementId + k : "next"} in</div>
          <div className="compose-eta">{e ? (e.estimated ? etaLabel(e) : e.seconds > 0 ? countdown(e.seconds) : "now") : "—"}</div>
          <div className="caption">
            position {(index % STATEMENT_SIZE) + 1} of {STATEMENT_SIZE}
            {e?.estimated && " · estimate"}
          </div>
        </div>
        <div className="mini-map" aria-hidden>
          {Array.from({ length: STATEMENT_SIZE }, (_, j) => (
            <i key={j} className={j === index % STATEMENT_SIZE ? "me" : j < inPage ? "on" : ""} />
          ))}
        </div>
      </div>
    </section>
  );
}

// Price now, the falling curve and the buy button. Curve (see Snapshot): floor = max(cost, valueOf(score)) *
// creditFloorBps / 10000 (floorMultBps: the spread over the bid's hard cap), start = floor * creditStartBps / 10000, linear over the sale window, then flat.
function PriceBox({
  id,
  c,
  snap,
  left,
  now,
  acquiredAt,
}: {
  id: number;
  c: PileCredit;
  snap: Snapshot;
  left: number;
  now: number;
  acquiredAt: number;
}) {
  const { data: values } = useCreditValues([BigInt(id)]);
  const value = values?.[id.toString()];
  const floor = value != null && snap.creditFloorBps != null ? ((c.cost > value ? c.cost : value) * BigInt(snap.creditFloorBps)) / 10000n : undefined;
  const start = floor != null && snap.creditStartBps != null ? (floor * BigInt(snap.creditStartBps)) / 10000n : undefined;
  const W = 352;
  const xEnd = 240;
  const el = now - acquiredAt;
  const frac = Math.min(1, Math.max(0, el / snap.creditWindow));
  const marker = left > 0 ? frac * xEnd : 320;
  const y0 = start != null && floor != null && start > floor ? 12 : 80;
  const hh = (t: number) =>
    new Date(t * 1000).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
  const yAt = (x: number) => (left > 0 ? y0 + ((80 - y0) * x) / xEnd : 80);
  return (
    <section className="side-sec">
      <div className="price-head">
        <div>
          <div className="label">price</div>
          <div className="big-price">
            {c.price > 0n ? eth(c.price) : <Sk w="6ch" />} <small>ETH</small>
          </div>
        </div>
        <div className="price-note">{left > 0 ? <>falling<br />floor in {countdown(left)}</> : "at floor"}</div>
      </div>
      {start != null && (
        <>
          <svg className="curve" width="100%" viewBox={`0 0 ${W} 92`} role="img" aria-label="price curve">
            <line x1="0" y1="80" x2={W} y2="80" className="curve-floor" />
            <polyline points={`0,${y0} ${xEnd},80 ${W},80`} className="curve-line" />
            <line x1={marker} y1="0" x2={marker} y2="92" className="curve-now" />
            <rect x={marker - 4} y={yAt(marker) - 4} width="8" height="8" className="curve-dot" />
            <line x1={xEnd} y1="76" x2={xEnd} y2="84" className="curve-tick" />
          </svg>
          <div className="curve-labels" suppressHydrationWarning>
            <span>bought {hh(acquiredAt)}</span>
            <span>floor {hh(acquiredAt + snap.creditWindow)}</span>
            <span>composed</span>
          </div>
        </>
      )}
      <div className="side-act">
        {/* a price of 0 is one not read yet: buying waits for it */}
        <Act label={snap.paused ? "engine paused" : "buy credit"} disabled={snap.paused || c.price === 0n} steps={(write) => buyCredits(write, snap, [id], c.price)} />
      </div>
    </section>
  );
}

function StatementCard({ sid }: { sid: number }) {
  const { data: held } = useStatements();
  const { rec: r } = useStatementView(sid);
  const h = held.find((s) => s.sid === sid);
  const line = h
    ? `${h.atFloor ? "at floor" : "for sale"} · ${eth(h.price)} ETH`
    : r?.sold
      ? `sold · ${eth(r.sold.price)} ETH`
      : r?.redeemed
        ? "redeemed"
        : "";
  return (
    <section className="side-sec">
      <div className="stmt-card">
        <StatementTile id={sid} />
        <div>
          <b>statement {sid}</b>
          <div className="muted">{line}</div>
          <Link href={`/statements/${sid}`} className="ulink">
            view statement →
          </Link>
        </div>
      </div>
    </section>
  );
}

// Sale split of a credit bought out of the credit sale (Core.sellCreditTo): the artist and operator cuts come off the
// price, then min(engine cost * creditCostToPotBps / 10000, rest) goes to the pot and the remainder to the buyback.
// Indexer mode shows the split stored with the sale; chain mode computes it with creditCostToPotBps at the sale block
// ("~" when that block cannot be read and the current value is used).
function SoldSplit({ sale }: { sale: CreditSale }) {
  const approx = sale.approx ? "~" : "";
  const line = (k: string, v: bigint | undefined, always = false, mark = "") =>
    v != null && (always || v > 0n) ? (
      <div className="kv">
        <span className="muted">{k}</span>
        <span>{mark}{eth(v)} ETH</span>
      </div>
    ) : null;
  return (
    <section className="side-sec">
      {line("sold for", sale.price, true)}
      {line("engine paid", sale.paid, true)}
      {line("to artist", sale.toArtist)}
      {line("to operator", sale.toOperator)}
      {line("to buyback", sale.toBuyback, true, approx)}
      {line("to pot", sale.toPot, true, approx)}
    </section>
  );
}

function Step({ e }: { e: CreditEvt }) {
  if (e.t === "composed")
    return (
      <HistLine
        mark="y"
        ts={e.ts}
        block={e.block}
        text={
          <>
            composed into <Link href={`/statements/${e.sid}`}>statement {e.sid}</Link>
          </>
        }
        value="—"
      />
    );
  if (e.t === "sold")
    return (
      <HistLine
        mark="c"
        ts={e.ts}
        block={e.block}
        text={
          <>
            bought in the credit sale by <Addr address={e.buyer} />
          </>
        }
        value={`${eth(e.price)} ETH`}
      />
    );
  if (e.t === "swapped")
    return (
      <HistLine
        mark="hollow"
        ts={e.ts}
        block={e.block}
        text={
          <>
            {e.dir === "in" ? "swapped in for " : "swapped out for "}
            <Link href={`/credits/${e.other}`}>credit #{e.other}</Link>
            {` by `}
            <Addr address={e.caller} />
          </>
        }
        value={`${tokens(e.fee)} CC`}
      />
    );
  return (
    <HistLine
      mark="hollow"
      ts={e.ts}
      block={e.block}
      text={
        e.how === "adopted" ? (
          "adopted"
        ) : e.how === "listing" && e.adapter ? (
          `bought from a listing via ${shortAddr(e.adapter)}`
        ) : (
          `bought at the ${e.how === "eth bid" ? "ETH bid" : e.how}`
        )
      }
      value={`${eth(e.cost)} ETH`}
    />
  );
}

// Swap this pile credit for one the connected wallet owns of equal or higher
// rating, for the swapFeeCc coin fee (Core.swapCredit). The wallet credits are
// filtered to those rated at least the pile credit; the caller approves the
// coin for the fee and the Credits collection for the Core once, then one tx.
function SwapPanel({ outId, outScore, snap }: { outId: number; outScore?: bigint; snap: Snapshot }) {
  const { address, isConnected } = useAccount();
  const { openConnectModal } = useConnectModal();
  const client = usePublicClient();
  const [inId, setInId] = useState<number | null>(null);
  const fee = snap.settings.swapFeeCc;

  const { data: wallet, scores, ready } = useWalletCredits(address);
  const eligible = wallet.filter((w) => outScore != null && w.score >= outScore).map((w) => w.id);

  async function swap(write: Write) {
    if (snap.paused || !address || !client || inId == null) return;
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
    <section className="side-sec">
      <div className="swap-head">
        <span className="label">swap</span>
        {fee > 0n && <span className="caption">{tokens(fee)} CC burned</span>}
      </div>
      <p className="side-copy">trade one of your credits with an equal or higher rating for this one.</p>
      {!isConnected ? (
        <button className="action secondary" onClick={openConnectModal} disabled={snap.paused}>
          {snap.paused ? "engine paused" : "connect to swap"}
        </button>
      ) : eligible.length === 0 ? (
        <p className="side-copy">{!ready || outScore == null ? "reading ratings…" : "none of your credits rates at or above this one."}</p>
      ) : (
        <>
          <div className="swap-list">
            {eligible.map((id) => (
              <label key={id} className="swap-row">
                <input type="radio" name="swap-in" className="radio" checked={inId === id} onChange={() => setInId(id)} />
                <CreditTile id={id} />
                <span className="swap-id">credit #{id}</span>
                <span className="muted">rating {rating(scores![id.toString()])}</span>
              </label>
            ))}
          </div>
          <div className="side-act">
            <Act
              secondary
              label={snap.paused ? "engine paused" : inId == null ? "pick a credit" : `swap in credit #${inId}`}
              disabled={snap.paused || inId == null}
              steps={swap}
            />
          </div>
        </>
      )}
    </section>
  );
}
