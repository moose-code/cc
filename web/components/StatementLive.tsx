"use client";

import { useState } from "react";
import Link from "next/link";
import { useAccount, useReadContract } from "wagmi";
import { formatUnits } from "viem";
import { StatementTile, CreditTile } from "./Tiles";
import { StatusBadge } from "./Cards";
import { HistRow } from "./History";
import { NotDeployed } from "./NotDeployed";
import { Act } from "./Act";
import { core, engineDeployed } from "@/lib/config";
import { STATEMENT_SIZE, useBlockTs, useScan } from "@/lib/engine";
import { formatBalance } from "@/lib/events";
import { useTokenMeta } from "@/lib/art";
import { controllerAbi, coreAbi, erc20Abi } from "@/lib/abis";
import { type HeldStatement, type Snapshot, useNow, useSnapshot, useStatements } from "@/lib/live";
import { agoLabel, commas, eth, signedPct } from "@/lib/format";

const BUFFER_BPS = 100n; // value above the gross price; the controller refunds the excess
const FORMATS = [0, 1, 2, 3, 4, 5, 6, 7];

// Statement detail. A statement the Core holds reads from the multicall
// (useStatements): the gross price, its engine price and royalty, the reference
// and the floor state, with buy, restyle and redeem. History comes from the
// Core and controller logs: Composed (credits, format, who, default or chosen),
// HeldFormatSet, StatementSoldTo, AnchorMoved and StatementRedeemed.
export function LiveStatement({ id }: { id: number }) {
  const { data: snap } = useSnapshot();
  const { data: held } = useStatements();
  const { data: scan } = useScan();
  const { data: meta } = useTokenMeta("statement", id);
  const now = useNow();
  const s = held.find((x) => x.sid === id);
  const rec = scan.statements[id];
  const composed = rec?.composed;
  const sale = rec?.sold;
  const redeemed = rec?.redeemed;
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
            {s ? <StatusBadge status="listed" /> : sale ? <StatusBadge status="sold" /> : redeemed ? <StatusBadge status="redeemed" /> : known ? <StatusBadge status="not held" /> : null}
          </div>
          {!snap ? (
            <p className="muted">loading…</p>
          ) : (
            <>
              {s && <StatementActions s={s} snap={snap} />}
              {!known && <p className="muted">no record of this statement on the engine.</p>}
              {known && (
                <div className="facts">
                  {cost != null && <Fact k="cost" v={`${eth(cost)} eth`} />}
                  <Fact k="credits" v={String(composed?.ids.length ?? STATEMENT_SIZE)} />
                  {score != null && <Fact k="credit score" v={commas(Number(score))} />}
                  {composed && <Fact k="format" v={`${formatName ?? "—"} (${rec?.restyled.at(-1)?.format ?? composed.format})`} />}
                  {composed && (
                    <Fact
                      k="composed"
                      v={`${composedTs != null ? agoLabel(now - composedTs) : "—"} · ${
                        composed.mode === "chosen" ? "chosen compose" : composed.mode === "default" ? "default compose" : "compose"
                      }`}
                    />
                  )}
                  {s && snap.balanceOn && <Fact k="rating value" v={`${eth(s.value)} eth`} />}
                  {s && snap.balanceOn && <Fact k="redeemable" v={snap.settings.redeemOn && s.atFloor ? "yes" : "no"} />}
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
                        note={composed.mode ? `${composed.mode} compose, format ${composed.format}` : `format ${composed.format}`}
                        block={composed.block}
                        tx={composed.tx}
                        addr={composed.caller}
                      />
                    )}
                    {rec?.restyled.map((r) => (
                      <HistRow key={r.tx} label="restyled" value={`format ${r.format}`} block={r.block} tx={r.tx} addr={r.caller} />
                    ))}
                    {s && (
                      <HistRow
                        label="for sale"
                        value={`${eth(s.gross)} eth now`}
                        note={cost ? `${signedPct(overCost(s.price, cost))} engine price over cost` : undefined}
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
                    {redeemed && <HistRow label="redeemed" value="by redemption" note={`received ${formatBalance(redeemed.received, scan.balanceToken)}`} block={redeemed.block} tx={redeemed.tx} />}
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

// buy at the gross price, restyle, and redeem of a statement the Core holds
function StatementActions({ s, snap }: { s: HeldStatement; snap: Snapshot }) {
  const { address } = useAccount();
  const [format, setFormat] = useState(0);
  const royalty = s.gross - s.price;
  const { data: ccBal } = useReadContract({
    address: snap.coin,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address && snap.minCcToChoose > 0n) },
  });
  const ccOk = snap.minCcToChoose === 0n || (ccBal ?? 0n) >= snap.minCcToChoose;
  const redeemable = snap.balanceOn && snap.settings.redeemOn && s.atFloor;

  return (
    <div className="buybox">
      <div className="buybox-price">
        <span className="muted">price</span>
        <span className="big">{eth(s.gross)} eth</span>
      </div>
      <div className="price-ends muted">
        <span>
          engine {eth(s.price)} + royalty {eth(royalty)}
        </span>
        <span>{s.atFloor ? "at floor" : "falling"}</span>
      </div>
      <div className="price-ends muted">
        <span>reference {eth(s.reference)}</span>
      </div>
      <Act
        label={snap.paused ? "sales paused" : "buy statement"}
        disabled={snap.paused}
        steps={async (write) =>
          void (await write({
            address: snap.controller,
            abi: controllerAbi,
            functionName: "buy",
            args: [BigInt(s.sid)],
            value: s.gross + (s.gross * BUFFER_BPS) / 10000n,
          }))
        }
      />
      <p className="muted small">
        the price falls toward its floor and rises if the engine bid peak rises. the excess of your payment is refunded.
      </p>

      <div className="restyle">
        <label className="muted">
          format{" "}
          <select value={format} onChange={(e) => setFormat(Number(e.target.value))}>
            {FORMATS.map((f) => (
              <option key={f} value={f}>
                {f}
              </option>
            ))}
          </select>
        </label>
        <Act
          label="restyle"
          disabled={!ccOk}
          title={!ccOk ? "coin balance below the minimum" : undefined}
          steps={async (write) => void (await write({ address: core, abi: coreAbi, functionName: "setHeldFormat", args: [BigInt(s.sid), format] }))}
        />
        <p className="muted small">
          restyle sets the format of this held statement. it needs at least {Number(formatUnits(snap.minCcToChoose, 18)).toLocaleString("en-US")} cc in the
          account.
        </p>
      </div>

      {snap.balanceOn && (
        <div className="restyle">
          <Act
            label="redeem statement"
            disabled={!redeemable}
            title={!snap.settings.redeemOn ? "redemption is off" : !s.atFloor ? "the price has not reached its floor" : undefined}
            steps={async (write) => void (await write({ address: core, abi: coreAbi, functionName: "redeemStatement", args: [BigInt(s.sid)] }))}
          />
          <p className="muted small">redeem hands the statement to the balance module for balance token by rating, once the price is at its floor.</p>
        </div>
      )}
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
