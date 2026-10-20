"use client";

import { statementSaleSplit } from "@/lib/sale-split";
import { useState, type ReactNode } from "react";
import Link from "next/link";
import { useAccount, useReadContract } from "wagmi";
import { StatementTile, CreditTile } from "./Tiles";
import { Act } from "./Act";
import { Addr } from "./Addr";
import { Breadcrumb } from "./Shell";
import { Fact, HeroArt, HistLine, SkFacts, SkHistory, type Ink } from "./Detail";
import { Sk, SkSideSec } from "./Skeleton";
import { NotDeployed } from "./NotDeployed";
import { useStatementRating } from "./Cards";
import { FormingStatement } from "./StatementForming";
import { core, engineDeployed, statements, STATEMENT_SIZE } from "@/lib/config";
import { useHistoryDown, useStatementIndex, useStatementView } from "@/lib/data";
import type { StatementRecord } from "@/lib/events";
import { useBlockTs } from "@/lib/engine";
import { useTokenMeta } from "@/lib/art";
import { controllerAbi, coreAbi, erc20Abi } from "@/lib/abis";
import { countdown, useBalanceToken, useCoinLive, useNow, useSnapshot, useStatements, type HeldStatement, type Snapshot } from "@/lib/live";
import { etaLabel } from "@/lib/compose-eta";
import { BALANCE_SYMBOL, agoLabel, commas, eth, formatHistoricalBalance, signedPct, tokens } from "@/lib/format";

const BUFFER_BPS = 100n; // value above the price; the controller refunds the excess
// TODO(design README open item "Statement format names"): the picker shows format numbers; names come from the
// tokenURI Format attribute of the current format only.
const FORMATS = [0, 1, 2, 3, 4, 5, 6, 7];

// Statement detail. A statement the Core holds reads from the multicall (useStatements): the asking price, the
// reference and the floor state, with buy, restyle and redeem. Facts and history come from the indexer
// (useStatementRecord): credits, format, composer, compose mode, restyles, anchor moves, sale, redemption and owner.
export function LiveStatement({ id }: { id: number }) {
  const { data: snap } = useSnapshot();
  const { data: held, dataUpdatedAt } = useStatements();
  const { rec, owner, isPending } = useStatementView(id);
  const { data: index } = useStatementIndex();
  const { data: meta, isPending: metaPending } = useTokenMeta("statement", id);
  const now = useNow();
  const s = held.find((x) => x.sid === id);
  const composed = rec?.composed;
  const sale = rec?.sold;
  const redeemed = rec?.redeemed;
  const { data: chainComposedTs } = useBlockTs(composed?.ts == null ? composed?.block : undefined);
  const composedTs = composed?.ts ?? chainComposedTs;
  const ratingText = useStatementRating(id, s?.rating ?? rec?.rating);
  if (!engineDeployed) return <NotDeployed />;

  const cost = s?.cost ?? composed?.cost;
  const known = Boolean(s || rec);
  const historyDown = useHistoryDown();
  const formatName = rec?.formatName ?? meta?.attrs.Format;
  const format = rec?.format ?? composed?.format;
  const creditCount = composed?.ids.length ?? (meta?.attrs.Credits != null ? Number(meta.attrs.Credits) : undefined);

  // prev and next among the known and forming statements, newest first. Every pile page with a credit is forming:
  // ids nextStatementId to nextStatementId + ceil(pileSize / 80) - 1.
  const nextSid = snap?.nextStatementId;
  const formingIds = snap && nextSid != null ? Array.from({ length: Math.ceil(Number(snap.pileSize) / STATEMENT_SIZE) }, (_, k) => nextSid + k) : [];
  const ids = [...new Set([...formingIds, ...held.map((x) => x.sid), ...index.map((r) => r.id)])].sort((a, b) => b - a);
  const at = ids.indexOf(id);
  const prevHref = at > 0 ? `/statements/${ids[at - 1]}` : undefined;
  const nextHref = at >= 0 && at < ids.length - 1 ? `/statements/${ids[at + 1]}` : undefined;

  // an id the Core has not minted yet: the page of the pile forming toward it
  if (snap && nextSid != null && id >= nextSid && !known) return <FormingStatement id={id} snap={snap} prevHref={prevHref} nextHref={nextHref} />;

  // the record is not known yet: facts, history and the rail are skeletons of their usual shape
  const loading = !known && (isPending || !snap);
  const ink: Ink = s ? "y" : redeemed ? "c" : "k";
  const holder: ReactNode = s ? (
    "engine"
  ) : owner ? (
    owner.toLowerCase() === core?.toLowerCase() ? (
      "engine"
    ) : (
      <Addr address={owner} />
    )
  ) : sale ? (
    <Addr address={sale.buyer} />
  ) : (
    "—"
  );

  return (
    <div className="detail-page">
      <Breadcrumb parent="statements" parentHref="/statements" id={id} prevHref={prevHref} nextHref={nextHref} />

      <div className="detail-split">
        <div className="detail-col">
          <div className="detail-body">
            <HeroArt tile={<StatementTile id={id} />} image={meta?.image} file={`statement-${id}.svg`} address={statements} loading={metaPending} />

            <div className="detail-right">
              <div className="label">statement</div>
              <h1 className="detail-id">{id}</h1>

              {!known && !historyDown && !loading && <p className="side-copy fx-in">no record of this statement on the engine.</p>}
              {loading && <SkFacts keys={["credit rating", "format", "engine cost", "credits", "composed", "holder"]} />}
              {loading && <SkHistory n={2} />}
              {known && (
                <dl className="dfacts fx-in">
                  <Fact k="credit rating" v={ratingText || "—"} />
                  <Fact
                    k="format"
                    v={
                      format != null
                        ? `${format}${formatName ? ` · ${String(formatName).toLowerCase()}` : ""}${
                            composed && format !== composed.format ? ` · restyled from ${composed.format}` : ""
                          }`
                        : (formatName && String(formatName).toLowerCase()) || "—"
                    }
                  />
                  <Fact k="engine cost" v={cost != null ? `${eth(cost)} ETH` : "—"} />
                  <Fact k="credits" v={creditCount != null ? String(creditCount) : "—"} />
                  {composed && (
                    <Fact
                      k="composed"
                      v={`${composedTs != null ? agoLabel(now - composedTs) : "—"} · ${
                        composed.mode === "chosen" ? "chosen compose" : composed.mode === "default" ? "default compose" : "compose"
                      }`}
                    />
                  )}
                  <Fact k="holder" v={holder} />
                </dl>
              )}

              {known && <History s={s} rec={rec} />}
              {historyDown && <p className="muted ix-down">history unavailable</p>}
            </div>
          </div>

          {composed && (
            <section className="cband">
              <div className="cband-head">
                <span className="label">{composed.ids.length} credits</span>
                <span className="caption">composed in the order the engine bought them</span>
              </div>
              <div className="cband-grid">
                {composed.ids.map((cid) => (
                  <Link key={cid} href={`/credits/${cid}`} title={`credit #${cid}`}>
                    <CreditTile id={cid} />
                  </Link>
                ))}
              </div>
            </section>
          )}
        </div>

        <aside className={`side ink-${ink}`}>
          {loading || !snap ? (
            <>
              <section className="side-sec" aria-busy="true">
                <div className="label">status</div>
                <div className="status-line">
                  <Sk w="10ch" />
                </div>
              </section>
              <SkSideSec label="price" lines={0} kv={2} action />
            </>
          ) : s ? (
            <>
              <PriceSection s={s} snap={snap} updatedAt={dataUpdatedAt} />
              <RestyleSection s={s} snap={snap} current={format} />
              {snap.balanceOn && <RedeemSection s={s} snap={snap} updatedAt={dataUpdatedAt} />}
            </>
          ) : (
            <ExitSection rec={rec} known={known} cost={cost} />
          )}
        </aside>
      </div>
    </div>
  );
}

// History, newest first: for sale now, then the logged steps.
function History({ s, rec }: { s?: HeldStatement; rec?: StatementRecord }) {
  const composed = rec?.composed;
  return (
    <section className="dhist">
      <div className="label">history</div>
      <div className="dhist-rows">
        {s && <HistLine mark="y" text={s.atFloor ? "at floor" : "for sale, price falling"} value={`${eth(s.price)} ETH`} when="now" />}
        {rec?.redeemed && <RedeemedLine r={rec.redeemed} />}
        {rec?.anchor.map((m) => (
          <HistLine
            key={m.tx}
            mark="hollow"
            ts={m.ts} block={m.block}
            text={`sale at ${pct(m.saleBps)} of reference, anchor now ${pct(m.anchorBps)}`}
            value="—"
          />
        ))}
        {rec?.sold && (
          <HistLine
            mark="hollow"
            ts={rec.sold.ts} block={rec.sold.block}
            text={
              <>
                sold to <Addr address={rec.sold.buyer} />
              </>
            }
            value={`${eth(rec.sold.price)} ETH`}
          />
        )}
        {[...(rec?.restyled ?? [])].reverse().map((r) => (
          <HistLine
            key={r.tx}
            mark="k"
            ts={r.ts} block={r.block}
            text={
              <>
                restyled to format {r.format} by <Addr address={r.caller} />
              </>
            }
            value="—"
          />
        ))}
        {composed && (
          <HistLine mark="y" ts={composed.ts} block={composed.block} text={`composed from ${composed.ids.length} credits`} value={`${eth(composed.cost)} ETH`} />
        )}
      </div>
    </section>
  );
}

function RedeemedLine({ r }: { r: NonNullable<StatementRecord["redeemed"]> }) {
  const balance = useBalanceToken();
  return <HistLine mark="c" ts={r.ts} block={r.block} text={`module received ${formatHistoricalBalance(r.received, r.token, balance)}`} value="—" />;
}

const pct = (bps: bigint | number) => `${(Number(bps) / 100).toLocaleString("en-US", { maximumFractionDigits: 2 })}%`;

// Age of a held statement now: the age read at the last fetch plus the wall clock since, frozen while sales are paused.
const liveAge = (s: HeldStatement, snap: Snapshot, updatedAt: number) =>
  s.age + (snap.paused ? 0 : Math.max(0, (Date.now() - updatedAt) / 1000));

// Status, price now, the falling curve and the buy button. Curve (see Snapshot): ask = reference * bps / 10000, with
// bps falling linearly from statementStartBps at age 0 to settings.saleFloorBps at statementDecayHours, then flat.
function PriceSection({ s, snap, updatedAt }: { s: HeldStatement; snap: Snapshot; updatedAt: number }) {
  if (snap.statementDecayHours === undefined || snap.statementStartBps === undefined) return null;
  const T = snap.statementDecayHours * 3600;
  const age = liveAge(s, snap, updatedAt);
  const left = s.atFloor ? 0 : Math.max(0, T - age);
  // _ask clamps the start to the floor
  const startBps = Math.max(snap.statementStartBps, snap.settings.saleFloorBps);
  const start = (s.reference * BigInt(startBps)) / 10000n;
  const floor = (s.reference * BigInt(snap.settings.saleFloorBps)) / 10000n;
  const W = 352;
  const xEnd = 240;
  const marker = left > 0 ? Math.min(1, age / T) * xEnd : 320;
  const y0 = start > floor ? 12 : 80;
  const yAt = (x: number) => (left > 0 ? y0 + ((80 - y0) * x) / xEnd : 80);
  const startX = startBps / 10000;

  // Share of the price by destination (Core.sellTo): artist and operator cuts first, then saleToBuybackBps of the rest.
  const { pot, buyback, cuts } = statementSaleSplit(snap.settings);

  return (
    <>
      <section className="side-sec">
        <div className="label">status</div>
        <div className="status-line">
          <span className="mark y" />
          {s.atFloor ? "at floor" : "for sale"}
        </div>
      </section>
      <section className="side-sec">
        <div className="price-head">
          <div>
            <div className="label">price</div>
            <div className="big-price">
              {eth(s.price)} <small>ETH</small>
            </div>
          </div>
          <div className="price-note" suppressHydrationWarning>
            {left > 0 ? (
              <>
                falling
                <br />
                floor in {countdown(left)}
              </>
            ) : (
              "at floor"
            )}
          </div>
        </div>
        <svg className="curve" width="100%" viewBox={`0 0 ${W} 92`} role="img" aria-label="price curve">
          <line x1="0" y1="80" x2={W} y2="80" className="curve-floor" />
          <polyline points={`0,${y0} ${xEnd},80 ${W},80`} className="curve-line" />
          <line x1={marker} y1="0" x2={marker} y2="92" className="curve-now" />
          <rect x={marker - 4} y={yAt(marker) - 4} width="8" height="8" className="curve-dot" />
          <line x1={xEnd} y1="76" x2={xEnd} y2="84" className="curve-tick" />
        </svg>
        <div className="curve-labels">
          <span>
            {commas(startX, 2)}x · {eth(start)}
          </span>
          <span>floor {eth(floor)}</span>
          <span>{snap.statementDecayHours}h</span>
        </div>
        <div className="side-act">
          <Act
            label={snap.paused ? "engine paused" : "buy statement"}
            disabled={snap.paused}
            steps={async (write) =>
              void (await write({
                address: snap.controller,
                abi: controllerAbi,
                functionName: "buy",
                args: [BigInt(s.sid)],
                value: s.price + (s.price * BUFFER_BPS) / 10000n,
              }))
            }
          />
        </div>
        <p className="caption">
          {commas(pot, 2)}% of the sale goes back to the pot · {commas(buyback, 2)}% buys and burns $CC
          {cuts > 0 && ` · ${commas(cuts, 2)}% to the artist and operator`}
        </p>
      </section>
    </>
  );
}

// Restyle a held statement (Core.setHeldFormat). Needs snap.minCcToChoose of $CC in the wallet.
function RestyleSection({ s, snap, current }: { s: HeldStatement; snap: Snapshot; current?: number }) {
  const { address } = useAccount();
  const coinLive = useCoinLive();
  const [pick, setPick] = useState<number | undefined>();
  const { data: ccBal } = useReadContract({
    address: snap.coin,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(coinLive !== false && address && snap.minCcToChoose > 0n) },
  });
  const ccOk = snap.minCcToChoose === 0n || (ccBal ?? 0n) >= snap.minCcToChoose;
  const sel = pick ?? current;
  const changed = pick != null && pick !== current;
  return (
    <section className="side-sec">
      <div className="swap-head">
        <span className="label">restyle</span>
        {current != null && <span className="caption">current: {current}</span>}
      </div>
      <p className="side-copy">
        change the format while the engine holds it.
        {snap.minCcToChoose > 0n && ` needs at least ${tokens(snap.minCcToChoose)} $CC in your wallet.`}
      </p>
      <div className="seg seg-fill" role="radiogroup" aria-label="format">
        {FORMATS.map((f) => (
          <button key={f} role="radio" aria-checked={sel === f} className={sel === f ? "on" : ""} onClick={() => setPick(f)}>
            {f}
          </button>
        ))}
      </div>
      <div className="side-act">
        <Act
          secondary
          label={pick == null ? "pick a format" : `restyle to format ${pick}`}
          disabled={!changed || !ccOk}
          title={!ccOk ? "$CC balance below the minimum" : undefined}
          steps={async (write) => {
            if (pick == null) return;
            await write({ address: core, abi: coreAbi, functionName: "setHeldFormat", args: [BigInt(s.sid), pick] });
            setPick(undefined);
          }}
        />
      </div>
      {changed && !ccOk && <p className="caption">your $CC balance is below the minimum.</p>}
    </section>
  );
}

// Redeem a held statement for the balance token (Core.redeemStatement), once it is at its floor and redeemOn is set.
function RedeemSection({ s, snap, updatedAt }: { s: HeldStatement; snap: Snapshot; updatedAt: number }) {
  const T = (snap.statementDecayHours ?? 0) * 3600;
  const left = s.atFloor || T === 0 ? 0 : Math.max(0, T - liveAge(s, snap, updatedAt));
  const on = snap.settings.redeemOn;
  const ready = on && s.atFloor;
  return (
    <section className="side-sec">
      <div className="swap-head">
        <span className="label">redeem</span>
        <span className="caption" suppressHydrationWarning>
          {!on ? "redemption is off" : s.atFloor ? "at floor" : `opens at floor · ${etaLabel({ seconds: left, estimated: true })}`}
        </span>
      </div>
      <p className="side-copy">once eligible, anyone can move this statement to the balance module. The module keeps the {BALANCE_SYMBOL} it receives; the caller may earn an ETH tip.</p>
      <div className="side-act">
        <Act
          secondary
          label="redeem to module"
          disabled={!ready}
          title={!on ? "redemption is off" : !s.atFloor ? "the price has not reached its floor" : undefined}
          steps={async (write) => void (await write({ address: core, abi: coreAbi, functionName: "redeemStatement", args: [BigInt(s.sid)] }))}
        />
      </div>
    </section>
  );
}

// Rail of a statement the engine no longer holds: state, and the sale split from the StatementSoldTo event.
function ExitSection({ rec, known, cost }: { rec?: StatementRecord; known: boolean; cost?: bigint }) {
  const balance = useBalanceToken();
  const sale = rec?.sold;
  const redeemed = rec?.redeemed;
  const title = sale ? "sold" : redeemed ? "redeemed" : known ? "not held by engine" : "unknown";
  const mark = redeemed ? "c" : "divider";
  const artist = sale?.toArtist ?? 0n;
  const operator = sale?.toOperator ?? 0n;
  const pot = sale?.toPot ?? (sale?.toBuyback != null ? sale.price - artist - operator - sale.toBuyback : undefined);
  return (
    <>
      <section className="side-sec">
        <div className="label">status</div>
        <div className="status-line">
          <span className={`mark ${mark}`} />
          {title}
        </div>
        {sale && (
          <p className="side-copy">
            bought by <Addr address={sale.buyer} />.
          </p>
        )}
        {redeemed && <p className="side-copy">the module received {formatHistoricalBalance(redeemed.received, redeemed.token, balance)}.</p>}
        {!sale && !redeemed && known && <p className="side-copy">no sale or redemption is logged for this statement.</p>}
      </section>
      {sale && (
        <section className="side-sec">
          <Kv k="sold for" v={`${eth(sale.price)} ETH`} />
          {cost != null && <Kv k="engine cost" v={`${eth(cost)} ETH · ${signedPct((Number(sale.price) / Number(cost) - 1) * 100)}`} />}
          {artist > 0n && <Kv k="to artist" v={`${eth(artist)} ETH`} />}
          {operator > 0n && <Kv k="to operator" v={`${eth(operator)} ETH`} />}
          {sale.toBuyback != null && <Kv k="to buyback" v={`${eth(sale.toBuyback)} ETH`} />}
          {pot != null && <Kv k="to pot" v={`${eth(pot)} ETH`} />}
        </section>
      )}
    </>
  );
}

function Kv({ k, v }: { k: string; v: string }) {
  return (
    <div className="kv">
      <span className="muted">{k}</span>
      <span>{v}</span>
    </div>
  );
}
