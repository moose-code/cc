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
    log("CreditBought", 3, { id: 10n, from: a, cost: 1n, toArtist: 0n }),
    log("BalanceFill", 4, { paid: 2n * 10n ** 18n, toArtist: 0n, available: 0n }),
    log("CreditBought", 5, { id: 11n, from: a, cost: 1n, toArtist: 0n }),
    log("BalanceFill", 6, { paid: 3n * 10n ** 18n, toArtist: 0n, available: 0n }),
    log("BalanceModuleSet", 7, { balanceToken: b }),
    log("StatementRedeemed", 8, { sid: 2n, received: 10n ** 6n }),
  ],
  head: 100n, burned: 0n, modes: new Map(), balanceToken: current,
});
assert.equal(result.statements[1].redeemed?.token, a);
assert.equal(result.statements[2].redeemed?.token, b);
assert.equal(result.rows[0].detail, `· module received 1000000000000000000 raw units (${a})`);
assert.equal(result.rows[1].eth, `2000000000000000000 raw units (${a})`);
assert.equal(result.rows[2].eth, `3000000000000000000 raw units (${a})`);
assert.equal(result.rows[3].detail, `· module received 1 $BALANCE (${b})`);

// promise: missing event-time identity or metadata never borrows the current token's decimals.
assert.equal(formatHistoricalBalance(10n ** 18n, a, current), `1000000000000000000 raw units (${a})`);
assert.equal(formatHistoricalBalance(1n, undefined, current), "1 raw units (token unknown)");
const unknown = processLogs({ logs: [log("StatementRedeemed", 1, { sid: 3n, received: 1n })], head: 100n, burned: 0n, modes: new Map(), balanceToken: current });
assert.equal(unknown.statements[3].redeemed?.token, undefined);
assert.equal(unknown.rows[0].detail, "· module received 1 raw units (token unknown)");

// promise: the indexer feed displays the saved currency for both redemptions and balance-credit payments.
const row = { id: "test", kind: "redeemed", creditId: null, other: null, statementId: 1n, account: null, amount: 10n ** 18n, amount2: null, balanceToken: a, ts: 100n, tx, rating: null, mode: null, composedFormat: null, restyledTo: null } as Parameters<typeof feedEvent>[0];
assert.equal(feedEvent(row, current).detail, `· module received 1000000000000000000 raw units (${a})`);
assert.equal(feedEvent({ ...row, balanceToken: b, amount: 10n ** 6n }, current).detail, `· module received 1 $BALANCE (${b})`);
assert.equal(feedEvent({ ...row, balanceToken: null }, current).detail, "· module received 1000000000000000000 raw units (token unknown)");
assert.equal(feedEvent({ ...row, kind: "credit_bought", creditId: 10n, amount2: 2n * 10n ** 18n }, current).eth, `2000000000000000000 raw units (${a})`);

// promise: a value-mode ETH fill counts as ETH spent and classifies the following CreditBought as an ETH bid.
const valued = processLogs({
  logs: [
    log("ValueRateFill", 1, { spent: 2n * 10n ** 17n, rateBps: 11_000n, pot: 1n }),
    log("CreditBought", 2, { id: 12n, from: a, cost: 3n * 10n ** 17n, toArtist: 0n }),
  ],
  head: 100n, burned: 0n, modes: new Map(), balanceToken: current,
});
assert.equal(valued.stats.creditsEth, 1);
assert.equal(valued.stats.creditsBalance, 0);
assert.equal(valued.stats.ethIntoCredits, 0.2);
assert.equal(valued.credits[12][0].t, "bought");
assert.equal(valued.credits[12][0].t === "bought" ? valued.credits[12][0].rate : 1n, undefined);

// promise: "ETH recycled" sums the pot's part of StatementSoldTo sales (price less buyback, artist and operator) and
// leaves out a controller-only Bought sale, whose split is unknown.
const e = (n: bigint) => n * 10n ** 16n; // hundredths of an ETH
const sales = processLogs({
  logs: [
    log("StatementSoldTo", 1, { sid: 4n, buyer: a, price: e(100n), toBuyback: e(20n), toArtist: e(10n), toOperator: e(5n) }),
    { ...log("Bought", 1, { sid: 5n, buyer: a, price: e(50n) }), transactionHash: `0x${"2".repeat(64)}` },
  ],
  head: 100n, burned: 0n, modes: new Map(), balanceToken: current,
});
assert.equal(sales.stats.sold, 2);
assert.equal(sales.stats.potSales, 1);
assert.equal(sales.stats.ethToPot, 0.65);
assert.equal(sales.statements[4].sold?.toPot, e(65n));
assert.equal(sales.rows[0].detail, "· 0.65 ETH to the pot · 0.2 to buyback · bought by");

// promise: each Buyback is a "$CC burned" ledger row with the ETH spent and the coin the Core burned in its own tx.
const burns = processLogs({
  logs: [log("Buyback", 3, { caller: a, amountIn: e(80n), paid: 0n })],
  head: 100n, burned: 8_214_330n * 10n ** 18n, burns: new Map([[tx, 8_214_330n * 10n ** 18n]]), modes: new Map(), balanceToken: current,
});
assert.deepEqual(
  { kind: burns.rows[0].kind, title: burns.rows[0].title, detail: burns.rows[0].detail, eth: burns.rows[0].eth },
  { kind: "burned", title: "8,214,330 $CC", detail: "bought with 0.8 ETH", eth: "0.8" },
);
console.log("history selfcheck ok");
