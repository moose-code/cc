"use client";

import type { ReactNode } from "react";
import { CreditTile } from "./Tiles";

export type ExchangeRow = {
  id: number;
  rating: string;
  gross: string;
  selected: boolean;
  disabled?: boolean;
  note?: string;
};

export type ExchangeReceipt = { count: number; minimum: string; hash: string };

export type ExchangeViewProps = {
  rows: ExchangeRow[];
  walletReady: boolean;
  connected: boolean;
  selectionCount: number;
  quoteAvailable: boolean;
  selectedRating: string;
  total: string;
  fee?: string; // the protocol fee in $BALANCE for the selection; the row is left out until a Credit is selected
  available?: string; // the treasury's $BALANCE free for the exchange, shown once the exchange is open
  adjustment?: string;
  minimum: string;
  rate: string;
  slippageBps: number;
  onSlippageChange: (bps: number) => void;
  onToggle: (id: number) => void;
  onSelectAll: () => void;
  allSelected: boolean;
  busy: boolean;
  status?: string;
  error?: string;
  receipt?: ExchangeReceipt;
  onReset: () => void;
  action: ReactNode;
};

export function ExchangeView({
  rows, walletReady, connected, selectionCount, quoteAvailable, selectedRating, total, fee, available, adjustment,
  minimum, rate, slippageBps, onSlippageChange, onToggle, onSelectAll,
  allSelected, busy, status, error, receipt, onReset, action,
}: ExchangeViewProps) {
  const selected = rows.filter((row) => row.selected);
  return (
    <main className="exchange-page">
      <section className="exchange-inventory" aria-labelledby="exchange-title">
        <div className="exchange-inventory-inner">
          <h1 id="exchange-title">Exchange Credits for $BALANCE</h1>
          <div className="exchange-list-heading">
            <div>
              <strong>your credits</strong>
              {walletReady && connected && <span> · {rows.length} in wallet · {selectionCount} selected</span>}
            </div>
            <button
              className="exchange-select-all"
              onClick={onSelectAll}
              disabled={busy || !rows.some((row) => !row.disabled)}
            >
              {allSelected ? "deselect all" : "select all"}
            </button>
          </div>
          <div className="exchange-table-frame">
            <table className="exchange-table">
              <thead>
                <tr><th scope="col">credit</th><th scope="col">rating</th><th scope="col"><span className="exchange-sr-only">select</span></th></tr>
              </thead>
              <tbody>
                {rows.map((row) => (
                  <tr key={row.id} className={`${row.selected ? "is-selected" : ""}${row.disabled ? " is-unavailable" : ""}`}>
                    <th scope="row">
                      <label className="exchange-credit" htmlFor={`exchange-credit-${row.id}`}>
                        <span className="exchange-art"><CreditTile id={row.id} /></span>
                        <span><strong>Credit #{row.id}</strong>{row.note && <small>{row.note}</small>}</span>
                      </label>
                    </th>
                    <td className="exchange-rating">{row.rating}</td>
                    <td className="exchange-selection">
                      <input
                        id={`exchange-credit-${row.id}`}
                        type="checkbox"
                        aria-label={`Select Credit #${row.id}`}
                        checked={row.selected}
                        disabled={busy || row.disabled}
                        onChange={() => onToggle(row.id)}
                      />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {rows.length === 0 && <p className="exchange-empty" role="status">{status || (!walletReady ? "Loading wallet…" : connected ? "No Credits in this wallet." : "Connect your wallet to view your Credits.")}</p>}
          </div>
          {rows.length > 0 && status && <p className="exchange-inventory-status" role="status">{status}</p>}
          {/* mobile: the selection and its payout stay at the bottom of the screen while the list scrolls, and the bar
              docks at the end of the list once the checkout below comes into view */}
          {connected && rows.length > 0 && !receipt && (
            <div className="exchange-mobile-bar">
              <span>{selectionCount === 0 ? "select Credits to exchange"
                : `${selectionCount} selected · ${quoteAvailable ? `${total} $BALANCE` : `${selectedRating} pts`}`}</span>
              <a href="#exchange-summary">review</a>
            </div>
          )}
        </div>
      </section>

      <section id="exchange-summary" className="exchange-summary" aria-labelledby="exchange-receive-title" aria-busy={busy}>
        {receipt ? (
          <div className="exchange-success" role="status">
            <p className="exchange-success-title" id="exchange-receive-title">sale complete</p>
            <p className="exchange-success-value">{receipt.count}</p>
            <p className="exchange-success-currency">Credit{receipt.count === 1 ? "" : "s"} sold for $BALANCE</p>
            <dl className="exchange-breakdown">
              <div><dt>minimum received</dt><dd>{receipt.minimum} $BALANCE</dd></div>
              <div><dt>transaction</dt><dd><code title={receipt.hash}>{shortHash(receipt.hash)}</code></dd></div>
            </dl>
            <button type="button" onClick={onReset}>sell more Credits</button>
          </div>
        ) : <>
        <div className="exchange-summary-content">
          {status && <p className="exchange-quote-status" role="status">{status}</p>}
          {available && <p className="exchange-available">{available} $BALANCE available to exchange from the Credit Cycle treasury</p>}
          <p className="exchange-eyebrow" id="exchange-receive-title">you receive</p>
          <div className="exchange-total" aria-live="polite" aria-atomic="true">{total}</div>
          <div className="exchange-currency"><i aria-hidden="true" />$BALANCE</div>
          <dl className="exchange-breakdown">
            {selected.map((row) => <div key={row.id}><dt>Credit #{row.id}</dt><dd>{quoteAvailable ? row.gross : `${row.rating} pts`}</dd></div>)}
            {selected.length > 0 && !quoteAvailable && <div><dt>selected rating</dt><dd>{selectedRating} pts</dd></div>}
            {fee && <div><dt>protocol fee</dt><dd>{fee} $BALANCE</dd></div>}
            {adjustment && <div><dt>price-protection adjustment</dt><dd>{adjustment}</dd></div>}
            <div className="exchange-breakdown-total"><dt>you receive</dt><dd>{total} $BALANCE</dd></div>
          </dl>
          <p className="exchange-explanation">{quoteAvailable
            ? `Credits are quoted at ${rate} of rating. Price protection can lower the quote. Your transaction receives at least the minimum below or reverts.`
            : "Credit ratings are shown in points. No executable BALANCE payout is available yet. The live payout and minimum will appear when the exchange is ready."}</p>
          <div className="exchange-slippage">
            <span id="exchange-slippage-label">slippage tolerance</span>
            <div role="group" aria-labelledby="exchange-slippage-label">
              {[0, 50, 100].map((bps) => (
                <button key={bps} type="button" aria-pressed={slippageBps === bps} disabled={busy} onClick={() => onSlippageChange(bps)}>{bps / 100}%</button>
              ))}
            </div>
          </div>
          <div className="exchange-minimum"><span>minimum you receive</span><strong>{minimum} $BALANCE</strong></div>
        </div>
        <div className="exchange-submit">
          {error && <p className="exchange-error" role="alert">{error}</p>}
          {action}
          <p>First sale asks once to approve the collection.</p>
        </div>
        </>}
      </section>
    </main>
  );
}

function shortHash(hash: string): string {
  return hash.length > 20 ? `${hash.slice(0, 10)}…${hash.slice(-8)}` : hash;
}
