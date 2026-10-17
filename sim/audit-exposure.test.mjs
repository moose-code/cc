// promise: the published launch exposure table reflects the current 0.1 ETH reserve and 2.5 percent purchase royalty.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { runCell } from "./ceiling.mjs";

test("historical exposure numbers omit the candidate royalty and reserve", () => {
  const old = JSON.parse(readFileSync(new URL("../docs/reviews/EXPOSURE-148-ceiling.json", import.meta.url), "utf8"));
  const common = { drop: 115, climb: 200, rec: 200, floorBps: 1, cap: 10_000, ceilBps: 11_000, idleStepSeconds: 600, idleLoosenBps: 600 };
  for (const pot of [0.5, 2, 10]) {
    const prior = old.rows.find((r) => r.cell.pot === pot && r.cell.ceilBps === 11_000 && r.cell.idleStepSeconds === 600 && r.cell.idleLoosenBps === 600);
    assert.ok(prior);
    const now = runCell({ ...common, pot });
    const total = now.dumpEth * 1.025;
    if (pot === 0.5) assert.ok(total < prior.dumpEth - 0.09, "the new reserve protects about 0.1 ETH");
    else assert.ok(total > prior.dumpEth + 0.019, "the royalty adds about 0.02 ETH to a 0.789 ETH seller dump");
    process.stdout.write(`pot ${pot} ETH: published seller spend ${prior.dumpEth.toFixed(6)}, current seller spend ${now.dumpEth.toFixed(6)}, current all-in ${total.toFixed(6)} ETH\n`);
  }
});
