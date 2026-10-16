// ceiling study (EXPOSURE-148): ceilBps x idleStepSeconds x idleLoosenBps over the grid's cases at small pots. usage: node sim/ceiling.mjs [out.json]
// launch values for everything else; steady sellers ask 10 to 25 percent above the bid left by the previous fill.
import fs from 'node:fs';
import { A, BLOCK, REF_PTS, OPEN, makeCore, runExit, runMarket } from './grid.mjs';
import { mulberry32, poisson, DEFAULTS, W } from './engine.js';

const REF_RATIO = (REF_PTS * 1e4) / 1_000_000;
const LAUNCH = { drop: 115, climb: 200, rec: 200, floorBps: 1, cap: 10000 };
const GRID = { pots: [0.5, 2, 10], ceil: [11000, 13000, 15000, 20000], step: [600, 300], loosen: [600, 1200], seeds: [1, 2, 3], hours: 24, spread: [0.10, 0.25], noSellerHours: 6 };
const mean = (a) => a.reduce((x, y) => x + y, 0) / a.length;

// steady market: one ask seller whose ask is (1 + u) times a base, u uniform in the spread; organic sellers at the bid (35 an hour).
// base: 'open' is the opening bid (a fixed market level, stationary); 'follow' is the bid the previous fill leaves (the owner's reading, the market ratchets up to the rate cap).
// the pot is refilled each block. a fill by either kind redraws the ask.
function runSpread(cell, seed, organic, mode = 'open') {
  const rng = mulberry32(seed), core = makeCore(cell), bid = (t) => core.ethRate(t) / W * REF_RATIO;
  const base = (t) => (mode === 'open' ? OPEN * REF_RATIO : bid(t)), draw = (t) => base(t) * (1 + GRID.spread[0] + (GRID.spread[1] - GRID.spread[0]) * rng());
  const fills = Array(GRID.hours).fill(0), askFills = Array(GRID.hours).fill(0);
  let ask = draw(0), queue = 0;
  for (let t = 0; t < GRID.hours * 3600; t += BLOCK) {
    core.ethPot = cell.pot; core.syncFunded();
    queue += poisson(rng, (organic * BLOCK) / 3600);
    for (let guard = 0; guard < 50; guard++) {
      const who = queue > 0 ? 'organic' : bid(t) >= ask ? 'ask' : null;
      if (!who) break;
      if (!(core.sellForEth(t, REF_PTS) > 0)) break;
      fills[Math.floor(t / 3600)]++;
      if (who === 'ask') askFills[Math.floor(t / 3600)]++; else queue--;
      ask = draw(t);
    }
  }
  return { fills, askFills };
}

// no sellers: highest rate as a multiple of the opening rate, and minutes until it first reaches 3x (the rate cap).
function runIdle(cell) {
  const core = makeCore(cell); let max2 = 0, max6 = 0, to3x = null;
  for (let t = 0; t <= GRID.noSellerHours * 3600; t += BLOCK) {
    const x = core.ethRate(t) / W / OPEN;
    if (t <= 7200) max2 = Math.max(max2, x);
    max6 = Math.max(max6, x);
    if (to3x === null && x >= 3 - 1e-9) to3x = t / 60;
  }
  return { x2h: max2, x6h: max6, to3xMin: to3x };
}

export function runCell(cell) {
  const sp = GRID.seeds.map((s) => runSpread(cell, A.seed + s, A.organicPerHour)), solo = GRID.seeds.map((s) => runSpread(cell, A.seed + s, 0)), fol = GRID.seeds.map((s) => runSpread(cell, A.seed + s, 0, 'follow'));
  const dump = runExit(cell, 'dump'), col = runExit(cell, 'collapse'), wave = runMarket(cell, true, false);
  return {
    cell, first: mean(sp.map((r) => r.fills[0])), firstSolo: mean(solo.map((r) => r.fills[0])), firstFollow: mean(fol.map((r) => r.fills[0])),  soloPerH: mean(solo.map((r) => mean(r.fills.slice(12)))),
    perH: mean(sp.map((r) => mean(r.fills.slice(12)))), askPerH: mean(sp.map((r) => mean(r.askFills.slice(12)))),
    dumpEth: dump.spent, dumpCredits: dump.credits, potEnd: dump.potEnd, worstMin: dump.worstMinuteEth, recMin: dump.recoveryMin, collapse: col.spent,
    waveMin: wave.waveDoneMin, idle: runIdle(cell),
  };
}

if (process.argv[1] && process.argv[1].endsWith('ceiling.mjs')) {
  const t0 = Date.now(), rows = [];
  for (const pot of GRID.pots) for (const ceilBps of GRID.ceil) for (const idleStepSeconds of GRID.step) for (const idleLoosenBps of GRID.loosen) rows.push(runCell({ ...LAUNCH, ceilBps, idleStepSeconds, idleLoosenBps, pot }));
  const out = { grid: GRID, launch: { ...LAUNCH, rateStart: DEFAULTS.rateStart, rateCap: DEFAULTS.rateCap, pointsPerPage: DEFAULTS.pointsPerPage, climbMultiplierCapBps: DEFAULTS.climbMultiplierCapBps }, seconds: (Date.now() - t0) / 1000, rows };
  if (process.argv[2]) fs.writeFileSync(process.argv[2], JSON.stringify(out, null, 1));
  const f = (x, d = 1) => (x == null ? '-' : (+x).toFixed(d));
  for (const pot of GRID.pots) {
    console.log(`\npot ${pot}`);
    console.log('| ceil | step s | loosen | ask book alone: credits first h | ask book alone: credits/h | asks follow the bid: credits first h | with 35/h organic: credits first h | with organic: credits/h | of which ask book | dump eth 6 h | dump credits | worst min eth | collapse eth | recovery min | wave min | idle x open 2 h | idle x open 6 h | min to 3x |');
    console.log('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|');
    for (const r of rows.filter((r) => r.cell.pot === pot)) { const c = r.cell; console.log(`| ${c.ceilBps} | ${c.idleStepSeconds} | ${c.idleLoosenBps} | ${f(r.firstSolo)} | ${f(r.soloPerH)} | ${f(r.firstFollow)} | ${f(r.first)} | ${f(r.perH)} | ${f(r.askPerH)} | ${f(r.dumpEth, 3)} | ${r.dumpCredits} | ${f(r.worstMin, 3)} | ${f(r.collapse, 3)} | ${f(r.recMin, 0)} | ${f(r.waveMin, 0)} | ${f(r.idle.x2h, 2)} | ${f(r.idle.x6h, 2)} | ${f(r.idle.to3xMin, 0)} |`); }
  }
  // probe: what moves the ask book's steady throughput. launch ceiling values, pot 0.5 for throughput, pot 2 for dump cost.
  const probe = [];
  for (const drop of [115, 70]) for (const climb of [200, 300, 500, 800]) {
    const c = { ...LAUNCH, drop, climb, rec: climb, ceilBps: 11000, idleStepSeconds: 600, idleLoosenBps: 600 };
    const th = runCell({ ...c, pot: 0.5 }), dp = runCell({ ...c, pot: 2 });
    probe.push({ drop, climb, askPerH: th.soloPerH, first: th.firstSolo, dumpEth: dp.dumpEth, dumpCredits: dp.dumpCredits, worstMin: dp.worstMin, collapse: dp.collapse, recMin: dp.recMin });
  }
  out.probe = probe;
  if (process.argv[2]) fs.writeFileSync(process.argv[2], JSON.stringify(out, null, 1));
  console.log('\nprobe: drop and climb (recovery climb equal), ceiling at launch');
  console.log('| dropPer100PointsBps | climb and recovery bps | ask book credits first h (pot 0.5) | ask book credits/h (pot 0.5) | dump eth 6 h (pot 2) | dump credits | worst min eth | collapse eth | recovery min |');
  console.log('|---|---|---|---|---|---|---|---|---|');
  for (const r of probe) console.log(`| ${r.drop} | ${r.climb} | ${f(r.first)} | ${f(r.askPerH)} | ${f(r.dumpEth, 3)} | ${r.dumpCredits} | ${f(r.worstMin, 3)} | ${f(r.collapse, 3)} | ${f(r.recMin, 0)} |`);
  console.error(`${rows.length} cells in ${out.seconds.toFixed(1)} s`);
}
