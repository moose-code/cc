// promise: the published launch exposure table reflects the current 0.1 ETH reserve and 2.5 percent purchase royalty.
// This guard fails on 1db4a9f and belongs with regenerated exposure artifacts.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { runCell } from "./ceiling.mjs";

test("published exposure grid records the candidate reserve and royalty", () => {
  const old = JSON.parse(readFileSync(new URL("../docs/reviews/EXPOSURE-148-ceiling.json", import.meta.url), "utf8"));
  const common = { drop: 115, climb: 200, rec: 200, floorBps: 1, cap: 10_000, ceilBps: 11_000, idleStepSeconds: 600, idleLoosenBps: 600 };
  const measured = [];
  for (const pot of [0.5, 2, 10]) {
    const prior = old.rows.find((r) => r.cell.pot === pot && r.cell.ceilBps === 11_000 && r.cell.idleStepSeconds === 600 && r.cell.idleLoosenBps === 600);
    assert.ok(prior);
    const now = runCell({ ...common, pot });
    const total = now.dumpEth * 1.025;
    measured.push({ published: prior, seller: now.dumpEth, artist: total - now.dumpEth, total });
    process.stdout.write(`pot ${pot} ETH: published seller spend ${prior.dumpEth.toFixed(6)}, current seller spend ${now.dumpEth.toFixed(6)}, current all-in ${total.toFixed(6)} ETH\n`);
  }
  assert.equal(String(old.launch.reserveWei), "100000000000000000", "exposure grid must state the launch reserve");
  assert.equal(old.launch.buyToArtistBps, 250, "exposure grid must include the purchase royalty");
  for (const { published, seller, artist, total } of measured) {
    assert.ok(Math.abs(published.sellerSpendEth - seller) < 1e-6, "the seller column must use candidate settings");
    assert.ok(Math.abs(published.artistRoyaltyEth - artist) < 1e-6, "the artist column must show the royalty");
    assert.ok(Math.abs(published.potSpendEth - total) < 1e-6, "the pot column must include seller and artist");
  }
});
