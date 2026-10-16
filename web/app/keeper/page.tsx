"use client";

import { useReadContract } from "wagmi";
import { Act } from "@/components/Act";
import { NotDeployed } from "@/components/NotDeployed";
import { PageHead } from "@/components/Shell";
import { coreAbi } from "@/lib/abis";
import { core, engineDeployed } from "@/lib/config";
import { useBalanceToken, useHead, useSnapshot } from "@/lib/live";
import { useStats } from "@/lib/data";
import { useEngine, useIxMode } from "@/lib/indexer";
import { BALANCE_SYMBOL, commas, eth, formatBalance, shortAddr } from "@/lib/format";

// The permissionless engine actions: the pots, the book and the next buyback (anyone may call them), and the push
// payouts. The artist and the payee are paid by push on every sale and book, so there is no claim here.
export default function KeeperPage() {
  const { data: s } = useSnapshot();
  const bal = useBalanceToken();
  const { data: stats } = useStats();
  const head = useHead().data?.n;
  // lastBuybackBlock from the indexer; the Core view in chain mode
  const mode = useIxMode();
  const engineQ = useEngine();
  const { data: lastLive } = useReadContract({
    address: core,
    abi: coreAbi,
    functionName: "lastBuybackBlock",
    query: { enabled: engineDeployed && mode === "chain", refetchInterval: 15000 },
  });
  const last = mode === "chain" ? lastLive : engineQ.data?.lastBuybackBlock ?? undefined;
  if (!engineDeployed) return <NotDeployed />;
  if (!s) return <main className="page detail" />;

  const row = (k: string, v: string) => (
    <div className="r" key={k}>
      <span>{k}</span>
      <b>{v}</b>
    </div>
  );
  const delay = BigInt(s.settings.buybackDelay);
  const slice = s.ethToBuyback < s.settings.buybackSlice ? s.ethToBuyback : s.settings.buybackSlice;
  const open = last != null ? last + delay : undefined; // first block a buyback is accepted
  const wait = open != null && head != null && head < open ? open - head : 0n;
  const status =
    s.ethToBuyback === 0n ? "the buyback pot is empty" : wait > 0n ? `in ${commas(Number(wait))} blocks` : "open now";

  return (
    <>
      <PageHead title="keeper" ink="k" meta={s.retired ? "retired" : s.paused ? "sales paused" : "running"} />
      <main className="page detail">
        <div className="keeper">
          <section>
            <h2>pots</h2>
            <div className="quote">
              {row("bid, reference credit", `${eth(s.ethRate)} eth`)}
              {row("pot", `${eth(s.ethPot)} eth`)}
              {row("to buyback", `${eth(s.ethToBuyback)} eth`)}
              {row("redeem burn pot", `${eth(s.ethRedeemBurn)} eth`)}
              {s.balanceOn && row(`${BALANCE_SYMBOL} in the module`, s.balanceAvailable === undefined ? "unavailable" : formatBalance(s.balanceAvailable, bal))}
              {s.balanceOn && row(`${BALANCE_SYMBOL} bid, % of par`, s.balanceAvailable === undefined ? "unavailable" : `${(Number(s.balanceRate) / 100).toFixed(1)}%`)}
            </div>
          </section>

          <section>
            <h2>book fees</h2>
            <p className="panel-note">counts the fees the hook sent into the pot.</p>
            <div className="actions">
              <Act label="book fees" steps={async (w) => void (await w({ address: core, abi: coreAbi, functionName: "book" }))} />
            </div>
          </section>

          <section>
            <h2>buyback</h2>
            <div className="quote">
              {row("next buyback", status)}
              {row("delay", `${commas(s.settings.buybackDelay)} blocks`)}
              {row("slice", `${eth(slice)} of ${eth(s.settings.buybackSlice)} eth`)}
            </div>
            <p className="panel-note">swaps a slice of the buyback pot for coin and burns it.</p>
            <div className="actions">
              <Act
                label="buyback"
                disabled={s.ethToBuyback === 0n || wait > 0n}
                steps={async (w) => void (await w({ address: core, abi: coreAbi, functionName: "buyback" }))}
              />
            </div>
          </section>

          <section>
            <h2>payouts</h2>
            <p className="panel-note">the artist and the payee are paid by push on every sale and book, so there is no claim.</p>
            <div className="quote">
              {row("artist", shortAddr(s.artist))}
              {row("artist received", stats ? `${stats.artistReceived.toFixed(4)} eth` : "—")}
              {row("payee", shortAddr(s.payee))}
              {row("payee received", stats ? `${stats.payeeReceived.toFixed(4)} eth` : "—")}
            </div>
          </section>
        </div>
      </main>
    </>
  );
}
