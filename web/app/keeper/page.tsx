"use client";

import { useReadContract } from "wagmi";
import { Act } from "@/components/Act";
import { NotDeployed } from "@/components/NotDeployed";
import { controllerAbi, coreAbi } from "@/lib/abis";
import { core, engineDeployed } from "@/lib/config";
import { useHead, useSnapshot } from "@/lib/live";
import { BALANCE_SYMBOL } from "@/lib/events";
import { commas, eth } from "@/lib/format";

// The permissionless engine actions: the pots, the next buyback and the claims.
// Anyone may call all four.
export default function KeeperPage() {
  const { data: s } = useSnapshot();
  const head = useHead().data?.n;
  const { data: last } = useReadContract({
    address: core,
    abi: coreAbi,
    functionName: "lastBuybackBlock",
    query: { enabled: engineDeployed, refetchInterval: 15000 },
  });
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
    <main className="page detail">
      <div className="page-head">
        <h1>keeper</h1>
        <span className="muted">{s.retired ? "retired" : s.paused ? "sales paused" : "running"}</span>
      </div>

      <div className="keeper">
        <section>
          <h2>pots</h2>
          <div className="quote">
            {row("bid, average credit", `${eth(s.ethRate)} eth`)}
            {row("pot", `${eth(s.ethPot)} eth`)}
            {row("to buyback", `${eth(s.ethToBuyback)} eth`)}
            {row("redeem burn reserve", `${eth(s.ethRedeemBurn)} eth`)}
            {row("payee owed", `${eth(s.payeeOwed)} eth`)}
            {row("royalty owed", `${eth(s.royaltyOwed)} eth`)}
            {s.balanceOn && row(`${BALANCE_SYMBOL} pot`, eth(s.balancePot))}
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
          <h2>claims</h2>
          <p className="panel-note">each claim pays its recipient.</p>
          <div className="actions">
            <Act
              label="claim payee"
              disabled={s.payeeOwed === 0n}
              steps={async (w) => void (await w({ address: core, abi: coreAbi, functionName: "claimPayee" }))}
            />
            <Act
              label="claim royalty"
              disabled={s.royaltyOwed === 0n}
              steps={async (w) => void (await w({ address: s.controller, abi: controllerAbi, functionName: "claimRoyalty" }))}
            />
          </div>
        </section>
      </div>
    </main>
  );
}
