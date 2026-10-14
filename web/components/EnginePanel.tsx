"use client";

import { controllerAbi, coreAbi } from "@/lib/abis";
import { core } from "@/lib/config";
import { useSnapshot } from "@/lib/live";
import { eth } from "@/lib/format";
import { Act } from "./Act";

// Side panel of the home page: the pots and the permissionless engine actions.
export function EnginePanel() {
  const { data: s } = useSnapshot();
  if (!s) return <aside className="side" />;
  const row = (k: string, v: string) => (
    <div className="r" key={k}>
      <span>{k}</span>
      <b>{v}</b>
    </div>
  );
  return (
    <aside className="side">
      <div className="price-row">
        <span className="pair">engine</span>
        <span className="muted">{s.retired ? "retired" : s.paused ? "sales paused" : "running"}</span>
      </div>
      <div className="quote">
        {row("bid per credit", `${eth(s.ethRate)} eth`)}
        {row("pot", `${eth(s.ethPot)} eth`)}
        {row("to buyback", `${eth(s.ethToBuyback)} eth`)}
        {row("redeem burn reserve", `${eth(s.ethRedeemBurn)} eth`)}
        {row("payee owed", `${eth(s.payeeOwed)} eth`)}
        {row("royalty owed", `${eth(s.royaltyOwed)} eth`)}
        {s.balanceOn && row("balance pot", `${eth(s.balancePot)}`)}
      </div>
      <div className="actions">
        <Act label="book fees" steps={async (w) => void (await w({ address: core, abi: coreAbi, functionName: "book" }))} />
        <Act
          label="buyback"
          disabled={s.ethToBuyback === 0n}
          steps={async (w) => void (await w({ address: core, abi: coreAbi, functionName: "buyback" }))}
        />
        <Act
          label="claim royalty"
          disabled={s.royaltyOwed === 0n}
          steps={async (w) => void (await w({ address: s.controller, abi: controllerAbi, functionName: "claimRoyalty" }))}
        />
      </div>
      <p className="panel-note">
        book counts the fees the hook sent into the pot. buyback swaps a slice of the buyback pot for coin and burns it. claim royalty pays the
        royalty recipient. anyone may call all three.
      </p>
    </aside>
  );
}
