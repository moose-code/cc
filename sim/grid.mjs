// settings grid for the stale-bid exposure study (EXPOSURE-129-grid). usage: node sim/grid.mjs [out.json]
// rules come from engine.js untouched; only dropPer100PointsBps, climbPerMinBps, recoveryClimbPerMinBps and the pot vary.
// cases: dump, collapse (exit sellers, 500 mixed-score credits), steady (flat 0.020 market plus organic sellers), wave (200 sellers at open).
import fs from 'node:fs';
import { Core, W, DEFAULTS, RATE_SCORE, mulberry32, poisson } from './engine.js';

const BLOCK = 12, REF_PTS = 433, OPEN = DEFAULTS.rateStart / W; // opening rate, eth per 100 points; REF_PTS is the dump credit in points
const CENSUS = [152, 224, 296, 368, 440, 512, 584, 656, 728]; // decile points of the credit score census (sim/data/notes.md)
const A = { credits: 500, ask: 0.005, sellH: 6, totalH: 48, collapseSec: 600, steadyAsk: 0.02, organicPerHour: 35, wave: 200, steadyH: 24, seed: 129 };

const GRID = { drop: [50, 100, 200, 300, 500], climb: [50, 100, 200], recFloor: [200, 400], pot: [10, 100] };

function makeCore(cell) {
  const p = { ...DEFAULTS, dropPerCreditPct: cell.drop / 100, climbPerMin: cell.climb / 100, recoveryClimbPerMin: cell.rec / 100, spendCapBps: 100 };
  const core = new Core(p, 0);
  core.fund(cell.pot, 0);
  return core;
}
const bidAt = (core, t) => core.ethRate(t) / W;

// exit sellers: credits sold in seeded inventory order whenever the score-scaled bid covers the per-credit ask; the payment is the bid
function runExit(cell, scenario) {
  const rng = mulberry32(A.seed);
  const inv = Array.from({ length: A.credits }, (_, i) => CENSUS[i % CENSUS.length]);
  for (let i = inv.length - 1; i > 0; i--) { const j = Math.floor(rng() * (i + 1)); [inv[i], inv[j]] = [inv[j], inv[i]]; }
  const core = makeCore(cell);
  const askAt = (t) => scenario === 'dump' ? A.ask : OPEN * (1 - 0.8 * Math.min(t / A.collapseSec, 1));
  const finalAsk = A.ask;
  let bought = 0, spent = 0, overpay = 0, crossing = null, stop = null, recovery = null, stalls = 0;
  const hourly = Array(A.sellH).fill(0), nByHour = Array(A.sellH).fill(0), ratioByHour = Array(A.sellH).fill(0);
  const check = (t) => {
    if (crossing === null && (scenario === 'dump' || t >= A.collapseSec) && bidAt(core, t) < finalAsk) crossing = { sec: t, credits: bought, spent, potEth: core.ethPot };
  };
  for (let t = 0; t <= A.totalH * 3600; t += BLOCK) {
    check(t);
    if (stop === null && (t >= A.sellH * 3600 || inv.length === 0)) stop = { sec: t, bid: bidAt(core, t), pot: core.ethPot };
    if (stop !== null) {
      if (recovery === null && bidAt(core, t) >= OPEN * (1 - 1e-9)) { recovery = t - stop.sec; break; }
      continue;
    }
    for (;;) {
      const bid = bidAt(core, t), ask = askAt(t);
      const idx = inv.findIndex((pts) => bid * pts * 1e4 / RATE_SCORE >= ask);
      if (idx < 0) break;
      const paid = core.sellForEth(t, inv[idx]);
      if (!(paid > 0)) { stalls++; break; }
      const h = Math.min(A.sellH - 1, Math.floor(t / 3600));
      hourly[h] += paid; nByHour[h]++; ratioByHour[h] += inv[idx] * 1e4 / RATE_SCORE;
      inv.splice(idx, 1); bought++; spent += paid; overpay += Math.max(0, paid - ask); check(t);
      if (!inv.length) break;
    }
  }
  const end = bidAt(core, A.totalH * 3600);
  return {
    spent, credits: bought, crossingMin: crossing && crossing.sec / 60, spentAfterCrossing: crossing ? spent - crossing.spent : null, potAtCrossing: crossing && crossing.potEth,
    creditsAfterCrossing: crossing ? bought - crossing.credits : null, overpay, stopMin: stop && stop.sec / 60,
    recoveryMin: recovery === null ? null : recovery / 60, bidAtStop: stop && stop.bid, finalBid: end, remaining: inv.length, potEnd: core.ethPot,
    stalls, ethByHour: hourly, creditsByHour: nByHour, scoreRatioSumByHour: ratioByHour,
  };
}

// market sellers at refScore: unlimited sellers at steadyAsk, organic sellers at the bid (35 an hour), optional launch wave at the bid.
// holdPot refills the pot at each block so the run measures the rule rather than the pot running dry.
function runMarket(cell, withWave, background = true, organicPerHour = A.organicPerHour) {
  const rng = mulberry32(A.seed + 1);
  const core = makeCore(cell);
  const hours = A.steadyH;
  const fills = Array(hours).fill(0), eth = Array(hours).fill(0), unl = Array(hours).fill(0), bidSum = Array(hours).fill(0), bidN = Array(hours).fill(0);
  let organicQueue = 0, wave = withWave ? A.wave : 0, waveDone = null, total = 0, spent = 0, stalls = 0, waveSpent = 0, wavePotLow = core.ethPot;
  for (let t = 0; t < hours * 3600; t += BLOCK) {
    if (!withWave) { core.ethPot = cell.pot; core.syncFunded(); }
    organicQueue += poisson(rng, (organicPerHour * BLOCK) / 3600);
    let progress = true, stalled = false;
    while (progress && !stalled) {
      progress = false;
      const groups = [
        () => wave > 0 && 'wave', () => background && organicQueue > 0 && 'organic', () => background && bidAt(core, t) >= A.steadyAsk && 'unlimited',
      ];
      for (const g of groups) {
        const who = g();
        if (!who) continue;
        const paid = core.sellForEth(t, REF_PTS);
        if (!(paid > 0)) { stalls++; stalled = true; break; }
        progress = true; total++; spent += paid; fills[Math.floor(t / 3600)]++; eth[Math.floor(t / 3600)] += paid;
        if (who === 'wave') { wave--; waveSpent += paid; if (wave === 0) waveDone = t; }
        else if (who === 'organic') organicQueue--;
        else unl[Math.floor(t / 3600)]++;
      }
    }
    bidSum[Math.floor(t / 3600)] += bidAt(core, t); bidN[Math.floor(t / 3600)]++;
    wavePotLow = Math.min(wavePotLow, core.ethPot);
    if (withWave && waveDone !== null) break;
  }
  return { fills, eth, unl, bidMean: bidSum.map((x, i) => x / bidN[i]), total, spent, stalls, waveDoneMin: waveDone === null ? null : waveDone / 60, waveSpent, potLow: wavePotLow };
}

const mean = (a) => a.reduce((x, y) => x + y, 0) / a.length;

export function runCell(cell) {
  const dump = runExit(cell, 'dump'), collapse = runExit(cell, 'collapse');
  const steady = runMarket(cell, false), noOrganic = runMarket(cell, false, true, 0), wave = runMarket(cell, true), waveAlone = runMarket(cell, true, false);
  const perHourSteady = mean(steady.fills.slice(12));
  return {
    cell,
    dump: { ...dump, ethLast2h: mean(dump.ethByHour.slice(-2)), ethPerHourLast2h: mean(dump.ethByHour.slice(-2)) },
    collapse,
    steady: { creditsPerHour: perHourSteady, noOrganicCreditsPerHour: mean(noOrganic.fills.slice(12)), noOrganicBidMeanLast12h: mean(noOrganic.bidMean.slice(12)), askPoolCreditsPerHour: mean(steady.unl.slice(12)), bidMeanLast12h: mean(steady.bidMean.slice(12)), creditsFirstHour: steady.fills[0], credits24h: steady.total, ethPerDay: steady.spent, ethPerHourSteady: mean(steady.eth.slice(12)), fillsByHour: steady.fills, stalls: steady.stalls, formulaPerHour: (cell.climb / cell.drop) * 60 },
    wave: { clearMin: wave.waveDoneMin, clearMinAlone: waveAlone.waveDoneMin, ethSpentAlone: waveAlone.waveSpent, ethSpent: wave.waveSpent, potLow: wave.potLow, stalls: wave.stalls },
  };
}

export function table(rows) {
  const f = (x, d = 2) => (x == null ? '-' : (+x).toFixed(d));
  const out = ['| cell | dump eth | dump min under market | dump eth after | collapse eth | credits/h | credits/h no organic | bid h12-24 | wave min | limit |', '|---|---|---|---|---|---|---|---|---|---|'];
  for (const r of rows) {
    const { drop, climb, rec, pot } = r.cell, d = r.dump, k = r.collapse, s = r.steady;
    const drained = d.potAtCrossing != null && d.potAtCrossing < 0.02; // crossing caused by an empty pot, not by the price
    const lim = d.spent < (pot === 10 ? 1 : 5) ? 'ok' : 'over';
    out.push(`| ${drop}/${climb}/${rec} pot ${pot} | ${f(d.spent)} | ${drained ? 'pot empty' : f(d.crossingMin, 0)} | ${drained ? '-' : f(d.spentAfterCrossing)} | ${f(k.spent)} | ${f(s.creditsPerHour, 1)} | ${f(s.noOrganicCreditsPerHour, 1)} | ${f(s.bidMeanLast12h, 4)} | ${f(r.wave.clearMin, 0)} | ${lim} |`);
  }
  return out.join('\n');
}

if (process.argv[1] && process.argv[1].endsWith('grid.mjs')) {
  const t0 = Date.now(), rows = [];
  for (const pot of GRID.pot) for (const drop of GRID.drop) for (const climb of GRID.climb) for (const rf of GRID.recFloor) {
    rows.push(runCell({ drop, climb, rec: Math.max(climb, rf), pot }));
  }
  const extras = [10, 100].map((pot) => runCell({ drop: 400, climb: 200, rec: 200, pot })); // off-grid probe between drop 300 and 500
  const out = { extras, assumptions: { ...A, census: CENSUS, openBidEth: OPEN, refPoints: REF_PTS, spendCapBps: 100, blockSeconds: BLOCK, grid: GRID, settingsHeld: { dropFloorBps: DEFAULTS.dropToPct * 100, recoveryGapBps: DEFAULTS.recoveryGapPct * 100, peakHalfLifeHours: DEFAULTS.peakHalfLifeHours, rateCapEth: DEFAULTS.rateCap / W, climbMultiplierCapBps: DEFAULTS.climbMultiplierCapBps, idleLoosenBps: DEFAULTS.idleLoosenPct * 100, ceilBps: DEFAULTS.ceilPct * 100 }, runSeconds: (Date.now() - t0) / 1000 }, rows };
  const file = process.argv[2];
  if (file) { fs.writeFileSync(file, JSON.stringify(out, null, 1)); console.log(table(rows)); } else console.log(JSON.stringify(out, null, 1));
  console.error(`${rows.length} cells in ${out.assumptions.runSeconds.toFixed(1)} s`);
}
