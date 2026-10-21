"use client";

import type { ReactNode } from "react";

// The "Burn $CC for BALANCE" panel of /exchange: presentation only. Every figure arrives formatted; the page owns the
// reads, the view state (web/lib/exchange.ts claimView), the quote arithmetic (claimQuote) and the consent flow
// (redeemClaim). While the treasury's CC redemption switch is off (`redemptionOpen` false) the form side is the
// accumulating view: the reserve, the live contribution rate, the available working funds and the status, with no
// transaction button; the preview of the entered amount is labelled as the current policy's answer, not a quote.

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
  // ccRedemptionEnabled: false shows the accumulating view in place of the form
  redemptionOpen: boolean;
  claimReserve: string;
  freeWorking: string;
  // the treasury's available(): what the Core's bid may pay now
  available: string;
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
  // the current policy's answer for the entered amount while redemption is off
  preview: string;
  liveMismatch: boolean;
  slippageBps: number;
  onSlippageChange: (bps: number) => void;
  busy: boolean;
  status?: string;
  error?: string;
  receipt?: ClaimReceipt;
  onReset: () => void;
  // the transaction button; none while redemption is off
  action?: ReactNode;
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
          is paused, and replace the redemption policy, and each such change invalidates pending quotes. The posted
          Credit payout above can be lowered by price protection; this burn pays the share quoted below or reverts.
        </p>
        <dl className="claim-grid">
          <div><dt>treasury</dt><dd><code>{p.treasury}</code></dd></div>
          <div><dt>BALANCE token</dt><dd><code>{p.balanceToken}</code> {p.balanceSymbol}</dd></div>
          <div><dt>redemption policy</dt><dd><code>{p.policy}</code> {p.policyVersion}{p.policyIsProRata ? "" : " (not pro-rata-v1)"}</dd></div>
          <div><dt>claim reserve{p.redemptionOpen ? "" : " (earmarked, not redeemable yet)"}</dt><dd>{p.claimReserve} {p.balanceSymbol}</dd></div>
          <div><dt>free working funds</dt><dd>{p.freeWorking} {p.balanceSymbol}</dd></div>
          <div><dt>available working funds</dt><dd>{p.available} {p.balanceSymbol}</dd></div>
          <div><dt>{p.ccSymbol} total supply</dt><dd>{p.ccSupply}</dd></div>
          <div><dt>contribution rate</dt><dd>{p.contributionRate} of each conversion</dd></div>
          <div><dt>redemption fee</dt><dd>{p.feeRate}</dd></div>
          <div><dt>{p.redemptionOpen ? "redeemable share" : "backing"} per {p.ccSymbol} (claim reserve over the total supply)</dt><dd>{p.backingPerCc} {p.balanceSymbol}</dd></div>
          <div><dt>your {p.ccSymbol}</dt><dd>{p.connected ? p.walletCc : "connect your wallet"}</dd></div>
        </dl>
      </div>
      <div className="claim-form">
        {!p.redemptionOpen ? (
          <div className="claim-accumulating">
            <p className="claim-accumulating-title">backing accumulating</p>
            <p className="claim-status" role="status">{p.status}</p>
            <dl className="claim-quote">
              <div><dt>claim reserve, earmarked</dt><dd>{p.claimReserve} {p.balanceSymbol}</dd></div>
              <div><dt>contribution rate</dt><dd>{p.contributionRate} of each conversion</dd></div>
              <div><dt>available working funds</dt><dd>{p.available} {p.balanceSymbol}</dd></div>
            </dl>
            <p className="claim-explanation">
              The claim reserve is earmarked as backing for {p.ccSymbol} burns and is not redeemable now. It grows with each
              Statement conversion at the contribution rate, read live from the treasury. No holder can burn {p.ccSymbol} for
              {" "}{p.balanceSymbol} until the owner turns the treasury&apos;s redemption switch on; the form opens here when it does.
            </p>
            <div className="claim-amount">
              <label htmlFor="claim-amount">{p.ccSymbol} to preview</label>
              <output className="claim-amount-value" htmlFor="claim-amount">{p.amount} {p.ccSymbol}</output>
              <input
                id="claim-amount"
                type="range"
                min="0"
                max="10000"
                step="1"
                value={p.amountBps}
                disabled={!p.connected}
                aria-valuetext={`${p.amount} ${p.ccSymbol}`}
                onChange={(e) => p.onAmountChange(Number(e.target.value))}
              />
              <span className="claim-range-labels" aria-hidden="true"><span>0</span><span>100%</span></span>
            </div>
            <dl className="claim-quote claim-preview">
              <div><dt>preview under the current policy</dt><dd>{p.preview} {p.balanceSymbol}</dd></div>
            </dl>
            <p className="claim-footnote">
              The preview is what the current policy would pay for that burn at today&apos;s reserve and supply. It is not an
              executable quote: redemption is closed, and the reserve, the supply and the policy can change before it opens.
            </p>
          </div>
        ) : p.receipt ? (
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
              Your quote and minimum are locked when you confirm. The transaction expires after 20 minutes and reverts if the owner
              changes the redemption terms, if the treasury pays under your minimum, or if redemption closes.
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
