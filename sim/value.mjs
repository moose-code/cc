// value-referenced pricing study (design validation, docs/reviews/DESIGN-value-pricing-f1101cb.md).
// usage: node sim/value.mjs [out.json]
// the shared percentage bid is the shipped shared instance of engine.js (CoreLib's second Rate instance, value mode's eth
// price state): a rate in bps of par, floor 10000 - balanceBidMarginBps, cap balanceBidCapBps, the shared climb, recovery
// climb, drop and peak, driven here through sharedRate and sharedFill. the balance bid itself is posted (decision 164).
// par of a credit is score * V where V is the eth value of one point. nothing here changes the shipped rules; only the
// cap, the climb and the drop vary, and the budget, the sale floor and the attacker are modelled on top.
import fs from 'node:fs';
import { Core, BPS, DEFAULTS, W, REF_PTS, RATE_SCORE, mulberry32, normal, poisson } from './engine.js';

const BLOCK = 12, V = DEFAULTS.rateStart / W / 100; // eth per point: the launch rate is wei per 100 points (decision 145), 0.0577 eth per 1,000 points
const CENSUS = [152, 224, 296, 368, 440, 512, 584, 656, 728]; // decile points of the credit score census (sim/grid.mjs)
const SEED = 147;

// a Core whose balance bid instance is the shared percentage bid. the module holding is set far above any fill so the
// available() clamp never lowers the read: the budget below is the only capacity limit, as the design asks
function makeBid(cell) {
  const p = {
    ...DEFAULTS, balanceBidMarginBps: BPS - cell.floor, balanceBidCapBps: cell.cap, balanceBidOn: true, redeemOn: true,
    climbPerMin: cell.climb / 100, recoveryClimbPerMin: Math.max(cell.climb, cell.rec ?? cell.climb) / 100, dropPerCreditPct: cell.drop / 100, // drop per 100 points (decision 145)
  };
  const core = new Core(p, 0);
  core.setBalanceModule(0, V);
  core.balancePot = 1e9;
  return core;
}
const pct = (core, t) => core.sharedRate(t) / 100; // the shared bid now, percent of par

// the combined acquisition budget: an allowance in eth value that refills at `ratePerMin` of the capital per minute up to
// `capFrac` of the capital. a purchase passes when it fits, or when the allowance is full (one otherwise admissible credit
// always clears, charged in full). `bucket` instead models the shipped rule: a 60 s bucket of 1 percent of the capital whose
// first purchase always passes
class Budget {
  constructor(capital, ratePerMin, capFrac, bucket) {
    this.k = capital; this.rate = ratePerMin; this.capFrac = capFrac; this.bucket = bucket;
    this.allow = capital * capFrac; this.t = 0; this.bucketId = -1; this.spent = 0;
  }
  // the capital falls with every purchase, as the pot does
  take(cost, now) {
    if (cost > this.k) return false;
    if (this.bucket) {
      const id = Math.floor(now / 60);
      if (id !== this.bucketId) { this.bucketId = id; this.spent = 0; this.snap = this.k; }
      if (this.spent !== 0 && this.spent + cost > this.snap * this.rate) return false;
      this.spent += cost; this.k -= cost;
      return true;
    }
    this.allow = Math.min(this.k * this.capFrac, this.allow + this.k * this.rate * (now - this.t) / 60); this.t = now;
    if (cost <= this.allow) { this.allow -= cost; this.k -= cost; return true; }
    if (this.allow >= this.k * this.capFrac - 1e-12) { this.allow = 0; this.k -= cost; return true; }
    return false;
  }
}

// (a) organic sellers: Poisson arrivals, a reservation in percent of par, lognormal around `mean` with sigma `sigma`, two
// hours of patience. a seller takes the bid the first block it covers the reservation; the fill drops the bid
function runOrganic(cell, lam, mean, sigma, hours = 24) {
  const rng = mulberry32(SEED), core = makeBid(cell), budget = new Budget(10, 0.01, 0.05, false);
  // the capital is held at 10 eth so the run measures the bid rule, not the pot running dry
  const queue = [];
  let fills = 0, pts = 0, paidPts = 0, prem = 0, lost = 0, bidSum = 0, bidN = 0, atCap = 0, premPts = 0;
  for (let t = 0; t < hours * 3600; t += BLOCK) {
    budget.k = 10;
    const n = poisson(rng, lam * BLOCK / 3600);
    for (let i = 0; i < n; i++) queue.push({ pts: CENSUS[Math.floor(rng() * CENSUS.length)], r: mean * Math.exp(sigma * normal(rng)) * 100, t0: t });
    for (let i = 0; i < queue.length;) {
      const q = queue[i];
      if (t - q.t0 > 7200) { lost++; queue.splice(i, 1); continue; }
      const b = pct(core, t);
      if (b >= q.r) {
        const cost = (q.pts * V * b) / 100;
        if (!budget.take(cost, t)) break;
        const paid = core.sharedFill(q.pts, t);
        if (!(paid > 0)) break;
        fills++; pts += q.pts; paidPts += paid / V; prem += Math.max(0, paid / V - q.pts); if (paid / V > q.pts) premPts += q.pts;
        queue.splice(i, 1); continue;
      }
      i++;
    }
    const b = pct(core, t); bidSum += b; bidN++; if (b >= cell.cap / 100 - 1e-9) atCap++;
  }
  return { fillsPerHour: fills / hours, meanPaidPct: pts ? (100 * paidPts) / pts : null, premiumLossPct: pts ? (100 * prem) / pts : null, sharePtsAbovePar: pts ? premPts / pts : null, timeMeanBidPct: bidSum / bidN, timeShareAtCap: atCap / bidN, lost };
}

// (b) a dump: `count` credits whose holders take the floor, offered in a fixed order every block until each is bought.
// compares the shipped bucket rule with the accumulating allowance, both at 1 percent a minute of a 10 eth capital that
// falls with every purchase. reports absorption time and the mean percent paid
function runDump(cell, count, bucket) {
  const rng = mulberry32(SEED + 1), core = makeBid(cell), budget = new Budget(10, 0.01, 0.05, bucket);
  const inv = Array.from({ length: count }, () => CENSUS[Math.floor(rng() * CENSUS.length)]);
  let i = 0, pts = 0, paidPts = 0, done = null;
  for (let t = 0; t < 48 * 3600 && i < count; t += BLOCK) {
    for (;;) {
      const p = inv[i], b = pct(core, t);
      if (!budget.take((p * V * b) / 100, t)) break;
      const paid = core.sharedFill(p, t);
      if (!(paid > 0)) break;
      pts += p; paidPts += paid / V; if (++i === count) { done = t; break; }
    }
  }
  return { minutes: done === null ? null : done / 60, meanPaidPct: pts ? (100 * paidPts) / pts : null, ethSpent: paidPts * V, conversionGainEth: (pts - paidPts) * V, left: count - i, capitalLeft: budget.k };
}

// the organic and dump cells use the launch drop of 115 bps per 100 points (about 500 per 433 point credit)
// (c) the return loop: an attacker buys engine inventory at the protected floor while the bid is low and sells it back once the
// bid has climbed to the cap. floor rule `current`: max(1, (1 + s) * bid now); rule `ceiling`: (1 + s) * cap. one refScore
// credit per cycle, the cycle the time the climb needs from the post-drop rate back to the cap; capped by the 1 percent a
// minute budget. returns the attacker's gain per hour as a percent of a 10 eth capital
function loopGain(cell, s, rule) {
  const core = makeBid(cell);
  const cap = cell.cap / BPS;
  // the attacker first dumps credits to push the bid to the floor (paid for them at the bid, not counted here)
  let t = 0;
  for (let i = 0; i < 20 && pct(core, t) > cell.floor / 100 + 1e-9; i++) core.sharedFill(REF_PTS, t);
  const bidLow = pct(core, t) / 100;
  const floor = rule === 'ceiling' ? (1 + s) * cap : Math.max(1, (1 + s) * bidLow);
  // time for the bid to climb from the post-drop level back to the cap, measured on the instance
  core.sharedFill(REF_PTS, t); // leave the bid one drop under the cap
  let t1 = t;
  while (pct(core, t1) < cell.cap / 100 - 1e-9 && t1 < 7 * 86400) t1 += 1;
  // climb from the floor to the cap
  const core2 = makeBid(cell);
  let t2 = 0;
  while (pct(core2, t2) < cell.cap / 100 - 1e-9 && t2 < 7 * 86400) t2 += 1;
  const cycleSec = Math.max(t1 - t, BLOCK);
  const gainPerCredit = (cap - floor) * REF_PTS * V; // eth per refScore credit
  const perHourByClimb = 3600 / cycleSec, perHourByBudget = (10 * 0.01 * 60) / (cap * REF_PTS * V); // the budget refills at 1 percent of 10 eth a minute
  const perHour = Math.min(perHourByClimb, perHourByBudget);
  return { bidLowPct: bidLow * 100, floorPct: floor * 100, gainPerCreditPct: (cap - floor) * 100, cycleMin: cycleSec / 60, floorToCapMin: t2 / 60, creditsPerHour: perHour, gainPerHourPctOfCapital: (100 * Math.max(0, gainPerCredit) * perHour) / 10 };
}

// (d) a manipulated reference: a price held `k` above the true value for `minutes` lets the engine overpay by k / (1 + k) of
// every eth it spends; the 1 percent a minute budget bounds the spend. a price held `k` below lets every held statement and
// aged credit sell k under value: the inventory bounds that loss, not the budget
function manipulation(k, minutes, capital, inventoryEth) {
  const spend = Math.min(capital, capital * 0.01 * minutes);
  return { k, minutes, capital, inventoryEth, buyLossEth: (spend * k) / (1 + k), buyLossPctOfCapital: (100 * (spend * k) / (1 + k)) / capital, saleLossEth: inventoryEth * k };
}

// (e) the pot after a sale at `mult` times the conversion value of a credit bought at `bid` times that value: artist 2.5 and
// operator 0.5 percent off the top, 25 percent of the rest to the buyback, 75 percent to the pot
function saleSplit(mult, bid) {
  const cuts = 0.03, rest = mult * (1 - cuts), toBuyback = 0.25 * rest, toPot = 0.75 * rest;
  const surplus = rest - bid;
  return { mult, bid, toPot, toBuyback, potChange: toPot - bid, burnFromPrincipal: Math.max(0, toBuyback - Math.max(0, surplus)), breakEvenMult: bid / (0.75 * (1 - cuts)) };
}

// (f) keeper payments and the processing reserve at a base fee, from the launch settings: compose about 8.5 million gas,
// redeem about 500 thousand, each paid gas times min(base fee, 3 gwei) plus 0.0003 eth
function processing(gwei) {
  const g = Math.min(gwei, 3) * 1e-9, compose = 8.5e6 * g + 0.0003, redeem = 5e5 * g + 0.0003;
  return { gwei, composeEth: compose, redeemEth: redeem, pageEth: compose + redeem, pagesPer0_1Eth: 0.1 / (compose + redeem) };
}

// (g) a patient seller against the shipped eth bid (the temporary phase): credits bought on the market at `PE`, sold in bursts
// of `k` refScore credits only when the bid has climbed to within 2 percent of the ceiling it can reach now (the ceiling of
// the last fill, loosened while idle, at most rateCap) and above the market; between bursts the seller waits. nobody else
// sells, which is the quiet market the loosening was designed for. the budget is the shipped bucket, the pot 10 eth
function runPatient(patch, PE, k = 5, hours = 24, pot = 10) {
  const p = { ...DEFAULTS, ...patch };
  const core = new Core(p, 0);
  core.fund(pot, 0);
  let spent = 0, n = 0, spent6 = 0, n6 = 0, first = null;
  for (let t = 0; t <= hours * 3600; t += BLOCK) {
    if (t === 6 * 3600) { spent6 = spent; n6 = n; }
    const r = (core.ethRate(t) / W) * REF_PTS / 100, ceil = (Math.min(core.stepCeil(t), p.rateCap) / W) * REF_PTS / 100; // per 433 point credit
    if (r < 0.98 * ceil || r <= PE) continue;
    for (let i = 0; i < k; i++) { const paid = core.sellForEth(t, REF_PTS); if (!(paid > 0)) break; spent += paid; n++; if (first === null) first = t; }
  }
  if (hours <= 6) { spent6 = spent; n6 = n; }
  return { firstSaleMin: first === null ? null : first / 60, eth6h: spent6, credits6h: n6, overpay6h: spent6 - n6 * PE, eth24h: spent, credits24h: n, overpay24h: spent - n * PE, potLeft: core.ethPot };
}

const f = (x, d = 2) => (x == null ? '-' : (+x).toFixed(d));
export function run() {
  const out = { assumptions: { blockSeconds: BLOCK, refPoints: REF_PTS, ethPerPoint: V, census: CENSUS, seed: SEED, capitalEth: 10, budgetPerMin: 0.01, budgetCap: 0.05, patienceSec: 7200 }, organic: [], dump: [], loop: [], manipulation: [], split: [], processing: [] };
  const caps = [10000, 10500, 11000], climbs = [200, 50, 20, 10], lams = [3, 12, 48], means = [1.0, 0.95];
  for (const cap of caps) for (const climb of climbs) for (const lam of lams) for (const mean of means) {
    const cell = { floor: 9000, cap, climb, drop: 115 };
    out.organic.push({ cell, lam, mean, ...runOrganic(cell, lam, mean, 0.08) });
  }
  for (const cap of caps) for (const climb of [200, 20]) for (const bucket of [true, false]) {
    const cell = { floor: 9000, cap, climb, drop: 115 };
    out.dump.push({ cell, rule: bucket ? 'bucket 60 s, first passes' : 'allowance 1 pct a minute, cap 5 pct', ...runDump(cell, 300, bucket) });
  }
  for (const cap of caps) for (const climb of [200, 20]) for (const s of [0.02, 0.05, 0.1]) for (const rule of ['current', 'ceiling']) {
    const cell = { floor: 9000, cap, climb, drop: 115 };
    out.loop.push({ cell, spread: s, rule, ...loopGain(cell, s, rule) });
  }
  for (const k of [0.03, 0.05, 0.1, 0.3]) for (const minutes of [5, 30, 60, 1440]) for (const capital of [10, 100]) out.manipulation.push(manipulation(k, minutes, capital, capital));
  for (const bid of [0.9, 1.0, 1.05]) for (const mult of [1.0, 1.05, 1.1025, 1.5, 1.654]) out.split.push(saleSplit(mult, bid));
  for (const gwei of [0.5, 1, 3, 5, 10]) out.processing.push(processing(gwei));
  out.patient = [];
  // the launch config of decision 146: no minute floor, spend cap off; the opening is 0.025 eth per 433 point credit
  for (const PE of [0.005, 0.025]) for (const climb of [200, 50, 20]) for (const capX of [3, 1.5, 1.2]) for (const loosen of ['shipped', 'none']) {
    const patch = { climbPerMin: climb / 100, recoveryClimbPerMin: climb / 100, rateCap: capX * DEFAULTS.rateStart };
    if (loosen === 'none') Object.assign(patch, { idleLoosenPct: 0.0001, climbMultiplierCapBps: 10000 });
    out.patient.push({ marketEth: PE, climb, rateCapX: capX, loosening: loosen, ...runPatient(patch, PE) });
  }
  return out;
}

export function tables(o) {
  const t = [];
  t.push('## organic sellers, 24 h, reservation lognormal sigma 8 percent, 10 eth capital, budget 1 percent a minute');
  t.push('| cap | climb bps/min | sellers/h | reservation mean | fills/h | mean paid % | premium loss % of par bought | share of points above par | time mean bid % | time at cap | sellers lost |');
  t.push('|---|---|---|---|---|---|---|---|---|---|---|');
  for (const r of o.organic) t.push(`| ${r.cell.cap / 100} | ${r.cell.climb} | ${r.lam} | ${r.mean} | ${f(r.fillsPerHour, 1)} | ${f(r.meanPaidPct, 1)} | ${f(r.premiumLossPct, 2)} | ${f(r.sharePtsAbovePar, 2)} | ${f(r.timeMeanBidPct, 1)} | ${f(r.timeShareAtCap, 2)} | ${r.lost} |`);
  t.push('\n## a 300 credit dump at the floor, 10 eth capital that falls with every purchase');
  t.push('| cap | climb | budget rule | minutes to absorb | mean paid % | eth spent | conversion gain eth | left | capital left |');
  t.push('|---|---|---|---|---|---|---|---|---|');
  for (const r of o.dump) t.push(`| ${r.cell.cap / 100} | ${r.cell.climb} | ${r.rule} | ${f(r.minutes, 0)} | ${f(r.meanPaidPct, 1)} | ${f(r.ethSpent, 2)} | ${f(r.conversionGainEth, 2)} | ${r.left} | ${f(r.capitalLeft, 2)} |`);
  t.push('\n## the return loop: buy at the protected floor, sell back at the cap');
  t.push('| cap | climb | spread | floor rule | bid after dump % | floor % | gain per credit % | cycle min | floor to cap min | credits/h | attacker gain % of capital per hour |');
  t.push('|---|---|---|---|---|---|---|---|---|---|---|');
  for (const r of o.loop) t.push(`| ${r.cell.cap / 100} | ${r.cell.climb} | ${r.spread} | ${r.rule} | ${f(r.bidLowPct, 1)} | ${f(r.floorPct, 2)} | ${f(r.gainPerCreditPct, 2)} | ${f(r.cycleMin, 1)} | ${f(r.floorToCapMin, 1)} | ${f(r.creditsPerHour, 1)} | ${f(r.gainPerHourPctOfCapital, 2)} |`);
  t.push('\n## a manipulated reference, inventory marked at the capital');
  t.push('| k | minutes held | capital eth | buy loss eth | buy loss % of capital | sale loss eth on inventory equal to the capital |');
  t.push('|---|---|---|---|---|---|');
  for (const r of o.manipulation) t.push(`| ${r.k} | ${r.minutes} | ${r.capital} | ${f(r.buyLossEth, 3)} | ${f(r.buyLossPctOfCapital, 2)} | ${f(r.saleLossEth, 2)} |`);
  t.push('\n## a sale at a multiple of conversion value, 25 percent of the net to the buyback');
  t.push('| bid paid | sale multiple | to pot | to buyback | pot change | burn paid from principal | break even multiple for the pot |');
  t.push('|---|---|---|---|---|---|---|');
  for (const r of o.split) t.push(`| ${r.bid} | ${r.mult} | ${f(r.toPot, 3)} | ${f(r.toBuyback, 3)} | ${f(r.potChange, 3)} | ${f(r.burnFromPrincipal, 3)} | ${f(r.breakEvenMult, 3)} |`);
  t.push('\n## a patient seller against the shipped eth bid: bursts of 5 refScore credits at the reachable ceiling, 10 eth pot, nobody else sells');
  t.push('| market eth | climb bps/min | rateCap x open | loosening | first sale min | 6 h eth | 6 h credits | 6 h overpay | 24 h eth | 24 h credits | 24 h overpay | pot left |');
  t.push('|---|---|---|---|---|---|---|---|---|---|---|---|');
  for (const r of o.patient) t.push(`| ${r.marketEth} | ${r.climb} | ${r.rateCapX} | ${r.loosening} | ${f(r.firstSaleMin, 0)} | ${f(r.eth6h)} | ${r.credits6h} | ${f(r.overpay6h)} | ${f(r.eth24h)} | ${r.credits24h} | ${f(r.overpay24h)} | ${f(r.potLeft)} |`);
  t.push('\n## processing payments at launch settings (3 gwei ceiling, 0.0003 eth fee)');
  t.push('| base fee gwei | compose eth | redeem eth | per page eth | pages a 0.1 eth reserve processes |');
  t.push('|---|---|---|---|---|');
  for (const r of o.processing) t.push(`| ${r.gwei} | ${f(r.composeEth, 4)} | ${f(r.redeemEth, 4)} | ${f(r.pageEth, 4)} | ${f(r.pagesPer0_1Eth, 1)} |`);
  return t.join('\n');
}

if (process.argv[1] && process.argv[1].endsWith('value.mjs')) {
  const t0 = Date.now(), o = run();
  o.assumptions.runSeconds = (Date.now() - t0) / 1000;
  if (process.argv[2]) fs.writeFileSync(process.argv[2], JSON.stringify(o, null, 1));
  console.log(tables(o));
  console.error(`${o.organic.length + o.dump.length + o.loop.length} runs in ${o.assumptions.runSeconds.toFixed(1)} s`);
}
