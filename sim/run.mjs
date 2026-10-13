// scenario batches. usage: node run.mjs [q1 q2 ...]. writes results/*.json
import fs from 'node:fs';
import { simulate, summary, WTP_Q, interp, W } from './engine.js';

const OUT = new URL('./results/', import.meta.url).pathname;
fs.mkdirSync(OUT, { recursive: true });
const SEEDS5 = [1, 2, 3, 4, 5], SEEDS3 = [1, 2, 3];
// rateStart as a share of the market price of a credit (0.0089 eth): 1.0 gives the launch default 8.9e15
export const rateAt = (share, price = 0.0089) => share * price * W;

// flat numeric metrics of one run
export function metrics(res) {
  const m = {}, S = res.S, T = res.T, st = res.stats, H = res.H;
  for (const d of [1, 3, 7, 14, 30, 60, 90]) {
    if (d * 24 > H) continue;
    const a = summary(res, d);
    Object.assign(m, {
      ['credits' + d]: a.credits, ['stmts' + d]: a.statements, ['sold' + d]: a.sold, ['burnEth' + d]: a.burnEth, ['burnPct' + d]: a.burnPct,
      ['waiting' + d]: a.waiting, ['exited' + d]: a.exited, ['locked' + d]: a.locked, ['pot' + d]: a.pot, ['recycled' + d]: a.recycled,
      ['salePct' + d]: a.avgSalePct, ['feeToBurn' + d]: a.feeToBurn, ['saleToBurn' + d]: a.saleToBurn,
    });
  }
  const s = summary(res);
  Object.assign(m, {
    potGoneDay: s.potGoneDay == null ? NaN : s.potGoneDay, steadyCredits: s.steadyCredits == null ? NaN : s.steadyCredits,
    steadyStatements: s.steadyStatements == null ? NaN : s.steadyStatements, steadySold: s.steadySold == null ? NaN : s.steadySold,
    steadyBurnEth: s.steadyBurnEth == null ? NaN : s.steadyBurnEth,
    firstFillHour: st.firstFillHour, costVsMarket: st.costVsMarket, costPerPointVsMarket: st.costPerPointVsMarket, costVsAsk: st.costVsAsk,
    avgScoreBought: st.avgScoreBought, clampSteps: st.clampSteps, rateMaxBidRatio: st.rateMaxBidRatio,
    saleOverCost: st.saleOverCost, saleOverFloor: st.saleOverFloor, saleAgeH: st.saleAgeHours, saleAtFloor: st.saleAtFloorShare, anchorBps: st.finalAnchorBps,
    stmtArrivals: st.stmtArrivals, stmtMiss: st.stmtMiss,
    boughtX: T.boughtX, creditSold: T.creditSold, creditGross: T.creditGross, creditToBuyback: T.creditToBuyback, burnEthM: T.burned / 1e6, listingPaid: T.listingPaid, spent: T.spent,
    stCost: T.composed ? T.stCost / T.composed : NaN, stRating: T.composed ? T.stRating / T.composed : NaN,
    xPotEnd: res.core.xPot, redeemBurnEnd: res.core.ethRedeemBurn, redeemBurnMoved: res.core.redeemBurnMoved, potEnd: res.core.ethPot, toBuybackEnd: res.core.ethToBuyback,
    feeToBurnEnd: res.core.feeToBuyback,
    recycledRatio: T.spent ? T.saleGross / T.spent : 0, fees: S.cumFees[H], saleToPot: T.saleToPot, saleToBuyback: T.saleToBuyback,
    f80hours: st.first80 ? st.first80.hours : NaN, f80ratio: st.first80 ? st.first80.ratio : NaN, f80score: st.first80 ? st.first80.avgScore : NaN,
    exitedValue: T.exitedValue, exitedCost: T.exitedCost, exitedValueOverCost: T.exitedCost ? T.exitedValue / T.exitedCost : NaN,
    exitedAgeDays: T.exited ? T.exitedAge / T.exited / 86400 : NaN, xRecv: T.xRecv, stratBought: T.stratBought,
  });
  return m;
}
export function mean(list) {
  const out = {};
  for (const k of Object.keys(list[0])) {
    const v = list.map((o) => o[k]).filter((x) => Number.isFinite(x));
    out[k] = v.length ? v.reduce((a, b) => a + b, 0) / v.length : null;
  }
  return out;
}
// mean over seeds of the metrics of one configuration
export function many(over, seeds = SEEDS3) {
  return mean(seeds.map((s) => metrics(simulate(Object.assign({}, over, { seed: s })))));
}
const r3 = (x) => (x == null || !Number.isFinite(x) ? x : +Number(x).toPrecision(4));
const round = (o) => JSON.parse(JSON.stringify(o, (k, v) => (typeof v === 'number' ? r3(v) : v)));
const write = (name, data) => { fs.writeFileSync(OUT + name + '.json', JSON.stringify(round(data), null, 1)); console.log('wrote', name); };
// share of statement buyers whose willingness to pay multiple is at least x
export function wtpSurvival(x) {
  let lo = 0, hi = 1;
  for (let i = 0; i < 60; i++) { const mid = (lo + hi) / 2; if (interp(WTP_Q, mid) < x) lo = mid; else hi = mid; }
  return 1 - lo;
}
const sweep = (key, vals, base = {}, seeds = SEEDS3) => vals.map((v) => Object.assign({ [key]: v }, many(Object.assign({}, base, { [key]: v }), seeds)));
const batches = {};
const PRESETS = ['comparable', 'sustained17', 'sustained50', 'deadWeek1'];

// ---- q1: the launch configuration as built, 30 60 90 days under each volume preset
batches.q1 = () => {
  const out = { presets: {}, series: [] };
  for (const v of PRESETS) out.presets[v] = many({ volPreset: v }, SEEDS5);
  const r = simulate({ seed: 1 });
  for (const d of [0, 1, 2, 3, 5, 7, 10, 14, 21, 30, 45, 60, 90]) {
    const a = r.at(d);
    out.series.push({ day: d, credits: a.credits, composed: a.composed, sold: a.sold, waiting: a.waiting, pot: a.pot, bid: a.bidRatio, burnPct: a.burnedPct, price: a.coinPrice });
  }
  out.wtpSurvival = Object.fromEntries([0.6, 0.84, 0.9, 1.0, 1.2, 1.5].map((x) => [x, wtpSurvival(x)]));
  return out;
};

// ---- q2: the opening limit as a share of the market price of a credit
batches.q2 = () => {
  const out = { share: [], decline: [], recovery: [] };
  for (const sh of [0.25, 0.4, 0.5, 0.6, 0.75, 0.9, 1.0, 1.25]) {
    out.share.push(Object.assign({ share: sh, rateStart: rateAt(sh) }, many({ rateStart: rateAt(sh) }, SEEDS5)));
    out.decline.push(Object.assign({ share: sh }, many({ rateStart: rateAt(sh), pricePath: 'decline' }, SEEDS3)));
    out.recovery.push(Object.assign({ share: sh }, many({ rateStart: rateAt(sh), pricePath: 'recovery' }, SEEDS3)));
  }
  // the same share at other market prices: the rule scales with price
  out.price = [];
  for (const p0 of [0.0045, 0.018, 0.03]) out.price.push(Object.assign({ p0 }, many({ priceP0: p0, rateStart: rateAt(1.0, p0) }, SEEDS3)));
  return out;
};

// ---- q4: the statement sale: start price, step length, floor, fee share, the waiting buyer
// a row is the mean over seeds; `both` lowers the curve floor and the hard floor together (the Core's hard floor wins over a lower curve floor)
const designRows = (base, seeds) => {
  const out = { base: many(base, seeds) };
  const row = (over) => many(Object.assign({}, base, over), seeds);
  out.markupBps = [10000, 15000, 20000].map((v) => Object.assign({ markupBps: v }, row({ markupBps: v })));
  out.fastDecay = [50, 100, 400].map((v) => Object.assign({ fastDecayBpsPerHour: v }, row({ fastDecayBpsPerHour: v })));
  out.floorHardHolds = [7500, 6000, 5000].map((v) => Object.assign({ floorBps: v, saleFloorBps: 7500 }, row({ floorBps: v })));
  out.floorBoth = [7500, 6000, 5000].map((v) => Object.assign({ floorBps: v, saleFloorBps: v }, row({ floorBps: v, saleFloorBps: v })));
  out.fee = [0, 1000, 2500, 5000].map((v) => Object.assign({ feeToBuybackBps: v }, row({ feeToBuybackBps: v })));
  out.wait = ['no', 'floor'].map((v) => Object.assign({ buyerWaits: v }, row({ buyerWaits: v })));
  return out;
};
batches.q4 = () => {
  const out = { comparable: designRows({}, SEEDS5), sustained17: designRows({ volPreset: 'sustained17' }, SEEDS3), pick: [], wtp: [], buyers: [], change: [] };
  for (const pick of ['cheapest', 'random']) for (const per of [8, 20]) out.pick.push(Object.assign({ pick, stmtPerDay: per }, many({ stmtPick: pick, stmtPerDay: per }, SEEDS5)));
  for (const w of [0.7, 0.84, 1, 1.3, 1.6]) out.wtp.push(Object.assign({ wtpMult: w }, many({ wtpMult: w }, SEEDS3)));
  for (const n of [3, 8, 20, 40]) out.buyers.push(Object.assign({ stmtPerDay: n }, many({ stmtPerDay: n, stmtFloorPerDay: Math.min(2, n) }, SEEDS3)));
  const lower = { floorBps: 6000, saleFloorBps: 6000 };
  for (const [day, patch] of [[7, lower], [14, lower], [30, lower], [14, { markupBps: 12000 }], [14, { feeToBuybackBps: 2500 }]]) {
    out.change.push({ day, patch: JSON.stringify(patch), ...many({ schedule: [{ day, patch }] }, SEEDS5) });
  }
  return out;
};

// ---- q5: the proceeds split
batches.q5 = () => {
  const out = {};
  for (const v of ['comparable', 'sustained17', 'sustained50']) out[v] = sweep('saleToBuybackBps', [0, 2500, 5000, 7500, 10000], { volPreset: v }, SEEDS5);
  return out;
};

// ---- q6: the stepped bid rule: drop per credit, drop floor, climb per minute, ceiling, idle loosening, clamp, and the hourly cap
batches.q6 = () => {
  const out = { base: many({}, SEEDS5), sweeps: {} };
  const S = out.sweeps;
  S.dropPerCreditPct = sweep('dropPerCreditPct', [0.25, 0.5, 1, 2], {}, SEEDS5);
  S.dropToPct = sweep('dropToPct', [50, 80, 95], {}, SEEDS5);
  S.climbPerMin = sweep('climbPerMin', [0.25, 0.5, 1, 2], {}, SEEDS5);
  S.ceilPct = sweep('ceilPct', [110, 125, 150, 200], {}, SEEDS5);
  S.idleLoosenPct = sweep('idleLoosenPct', [0, 1, 2, 5], {}, SEEDS5);
  // hard cases: a low opening limit in a recovering market and a declining market
  const hard = { rateStart: rateAt(0.4), pricePath: 'recovery' }, dec = { pricePath: 'decline' };
  const pick = { dropPerCreditPct: [0.25, 0.5, 2], climbPerMin: [0.25, 0.5, 2], ceilPct: [110, 125, 200] };
  out.hardRecovery = {}; out.decline = {};
  for (const [k, vals] of Object.entries(pick)) { out.hardRecovery[k] = sweep(k, vals, hard); out.decline[k] = sweep(k, vals, dec); }
  return out;
};

// ---- q7: after the launch pot, per day as a function of daily coin volume (constant volume after day one)
batches.q7 = () => {
  const out = { volume: [], stmtDemand: [], wtp: [] };
  for (const v of [1, 5, 17, 50, 150]) {
    const o = { volPreset: 'custom', volTail: v, volHalfLifeDays: 2 };
    out.volume.push(Object.assign({ ethPerDay: v, feesPerDay: v * 0.0587 }, many(o, SEEDS5)));
    // statement demand 5 times higher, to see what the sale side can do when the buyers are there
    out.stmtDemand.push(Object.assign({ ethPerDay: v }, many(Object.assign({ stmtPerDay: 40, stmtFloorPerDay: 10 }, o), SEEDS3)));
  }
  return out;
};

// ---- q8: phase 2 arrives on day 14, 30 or 60 in hold (exitMode 1) or on (exitMode 2), for a range of exit token values per score point
batches.q8 = () => {
  const out = { grid: [], bid: [], noModule: many({}, SEEDS3) };
  const XPS = [1e-5, 2e-5, 3e-5, 5e-5, 1e-4, 2e-4]; // eth value per point; a 440 point credit redeems 440 times this
  for (const mode of [1, 2]) {
    for (const day of [14, 30, 60]) {
      for (const xpPerPoint of XPS) {
        const runs = SEEDS3.map((seed) => {
          const r = simulate({ seed, phase2Day: day, phase2ExitMode: mode, xpPerPoint, days: 90 });
          const m = metrics(r), b = r.at(day - 1 / 24), p7 = r.at(Math.min(90, day + 7)), p30 = r.at(Math.min(90, day + 30));
          return Object.assign(m, { waitBefore: b.waiting, exitedAt7: p7.exited, xPotAt7: p7.xPot, xBoughtAt7: p7.xBought, xBoughtAt30: p30.xBought, redeemBurnMovedAt30: p30.redeemBurnMoved });
        });
        out.grid.push(Object.assign({ mode, day, xpPerPoint }, mean(runs)));
      }
    }
  }
  for (const xpPerPoint of [2e-5, 1e-4]) {
    const r = simulate({ xpPerPoint, phase2Day: 14, seed: 1 });
    for (const d of [14.5, 15, 16, 18, 21, 30, 45, 60, 90]) { const a = r.at(d); out.bid.push({ xpPerPoint, day: d, xPot: a.xPot, redeemBurn: a.redeemBurn, xBought: a.xBought, exited: a.exited, burnPct: a.burnedPct }); }
  }
  // a keeper that redeems only when the exit token returned is worth at least the asking price
  out.keeper = [0, 1].map((ratio) => Object.assign({ exitMinRatio: ratio }, many({ phase2Day: 30, xpPerPoint: 3e-5, exitMinRatio: ratio }, SEEDS3)));
  return out;
};

// ---- q9: sensitivity, low and high values of each input against the base case (credits acquired and statements created at day 90)
batches.q9 = () => {
  const base = many({}, SEEDS5);
  const tests = [
    ['volScale', 0.25, 4], ['priceP0', 0.0045, 0.018], ['pricePath', 'decline', 'recovery'], ['askSigma', 0.15, 0.4], ['impactElast', 0, 0.3],
    ['offersPerHour', 60, 400], ['supplyElast', 0.5, 3], ['bookChurn', 0.02, 0.15], ['stmtPerDay', 3, 20], ['wtpMult', 0.7, 1.3],
    ['buyShareLate', 0.42, 0.52], ['rateStart', rateAt(0.25), rateAt(1.25)], ['markupBps', 10000, 20000], ['fastDecayBpsPerHour', 50, 400], ['floor, both floors', { floorBps: 5000, saleFloorBps: 5000 }, { floorBps: 7500, saleFloorBps: 7500 }],
    ['feeToBuybackBps', 0, 2500], ['buyerWaits', 'no', 'floor'],
    ['saleToBuybackBps', 0, 10000], ['dropPerCreditPct', 0.25, 2], ['climbPerMin', 0.25, 2], ['ceilPct', 110, 200], ['idleLoosenPct', 0, 5],
    ['listedShare', 0, 0.5], ['sniperVolShare', 0.2, 0.6], ['h1Share', 0.45, 0.7], ['feeToRedeemBurnBps', 0, 2500], ['stmtPick', 'cheapest', 'random'],
  ];
  const out = { base, rows: [] };
  for (const [k, lo, hi] of tests) {
    const ov = (v) => (v && typeof v === 'object' ? v : { [k]: v });
    const a = many(ov(lo), SEEDS3), b = many(ov(hi), SEEDS3);
    const pick = (m) => ({ salePct90: m.salePct90, credits90: m.credits90, stmts90: m.stmts90, sold90: m.sold90, burnEth90: m.burnEth90, burnPct90: m.burnPct90, waiting90: m.waiting90, costVsMarket: m.costVsMarket, credits7: m.credits7, steadyCredits: m.steadyCredits });
    out.rows.push({ key: k, lo: JSON.stringify(lo), hi: JSON.stringify(hi), loRes: pick(a), hiRes: pick(b) });
  }
  return out;
};

// ---- q11: does the sale design result hold when buyers pick any statement that fits instead of the one with the lowest asking price
batches.q11 = () => {
  const out = { base: designRows({ stmtPick: 'random' }, SEEDS5) };
  return out;
};

// ---- q10: named scenarios (the page presets) and the owner adapts later cases, three volume presets
export const COMBOS = {
  asLaunched: {},
  floor6000at14: { schedule: [{ day: 14, patch: { floorBps: 6000, saleFloorBps: 6000 } }] },
  floor6000: { floorBps: 6000, saleFloorBps: 6000 },
  floor5000: { floorBps: 5000, saleFloorBps: 5000 },
  fee2500: { feeToBuybackBps: 2500 },
  markup13000: { markupBps: 13000 },
  waitFloor: { buyerWaits: 'floor' },
  split0: { saleToBuybackBps: 0 },
  split10000: { saleToBuybackBps: 10000 },
  open50: { rateStart: rateAt(0.5) },
  open75: { rateStart: rateAt(0.75) },
  drop2pct: { dropPerCreditPct: 2 },
};
batches.q10 = () => {
  const out = {};
  for (const [name, o] of Object.entries(COMBOS)) {
    out[name] = { comparable: many(o, SEEDS5), sustained17: many(Object.assign({ volPreset: 'sustained17' }, o), SEEDS3), deadWeek1: many(Object.assign({ volPreset: 'deadWeek1' }, o), SEEDS3) };
  }
  return out;
};

if (process.argv[1] && process.argv[1].endsWith('run.mjs')) {
  const want = process.argv.slice(2);
  for (const name of want.length ? want : Object.keys(batches)) {
    const t = Date.now();
    write(name, batches[name]());
    console.log(name, ((Date.now() - t) / 1000).toFixed(1) + 's');
  }
}
