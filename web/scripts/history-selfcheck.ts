import assert from "node:assert/strict";
import { processLogs } from "../lib/events";
import { formatHistoricalBalance } from "../lib/format";
import { feedEvent } from "../lib/indexer";

const a = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as const;
const b = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" as const;
const current = { address: b, decimals: 6 };
const tx = `0x${"1".repeat(64)}`;
const log = (eventName: string, logIndex: number, args: Record<string, unknown>) => ({ eventName, logIndex, args, transactionHash: tx, blockNumber: 100n });

// promise: same-block replacements preserve the token selected before each redemption, not today's decimals.
const result = processLogs({
  logs: [
    log("BalanceModuleSet", 1, { balanceToken: a }),
    log("StatementRedeemed", 2, { sid: 1n, received: 10n ** 18n }),
    log("CreditBought", 3, { id: 10n, from: a, cost: 1n }),
    log("BalanceRateFill", 4, { spent: 2n * 10n ** 18n }),
    log("CreditBought", 5, { id: 11n, from: a, cost: 1n }),
    log("BalanceRateFill", 6, { spent: 3n * 10n ** 18n }),
    log("BalanceModuleSet", 7, { balanceToken: b }),
    log("StatementRedeemed", 8, { sid: 2n, received: 10n ** 6n }),
  ],
  head: 100n, burned: 0n, modes: new Map(), balanceToken: current,
});
assert.equal(result.statements[1].redeemed?.token, a);
assert.equal(result.statements[2].redeemed?.token, b);
assert.equal(result.rows[0].detail, `· received 1000000000000000000 raw units (${a})`);
assert.equal(result.rows[1].eth, `2000000000000000000 raw units (${a})`);
assert.equal(result.rows[2].eth, `3000000000000000000 raw units (${a})`);
assert.equal(result.rows[3].detail, `· received 1 $BALANCE (${b})`);

// promise: missing event-time identity or metadata never borrows the current token's decimals.
assert.equal(formatHistoricalBalance(10n ** 18n, a, current), `1000000000000000000 raw units (${a})`);
assert.equal(formatHistoricalBalance(1n, undefined, current), "1 raw units (token unknown)");
const unknown = processLogs({ logs: [log("StatementRedeemed", 1, { sid: 3n, received: 1n })], head: 100n, burned: 0n, modes: new Map(), balanceToken: current });
assert.equal(unknown.statements[3].redeemed?.token, undefined);
assert.equal(unknown.rows[0].detail, "· received 1 raw units (token unknown)");

// promise: the indexer feed displays the saved currency for both redemptions and balance-credit payments.
const row = { id: "test", kind: "redeemed", creditId: null, other: null, statementId: 1n, account: null, amount: 10n ** 18n, amount2: null, balanceToken: a, ts: 100n, tx, rating: null, mode: null, composedFormat: null, restyledTo: null } as Parameters<typeof feedEvent>[0];
assert.equal(feedEvent(row, current).detail, `· received 1000000000000000000 raw units (${a})`);
assert.equal(feedEvent({ ...row, balanceToken: b, amount: 10n ** 6n }, current).detail, `· received 1 $BALANCE (${b})`);
assert.equal(feedEvent({ ...row, balanceToken: null }, current).detail, "· received 1000000000000000000 raw units (token unknown)");
assert.equal(feedEvent({ ...row, kind: "credit_bought", creditId: 10n, amount2: 2n * 10n ** 18n }, current).eth, `2000000000000000000 raw units (${a})`);
console.log("history selfcheck ok");
