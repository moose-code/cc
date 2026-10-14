// headline run. usage: node sim/run.mjs [q1]. writes sim/results/q1.json: the mean over five seeds per volume preset at 1, 3, 7, 14, 30, 60
// and 90 days, and the daily series of seed 1
import fs from 'node:fs';
import { simulate, summary, WTP_Q, interp } from './engine.js';

const OUT = new URL('./results/', import.meta.url).pathname;
fs.mkdirSync(OUT, { recursive: true });
const SEEDS5 = [1, 2, 3, 4, 5];
const PRESETS = ['comparable', 'sustained17', 'sustained50', 'deadWeek1'];

// flat numeric metrics of one run
export function metrics(res) {
  const m = {}, S = res.S, T = res.T, st = res.stats, H = res.H;
  for (const d of [1, 3, 7, 14, 30, 60, 90]) {
    if (d * 24 > H) continue;
    const a = summary(res, d);
    Object.assign(m, {
      ['credits' + d]: a.credits, ['stmts' + d]: a.statements, ['sold' + d]: a.sold, ['burnEth' + d]: a.burnEth, ['burnPct' + d]: a.burnPct,
      ['waiting' + d]: a.waiting, ['redeemed' + d]: a.redeemed, ['locked' + d]: a.locked, ['pot' + d]: a.pot, ['recycled' + d]: a.recycled,
      ['salePct' + d]: a.avgSalePct, ['saleToBurn' + d]: a.saleToBurn,
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
    balancePotEnd: res.core.balancePot, redeemBurnEnd: res.core.ethRedeemBurn, redeemBurnMoved: res.core.redeemBurnMoved, potEnd: res.core.ethPot, toBuybackEnd: res.core.ethToBuyback,
    royaltyOwedEnd: res.core.royaltyOwed, payeeOwedEnd: res.core.payeeOwed,
    recycledRatio: T.spent ? T.saleGross / T.spent : 0, fees: S.cumFees[H], saleToPot: T.saleToPot, saleToBuyback: T.saleToBuyback,
    f80hours: st.first80 ? st.first80.hours : NaN, f80ratio: st.first80 ? st.first80.ratio : NaN, f80score: st.first80 ? st.first80.avgScore : NaN,
    redeemedValue: T.redeemedValue, redeemedCost: T.redeemedCost, redeemedValueOverCost: T.redeemedCost ? T.redeemedValue / T.redeemedCost : NaN,
    redeemedAgeDays: T.redeemed ? T.redeemedAge / T.redeemed / 86400 : NaN, xRecv: T.xRecv, stratBought: T.stratBought,
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
export function many(over, seeds = SEEDS5) {
  return mean(seeds.map((s) => metrics(simulate(Object.assign({}, over, { seed: s })))));
}
// share of statement buyers whose willingness to pay multiple is at least x
export function wtpSurvival(x) {
  let lo = 0, hi = 1;
  for (let i = 0; i < 60; i++) { const mid = (lo + hi) / 2; if (interp(WTP_Q, mid) < x) lo = mid; else hi = mid; }
  return 1 - lo;
}
const r3 = (x) => (x == null || !Number.isFinite(x) ? x : +Number(x).toPrecision(4));
const round = (o) => JSON.parse(JSON.stringify(o, (k, v) => (typeof v === 'number' ? r3(v) : v)));
const write = (name, data) => { fs.writeFileSync(OUT + name + '.json', JSON.stringify(round(data), null, 1)); console.log('wrote', name); };

const batches = {};
// q1: the launch configuration as built, 30 60 90 days under each volume preset
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

if (process.argv[1] && process.argv[1].endsWith('run.mjs')) {
  const want = process.argv.slice(2);
  for (const name of want.length ? want : Object.keys(batches)) {
    const t = Date.now();
    write(name, batches[name]());
    console.log(name, ((Date.now() - t) / 1000).toFixed(1) + 's');
  }
}
