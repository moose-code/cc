"use client";

import type { ReactNode } from "react";

// The "Burn $CC for BALANCE" panel of /exchange: presentation only. Every figure arrives formatted; the page owns the
// reads, the quote arithmetic (web/lib/exchange.ts claimQuote) and the consent flow (redeemClaim).

export type ClaimReceipt = { burned: string; received: string; hash: string };

export type ClaimPanelProps = {
  // when set, the panel shows this notice alone: the Core's module is not a phase 2 treasury
  notice?: string;
  treasury: string;
  balanceToken: string;
  balanceSymbol: string;
  policy: string;
  policyVersion: string;
  policyIsProRata: boolean;
  claimReserve: string;
  freeWorking: string;
  ccSupply: string;
  ccSymbol: string;
  contributionRate: string;
  feeRate: string;
  backingPerCc: string;
  walletCc: string;
  connected: boolean;
  amount: string;
  amountBps: number;
  onAmountChange: (value: number) => void;
  quoted: string;
  minimum: string;
  epoch: string;
  liveMismatch: boolean;
  slippageBps: number;
  onSlippageChange: (bps: number) => void;
  busy: boolean;
  status?: string;
  error?: string;
  receipt?: ClaimReceipt;
  onReset: () => void;
  action: ReactNode;
};

export function ClaimPanel(p: ClaimPanelProps) {
  if (p.notice) {
    return (
      <section className="claim-panel claim-panel-notice" aria-labelledby="claim-title">
        <h2 id="claim-title">Burn $CC for $BALANCE</h2>
        <p role="status">{p.notice}</p>
      </section>
    );
  }
  return (
    <section className="claim-panel" aria-labelledby="claim-title" aria-busy={p.busy}>
      <div className="claim-facts">
        <h2 id="claim-title">Burn $CC for $BALANCE</h2>
        <p className="claim-lede">
          A burn of $CC pays a proportional share of the treasury&apos;s claim reserve, the backing the engine&apos;s owner manages.
          It is not an automatic market purchase: the owner can add backing, move backing to working funds while redemption
          is paused, and replace the redemption policy, and each such change invalidates pending quotes. The 90 percent
          Credit payout above can be lowered by price protection; this burn pays the share quoted below or reverts.
        </p>
        <dl className="claim-grid">
          <div><dt>treasury</dt><dd><code>{p.treasury}</code></dd></div>
          <div><dt>BALANCE token</dt><dd><code>{p.balanceToken}</code> {p.balanceSymbol}</dd></div>
          <div><dt>redemption policy</dt><dd><code>{p.policy}</code> {p.policyVersion}{p.policyIsProRata ? "" : " (not pro-rata-v1)"}</dd></div>
          <div><dt>claim reserve</dt><dd>{p.claimReserve} {p.balanceSymbol}</dd></div>
          <div><dt>free working funds</dt><dd>{p.freeWorking} {p.balanceSymbol}</dd></div>
          <div><dt>{p.ccSymbol} total supply</dt><dd>{p.ccSupply}</dd></div>
          <div><dt>contribution rate</dt><dd>{p.contributionRate} of each conversion</dd></div>
          <div><dt>redemption fee</dt><dd>{p.feeRate}</dd></div>
          <div><dt>redeemable share per {p.ccSymbol} (claim reserve over the total supply)</dt><dd>{p.backingPerCc} {p.balanceSymbol}</dd></div>
          <div><dt>your {p.ccSymbol}</dt><dd>{p.connected ? p.walletCc : "connect your wallet"}</dd></div>
        </dl>
      </div>
      <div className="claim-form">
        {p.receipt ? (
          <div className="claim-success" role="status">
            <p className="claim-success-title">burn complete</p>
            <p className="claim-success-value">{p.receipt.received}</p>
            <p className="claim-success-currency">{p.balanceSymbol} received</p>
            <dl className="claim-receipt">
              <div><dt>{p.ccSymbol} burned</dt><dd>{p.receipt.burned}</dd></div>
              <div><dt>transaction</dt><dd><code title={p.receipt.hash}>{shortHash(p.receipt.hash)}</code></dd></div>
            </dl>
            <button type="button" onClick={p.onReset}>burn more {p.ccSymbol}</button>
          </div>
        ) : (
          <>
            <div className="claim-amount">
              <label htmlFor="claim-amount">{p.ccSymbol} to burn</label>
              <output className="claim-amount-value" htmlFor="claim-amount">{p.amount} {p.ccSymbol}</output>
              <input
                id="claim-amount"
                type="range"
                min="0"
                max="10000"
                step="1"
                value={p.amountBps}
                disabled={p.busy || !p.connected}
                aria-valuetext={`${p.amount} ${p.ccSymbol}`}
                onChange={(e) => p.onAmountChange(Number(e.target.value))}
              />
              <span className="claim-range-labels" aria-hidden="true"><span>0</span><span>100%</span></span>
            </div>
            <dl className="claim-quote">
              <div><dt>you receive</dt><dd>{p.quoted} {p.balanceSymbol}</dd></div>
              <div><dt>minimum you receive</dt><dd>{p.minimum} {p.balanceSymbol}</dd></div>
              <div><dt>terms version (epoch)</dt><dd>{p.epoch}</dd></div>
            </dl>
            {p.liveMismatch && <p className="claim-note" role="status">The treasury&apos;s quote differs from the pro-rata arithmetic; the treasury&apos;s quote is shown and used.</p>}
            <div className="claim-slippage">
              <span id="claim-slippage-label">slippage tolerance</span>
              <div role="group" aria-labelledby="claim-slippage-label">
                {[0, 50, 100].map((bps) => (
                  <button key={bps} type="button" aria-pressed={p.slippageBps === bps} disabled={p.busy} onClick={() => p.onSlippageChange(bps)}>{bps / 100}%</button>
                ))}
              </div>
            </div>
            <p className="claim-explanation">
              The terms epoch is the treasury&apos;s version number for redemption settings, not a date or time period. Your quote pins
              that version when you confirm, so the transaction reverts if the owner changes the terms. It also expires after 20 minutes
              and reverts if the treasury pays under your minimum or redemption closes.
            </p>
            {p.status && <p className="claim-status" role="status">{p.status}</p>}
            {p.error && <p className="claim-error" role="alert">{p.error}</p>}
            {p.action}
            <p className="claim-footnote">The first burn asks once to approve the treasury for exactly the amount entered.</p>
          </>
        )}
      </div>
    </section>
  );
}

function shortHash(hash: string): string {
  return hash.length > 20 ? `${hash.slice(0, 10)}…${hash.slice(-8)}` : hash;
}
