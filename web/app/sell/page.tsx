"use client";

import { useEffect, useMemo, useState, type KeyboardEvent, type MouseEvent } from "react";
import Link from "next/link";
import { formatUnits } from "viem";
import { useAccount, usePublicClient } from "wagmi";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { CreditTile } from "@/components/Tiles";
import { Act } from "@/components/Act";
import { NotDeployed } from "@/components/NotDeployed";
import { ArtFrame, PageHead } from "@/components/Shell";
import { core, credits, engineDeployed, SCORE_PER_100_POINTS } from "@/lib/config";
import { coreAbi, creditsAbi } from "@/lib/abis";
import { balanceFills, balanceQuote, potPoints, sellQuote, useBalanceToken, useBidsOf, useNow, useSellQuote, useSnapshot, useWalletCredits } from "@/lib/live";
import { BALANCE_SYMBOL, balanceAmount, commas, eth, rating, usd } from "@/lib/format";
import type { Write } from "@/lib/tx";
import { useBalanceInEth, useEthUsd } from "@/lib/market";

const MIN_OUT_BPS = 9950n; // 0.5% under the batch total quoted at click time
const CARDS_UP_TO = 8; // a wallet of up to 8 credits shows cards, a larger one the table
const ROWS = 14; // table rows per page
const FILLS_CARDS = 4; // fill list rows in the rail before "+ N more"
const FILLS_TABLE = 5;

type Cur = "eth" | "bal";
type Sort = "offer" | "rating" | "id";
type Credit = { id: number; score: bigint };

// Holders sell their credits (the external Credits NFT) into the engine:
// Credits.setApprovalForAll(Core, true) once, then Core.sellForEth(ids, minOut),
// or Core.sellForBalance(ids, minOut, expectedToken) while the balance bid is on.
// The ids go in the list's sort order: the quote, the fill list, minOut and the tx args all use that one array.
export default function SellPage() {
  const { address, isConnected } = useAccount();
  const { openConnectModal } = useConnectModal();
  const client = usePublicClient();
  const { data: snap } = useSnapshot();
  const bal = useBalanceToken();
  const balanceEth = useBalanceInEth();
  const { data: ethUsd } = useEthUsd();
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [cur, setCur] = useState<Cur>("eth");
  const [sort, setSort] = useState<Sort>("offer");
  const [page, setPage] = useState(0);
  const [anchor, setAnchor] = useState<number>();

  const bid = snap?.ethRate ?? 0n; // wei per 100 points
  const pot = snap?.ethPot ?? 0n;
  // the module reads can fail; the balance side is then unavailable and the eth side renders alone
  const balanceBid = Boolean(snap?.balanceOn && snap.settings.balanceBidOn && snap.balanceUnit !== undefined);
  const isBal = cur === "bal" && balanceBid;
  const now = useNow(5000);
  const balanceQuoteMissing = isBal && Boolean(snap?.value.on) && (snap?.value.perPointSell ?? 0n) === 0n;

  const { data: wallet, ready } = useWalletCredits(isConnected ? address : undefined);
  // each credit's own eth bid, ethRate() * score / 1,000,000 (one multicall of Core.bidOf); the snapshot rate
  // gives the same figure while the multicall loads
  const { data: bids } = useBidsOf(wallet.map((c) => BigInt(c.id)), now);
  const bidForId = (c: Credit): bigint => bids?.[c.id.toString()] ?? (bid * c.score) / SCORE_PER_100_POINTS;
  // the per-credit balance payout from the indexed scores and the snapshot, through balanceFills: the posted rate
  // outside value mode, the value rate clamp at the protected sale price in value mode, and 0 when that price is missing
  const balanceForId = (c: Credit): bigint => (balanceBid && snap ? (balanceFills(snap, [c.score])[0] ?? 0n) : 0n);

  // the offer is the bid times the score, so offer order is score order; ties by id
  const list = useMemo(() => {
    const r = [...wallet];
    const byId = (a: Credit, b: Credit) => a.id - b.id;
    if (sort === "id") return r.sort(byId);
    const dir = sort === "offer" ? -1 : 1;
    return r.sort((a, b) => (a.score === b.score ? byId(a, b) : a.score < b.score ? -dir : dir));
  }, [wallet, sort]);
  const many = list.length > CARDS_UP_TO;
  const pages = Math.max(1, Math.ceil(list.length / ROWS));
  useEffect(() => setPage((p) => Math.min(p, pages - 1)), [pages]);

  // drop ids that left the wallet (sold, transferred)
  useEffect(() => {
    if (!ready) return;
    setSelected((prev) => {
      const held = new Set(wallet.map((c) => c.id));
      const next = new Set([...prev].filter((id) => held.has(id)));
      return next.size === prev.size ? prev : next;
    });
  }, [wallet, ready]);

  // the sell order
  const order = list.filter((c) => selected.has(c.id));
  const orderIds = order.map((c) => BigInt(c.id));
  const n = order.length;
  const quote = useSellQuote(orderIds, now);
  const ethFills = quote.data && order.every((c) => quote.data!.fills[c.id.toString()] !== undefined) ? quote.data.fills : undefined;
  const balFills = useMemo(() => {
    if (!balanceBid || !snap) return undefined;
    const f = balanceFills(snap, order.map((c) => c.score));
    return Object.fromEntries(order.map((c, i) => [c.id.toString(), f[i]])) as Record<string, bigint>;
  }, [balanceBid, snap, order.map((c) => c.id).join(",")]); // eslint-disable-line react-hooks/exhaustive-deps
  const fills = isBal ? balFills : ethFills;
  const fillOf = (c: Credit) => fills?.[c.id.toString()];

  const total = n === 0 ? undefined : isBal ? (balFills ? order.reduce((t, c) => t + (balFills[c.id.toString()] ?? 0n), 0n) : undefined) : ethFills && quote.data!.amount;
  const sum = order.reduce((t, c) => t + (isBal ? balanceForId(c) : bidForId(c)), 0n);
  const drop = total !== undefined && sum > total ? sum - total : 0n;
  const dropPct = sum > 0n && total !== undefined ? ((Number(drop) / Number(sum)) * 100).toFixed(1) : "0.0";

  const unit = isBal ? BALANCE_SYMBOL : "ETH";
  const num = (v: bigint, dp = 4) => (isBal ? balanceAmount(v, bal, 2) ?? "…" : eth(v, dp));
  const withUnit = (v: bigint | undefined) => (v === undefined ? "…" : `${num(v)} ${unit}`);
  const usdOf = (wei: bigint | undefined) => (wei !== undefined && ethUsd != null ? `≈ ${usd(Number(formatUnits(wei, 18)) * ethUsd)}` : undefined);
  const heroUsd = total === undefined ? undefined : usdOf(isBal ? balanceEth(total) : total);

  const toggleOne = (id: number) =>
    setSelected((prev) => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  // shift-click selects every credit between the last clicked one and this one, in list order
  const click = (id: number) => (e: MouseEvent | KeyboardEvent) => {
    const a = anchor === undefined ? -1 : list.findIndex((c) => c.id === anchor);
    const b = list.findIndex((c) => c.id === id);
    if (e.shiftKey && a >= 0 && b >= 0) {
      const [lo, hi] = a < b ? [a, b] : [b, a];
      setSelected((prev) => new Set([...prev, ...list.slice(lo, hi + 1).map((c) => c.id)]));
    } else toggleOne(id);
    setAnchor(id);
  };
  const keys = (id: number) => (e: KeyboardEvent) => {
    if (e.key !== " " && e.key !== "Enter") return;
    e.preventDefault();
    click(id)(e);
  };
  const pick = (cs: Credit[]) => () => setSelected(new Set(cs.map((c) => c.id)));
  const allOn = n > 0 && n === list.length;

  const quick: { label: string; on: () => void }[] = many
    ? [
        { label: "all", on: pick(list) },
        { label: "top 10 offers", on: pick([...list].sort((a, b) => (a.score === b.score ? a.id - b.id : a.score < b.score ? 1 : -1)).slice(0, 10)) },
        { label: "clear", on: pick([]) },
      ]
    : [{ label: allOn ? "clear" : "select all", on: pick(allOn ? [] : list) }];

  // the collection approval to the Core, once
  async function approve(write: Write) {
    if (!address || !client) return;
    const ok = await client.readContract({ address: credits, abi: creditsAbi, functionName: "isApprovedForAll", args: [address, core!] });
    if (!ok) await write({ address: credits, abi: creditsAbi, functionName: "setApprovalForAll", args: [core, true] });
  }

  if (!engineDeployed) return <NotDeployed />;

  const meta = snap
    ? `bid ${eth(bid, 5)} ETH / 100 pts · pot ${eth(pot, 2)} ETH · covers ~${commas(potPoints(pot, bid))} pts`
    : "reading the engine…";
  const plural = (k: number) => `${k} credit${k === 1 ? "" : "s"}`;
  const spendCap = snap && snap.settings.spendCapBps < 10000 && !isBal;
  const shownFills = order.slice(0, many ? FILLS_TABLE : FILLS_CARDS);
  const rows = many ? list.slice(page * ROWS, (page + 1) * ROWS) : list;

  const check = (on: boolean, partial = false, lg = false) => (
    <span className={`sell-chk${lg ? " lg" : ""}${on || partial ? " on" : ""}`} aria-hidden>
      {on ? "✓" : partial ? "–" : ""}
    </span>
  );
  const batchCell = (c: Credit, on: boolean) => (on ? withUnit(fillOf(c)) : "—");

  const card = (c: Credit) => {
    const on = selected.has(c.id);
    const offer = bidForId(c);
    return (
      <div key={c.id} className={`sell-card${on ? " on" : ""}`} role="checkbox" aria-checked={on} aria-label={`credit #${c.id}`} tabIndex={0} onClick={click(c.id)} onKeyDown={keys(c.id)}>
        <div className="sell-card-art">
          <ArtFrame>
            <CreditTile id={c.id} />
          </ArtFrame>
          {check(on, false, true)}
        </div>
        <div className="sell-card-body">
          <div className="sell-card-cap">engine offers</div>
          <div className="sell-card-offer">
            <b>{eth(offer)}</b>
            <small>ETH</small>
            <span>{usdOf(offer)}</span>
          </div>
          <div className="sell-card-row muted">
            <span>#{c.id}</span>
            <span>rating {rating(c.score)}</span>
          </div>
          <div className="sell-card-row sell-card-batch">
            <span className="quiet">{on ? "in this batch" : "not selected"}</span>
            <span className={on ? undefined : "off"}>{batchCell(c, on)}</span>
          </div>
          {balanceBid && (
            <div className="sell-card-row">
              <span className="quiet">or in {BALANCE_SYMBOL}</span>
              <span>{balanceAmount(balanceForId(c), bal, 2) ?? "…"}</span>
            </div>
          )}
        </div>
      </div>
    );
  };

  const table = (
    <div className={`sell-table${balanceBid ? "" : " no-bal"}`}>
      <div className="sell-row sell-row-head">
        <span
          className="sell-row-chk"
          role="checkbox"
          aria-checked={allOn ? true : n > 0 ? "mixed" : false}
          aria-label="select all"
          tabIndex={0}
          onClick={pick(allOn ? [] : list)}
          onKeyDown={(e) => (e.key === " " || e.key === "Enter") && (e.preventDefault(), pick(allOn ? [] : list)())}
        >
          {check(allOn, n > 0)}
        </span>
        <span />
        <span>credit</span>
        <span className="num">rating</span>
        <span className="num">offer alone</span>
        <span className="num">in this batch</span>
        {balanceBid && <span className="num">or in {BALANCE_SYMBOL}</span>}
      </div>
      {rows.map((c) => {
        const on = selected.has(c.id);
        return (
          <div key={c.id} className={`sell-row${on ? " on" : ""}`} role="checkbox" aria-checked={on} aria-label={`credit #${c.id}`} tabIndex={0} onClick={click(c.id)} onKeyDown={keys(c.id)}>
            <span className="sell-row-chk">{check(on)}</span>
            <span className="sell-thumb">
              <CreditTile id={c.id} />
            </span>
            <span className="sell-row-id">#{c.id}</span>
            <span className="num">{rating(c.score)}</span>
            <span className="num sell-row-offer">
              {eth(bidForId(c))} <small>ETH</small>
            </span>
            <span className={`num${on ? "" : " off"}`}>{batchCell(c, on)}</span>
            {balanceBid && <span className="num muted">{balanceAmount(balanceForId(c), bal, 2) ?? "…"}</span>}
          </div>
        );
      })}
      <div className="sell-table-foot">
        <span>
          showing {rows.length} of {list.length} · shift-click to select a range
        </span>
        <span className="sell-pager">
          <button onClick={() => setPage((p) => Math.max(0, p - 1))} disabled={page === 0}>
            ← prev
          </button>
          <span>
            {page + 1} / {pages}
          </span>
          <button onClick={() => setPage((p) => Math.min(pages - 1, p + 1))} disabled={page >= pages - 1}>
            next →
          </button>
        </span>
      </div>
    </div>
  );

  const examples = [100, 400, 800];

  return (
    <>
      <PageHead title="sell to the engine" ink="k" meta={meta}>
        <span className="sell-refresh">offers refresh every 5s</span>
      </PageHead>
      <div className="split sell">
        <div className="split-main sell-main">
          {isConnected && ready && list.length > 0 && (
            <div className="sell-bar">
              <div className="sell-bar-title">
                <b>your credits ({list.length})</b>
                <span className="muted">{n} selected</span>
              </div>
              <div className="sell-quick">
                {quick.map((q) => (
                  <button key={q.label} onClick={q.on}>
                    {q.label}
                  </button>
                ))}
                {many && (
                  <label className="sort">
                    sort:{" "}
                    <select
                      value={sort}
                      onChange={(e) => {
                        setSort(e.target.value as Sort);
                        setPage(0);
                      }}
                    >
                      <option value="offer">offer high → low</option>
                      <option value="rating">rating low → high</option>
                      <option value="id">id</option>
                    </select>
                  </label>
                )}
              </div>
            </div>
          )}

          <div className="sell-how">
            <div>
              <span className="muted">how offers work</span>
              <p>each credit&apos;s offer is the bid scaled by its rating. rating 100 = {snap ? eth(bid, 5) : "—"} ETH.</p>
            </div>
            {examples.map((r, i) => (
              <div key={i}>
                <span className="muted">rating {commas(r)}</span>
                <b>
                  {snap ? eth((bid * BigInt(r)) / 100n) : "—"} <small>ETH</small>
                </b>
              </div>
            ))}
          </div>

          {!isConnected ? (
            <div className="sell-empty">
              <p>connect a wallet to see your credits.</p>
              <button className="btn-fill" onClick={openConnectModal}>
                connect wallet
              </button>
            </div>
          ) : !ready ? (
            <div className="sell-empty">
              <p className="muted">reading your credits…</p>
            </div>
          ) : list.length === 0 ? (
            <div className="sell-empty">
              <p>you don&apos;t hold any credits.</p>
              <Link href="/credits" className="ulink">
                see the credits the engine holds →
              </Link>
            </div>
          ) : many ? (
            table
          ) : (
            <div className="sell-cards">{list.map(card)}</div>
          )}
        </div>

        <aside className="side sell-rail">
          <div className="sell-rail-in">
            <div className="sell-rail-head">
              <h2>your offer</h2>
              {balanceBid && (
                <div className="seg" role="group" aria-label="currency">
                  <button className={isBal ? "" : "on"} onClick={() => setCur("eth")}>
                    ETH
                  </button>
                  <button className={isBal ? "on" : ""} onClick={() => setCur("bal")}>
                    {BALANCE_SYMBOL}
                  </button>
                </div>
              )}
            </div>

            <div className="sell-hero">
              <span className="muted">you receive for {plural(n)}</span>
              <div>
                <b>{n === 0 ? "—" : total === undefined ? "…" : num(total)}</b>
                <span>{unit}</span>
              </div>
              <span className="muted">{heroUsd ?? "—"}</span>
            </div>

            <div className="sell-break">
              <div>
                <span className="muted">offers added up</span>
                <span>{n ? `${num(sum)} ${unit}` : "—"}</span>
              </div>
              <div>
                <span className="muted">batch drop ({n ? dropPct : "0.0"}%)</span>
                <span>{n ? (total === undefined ? "…" : `−${num(drop)} ${unit}`) : "—"}</span>
              </div>
              <div className="sell-break-total">
                <span>you receive</span>
                <span>{n ? withUnit(total) : "—"}</span>
              </div>
              <div>
                <span className="muted">minimum, reverts below</span>
                <span className="muted">{n ? withUnit(total === undefined ? undefined : (total * MIN_OUT_BPS) / 10000n) : "—"}</span>
              </div>
            </div>

            <p className="sell-copy">
              {isBal
                ? `the ${BALANCE_SYMBOL} bid is a posted price, ${snap ? Number(snap.balanceRate) / 100 : "…"}% of par per point: it does not drop after a credit and does not climb while idle, so a batch pays the offers added up.`
                : "the bid drops a little after each credit the engine buys. selling several in one transaction, later credits fill at the lower bid, so the batch pays less than the offers added up."}
              {snap && snap.settings.buyToArtistBps > 0
                ? ` the engine pays the artist a ${snap.settings.buyToArtistBps / 100}% royalty on top of every purchase, and it comes on top of what you receive.${isBal ? " On the balance route, a payment the token cannot deliver in the sale transaction is recorded for the artist to claim." : ""}`
                : ""}
            </p>

            {n > 0 && (
              <div className="sell-fills">
                <div className="sell-fill sell-fill-head">
                  <span>#</span>
                  <span>credit</span>
                  <span>fills at</span>
                </div>
                {shownFills.map((c, i) => (
                  <div key={c.id} className="sell-fill">
                    <span className="quiet">{i + 1}</span>
                    <span>
                      #{c.id} <span className="quiet">· r{rating(c.score)}</span>
                    </span>
                    <span>{fillOf(c) === undefined ? "…" : num(fillOf(c)!)}</span>
                  </div>
                ))}
                {n > shownFills.length && <div className="sell-fill-more">+ {n - shownFills.length} more</div>}
              </div>
            )}

            {spendCap && (
              <p className="sell-copy">
                eth purchase cap: {snap!.settings.spendCapBps / 100}% of the bucket&apos;s opening pot per {snap!.settings.bucketSeconds} seconds. the eth quote does not
                reserve purchase budget. an eth sale can be blocked until the next budget bucket, even when the pot has funds.
              </p>
            )}

            <div className="sell-cta">
              {n === 0 || !snap ? (
                <button className="action" disabled>
                  select credits to sell
                </button>
              ) : snap.paused ? (
                <button className="action" disabled>
                  engine paused
                </button>
              ) : balanceQuoteMissing ? (
                <button className="action" disabled>
                  balance quote unavailable
                </button>
              ) : isBal ? (
                <Act
                  label={`approve & sell ${plural(n)} for ${BALANCE_SYMBOL}`}
                  steps={async (write) => {
                    const ids = orderIds;
                    await approve(write);
                    // minOut replays the per-credit drop from the snapshot over the sell order, like the eth quote, so an
                    // ordinary batch does not trip Slippage
                    const expected = balanceQuote(snap, order.map((c) => c.score));
                    await write({ address: core, abi: coreAbi, functionName: "sellForBalance", args: [ids, (expected * MIN_OUT_BPS) / 10000n, snap.balanceToken] });
                    setSelected(new Set());
                  }}
                />
              ) : (
                <Act
                  label={`approve & sell ${plural(n)} for ETH`}
                  steps={async (write) => {
                    const ids = orderIds;
                    await approve(write);
                    // each credit pays its own bid (ethRate * score / 1,000,000) and the bid drops per credit sold in one
                    // call: minOut is a share of the whole batch's total, replayed from the contract's rate loop
                    const expected = (await sellQuote(client!, ids, now)).amount;
                    await write({ address: core, abi: coreAbi, functionName: "sellForEth", args: [ids, (expected * MIN_OUT_BPS) / 10000n] });
                    setSelected(new Set());
                  }}
                />
              )}
              <p className="caption">first sale asks once to approve the collection to the engine, then sells in one transaction.</p>
            </div>
          </div>
        </aside>
      </div>
    </>
  );
}
