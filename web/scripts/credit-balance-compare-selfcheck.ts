import assert from "node:assert/strict";
import { grossBalance, postedBalance, workingSurplus, parseAsks, relativeGap, ethPerPoint, ethValueAtSpot } from "../lib/credit-balance-compare.ts";

const p300 = 300n * 10_000n;
const unit = 10n ** 18n;
assert.equal(grossBalance(p300), 300n * unit);
assert.equal(postedBalance(p300, 8_000), 240n * unit);
assert.equal(workingSurplus(p300, 240n * unit), 228n * unit / 10n); // 300 - 240 - 7.2 - 30 = 22.8
assert.equal(workingSurplus(p300, postedBalance(p300, 9_000)), -81n * unit / 10n); // 300 - 270 - 8.1 - 30 = -8.1
assert.throws(() => postedBalance(p300, 10_001));
assert.equal(ethValueAtSpot(240n * unit, 12_000), 0.02);
assert.equal(relativeGap(0.02, 20_000_000_000_000_000n), 0);
assert.equal(ethPerPoint(30_000_000_000_000_000n, p300), 0.0001);
assert.equal(ethValueAtSpot(240n * unit, undefined), undefined);

const asks = parseAsks([
  { id: "1", price: "30000000000000000", score: "3000000", hash: "0x1" },
  { id: "2", price: "20000000000000000", score: null },
  { id: "1", price: "20000000000000000", score: "3000000", hash: "0x2" },
  { id: "3", price: "0", score: "9000000" }
], [
  { id: "1", price: "25000000000000000", score: "3000000" },
  { id: "4", price: "30000000000000000", score: "6000000" }
]);
assert.equal(asks.length, 3);
assert.equal(asks[0].id, "4"); // 0.03 ETH / 600 pts beats 0.02 ETH / 300 pts
assert.equal(asks[1].priceWei, 20_000_000_000_000_000n);
assert.equal(asks[1].source, "OpenSea");
assert.equal(asks[2].source, "CreditStrategy"); // venues remain separate
console.log("credit ↔ balance comparison math: calculations and sorting passed");
