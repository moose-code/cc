// no-floor study (EXPOSURE-146): five drop-floor / spend-cap configurations over the grid's four cases. usage: node sim/nofloor.mjs [out.json]
import fs from 'node:fs';
import { A, runExit, runMarket } from './grid.mjs';

A.steadyAsk = 0.018; // steady and wave sellers ask 0.018
const CONFIGS = {
  A: { label: 'A today: floor 5000, cap 100', drop: 500, climb: 200, rec: 200, floorBps: 5000, cap: 100 },
  B: { label: 'B no floor, no cap, rec 200', drop: 500, climb: 200, rec: 200, floorBps: 1, cap: 10000 },
  C: { label: 'C no floor, no cap, rec 500', drop: 500, climb: 200, rec: 500, floorBps: 1, cap: 10000 },
  D: { label: 'D no floor, no cap, rec 500, drop 300', drop: 300, climb: 200, rec: 500, floorBps: 1, cap: 10000 },
  E: { label: 'E floor 5000, no cap', drop: 500, climb: 200, rec: 200, floorBps: 5000, cap: 10000 },
};
const mean = (a) => a.reduce((x, y) => x + y, 0) / a.length;
const rows = [];
for (const pot of [10, 100]) for (const [k, c] of Object.entries(CONFIGS)) {
  const cell = { ...c, pot };
  const d = runExit(cell, 'dump'), col = runExit(cell, 'collapse');
  const st = runMarket(cell, false), no = runMarket(cell, false, true, 0), w = runMarket(cell, true);
  rows.push({
    cfg: k, pot, label: c.label,
    dumpBefore: d.crossingMin == null ? d.spent : d.spent - d.spentAfterCrossing, dumpTotal: d.spent, credits: d.credits, points: d.pointsBought,
    crossMin: d.crossingMin, drained: d.potAtCrossing != null && d.potAtCrossing < 0.02, recMin: d.recoveryMin, worstMin: d.worstMinuteEth,
    avgShare: d.credits ? d.spent / d.credits / A.ask : null, steadyPerH: mean(st.fills.slice(12)), steadyNoOrg: mean(no.fills.slice(12)), steadyBid: mean(st.bidMean.slice(12)),
    waveMin: w.waveDoneMin, waveSpent: w.waveSpent, refusedPct: 100 * d.refusedProbes / d.probes, probes: d.probes, collapse: col.spent, remaining: d.remaining, stopMin: d.stopMin, stalls: d.stalls,
  });
}
if (process.argv[2]) fs.writeFileSync(process.argv[2], JSON.stringify(rows, null, 1));
const f = (x, d = 2) => (x == null ? '-' : (+x).toFixed(d));
for (const pot of [10, 100]) {
  console.log(`\npot ${pot}`);
  console.log('| config | dump eth before under market | dump eth 6 h | credits | points | min to under market | min to recover | worst minute eth | credits/h steady, with 35/h organic | credits/h, no organic | wave min | avg price / market | refused minutes % | collapse eth |');
  console.log('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|');
  for (const r of rows.filter((r) => r.pot === pot)) console.log(`| ${r.cfg} | ${f(r.dumpBefore)} | ${f(r.dumpTotal)} | ${r.credits} | ${r.points} | ${r.drained ? 'pot empty' : f(r.crossMin, 0)} | ${f(r.recMin, 0)} | ${f(r.worstMin, 3)} | ${f(r.steadyPerH, 1)} | ${f(r.steadyNoOrg, 1)} | ${f(r.waveMin, 0)} | ${f(r.avgShare, 2)} | ${f(r.refusedPct, 0)} | ${f(r.collapse)} |`);
}
