// the engine bid against the real OpenSea and CreditStrategy board over 30 days, under decision 128.
// usage: node sim/market.mjs. prints the launch-settings table, writes sim/out/market.json and sim/out/market.md.
// the Core, the drop, the climb, the multiplier and the hourly bound, the compose and the sale come from engine.js; this file
// is a fresh minute-step loop because the board is the real listings (sim/data), not engine.js's synthetic book.
import fs from 'node:fs';
import { Core, W, BPS, RATE_SCORE, DEFAULTS, mulberry32, normal, poisson, interp, WTP_Q, stmtArrivalsPerDay } from './engine.js';

const DATA = new URL('./data/', import.meta.url).pathname;
const OUT = new URL('./out/', import.meta.url).pathname;
const rd = (f) => JSON.parse(fs.readFileSync(DATA + f, 'utf8'));

// ---- the real board (market model 1). score of an id in points = bidOf / ethRate * (REF_PTS / 1e4), the inverse of the
// per-credit bid at the time of the board read, when the reference credit was 433 points (4,330,000 score units; the
// rate was wei per such a credit, decision 145 made it wei per 100 points). the live state below is in the same units
const REF_PTS = 4330000;
const BOARD_RAW = rd('board_raw.json').listings;
const READS = rd('reads_board.json');
const STRAT_READS = rd('strategy_reads.json');
const SUMMARY = rd('summary.json');
const ER = READS.ethRate; // 0.0169 eth, the rate the scores were read at
const scoreOf = new Map();
READS.ids.forEach((id, i) => scoreOf.set(String(id), (READS.bid[i] / ER) * (REF_PTS / 1e4)));
// the census deciles fill the score of a listing with no on-chain read (4 percent of the board)
const CEN = Object.values(SUMMARY.score_distribution_points.all_credits_ever_minted_122154_full_census.deciles);
const censusScore = (rng) => CEN[Math.min(CEN.length - 1, Math.floor(rng() * CEN.length))];
// the live engine state (task): pot 6.556 eth, rate 0.0169 eth, pile 9
const POT0 = 6.556, RATE0 = 0.0169 * W, PILE0 = 9;
const PE = 0.0089; // the current flat market price of a credit, eth (notes.md, last 24h median). score does not price the market

// one fresh board for a run: OpenSea listings and CreditStrategy listings, each {ask eth, pts, need eth}. need = ask / scoreRatio,
// the eth per 100 points the rate must reach for this listing to clear. junk asks (over 100 eth) stay in the board and never clear
function buildBoard(rng) {
  const sr = (pts) => (pts * 1e4) / RATE_SCORE; // score over 100 points: the rate is wei per 100 points
  const book = [], strat = [];
  for (const l of BOARD_RAW) {
    const pts = scoreOf.get(String(l.id)) || censusScore(rng);
    const ask = Number(l.price) / 1e18;
    if (!(pts > 0) || !(ask > 0)) continue;
    book.push({ ask, pts, need: ask / sr(pts) });
  }
  for (const id of Object.keys(STRAT_READS.price)) {
    const b = STRAT_READS.bid[id];
    if (!b) continue;
    const pts = (b / ER) * (REF_PTS / 1e4), ask = Number(STRAT_READS.price[id]) / 1e18;
    if (!(pts > 0) || !(ask > 0)) continue;
    strat.push({ ask, pts, need: ask / sr(pts) });
  }
  book.sort((a, b) => b.need - a.need); // descending: the cheapest to clear is last, popped first
  strat.sort((a, b) => b.need - a.need);
  return { book, strat };
}
// the board's median ask per point over both venues, eth per point (the yardstick for the paid price per point)
const BOARD_MED_PP = (() => {
  const pp = [];
  const { book, strat } = buildBoard(mulberry32(1));
  for (const it of book.concat(strat)) if (it.ask <= 100) pp.push(it.ask / it.pts);
  pp.sort((a, b) => a - b);
  return pp[Math.floor(pp.length / 2)];
})();

// ---- the fee path (market model 4). day-one volume by path, decaying 5 percent a day; dead week and the pump edit it per scenario
const VOL_DAY0 = { low: 20, base: 100, high: 500 };
function dayVolume(path, d, scenario) {
  if (scenario === 'deadWeek' && d >= 7 && d < 14) return 0; // days 8 to 14 (0-indexed 7..13)
  return VOL_DAY0[path] * Math.pow(0.95, d);
}
const FEE_TO_CORE = 0.0621; // 90 percent of the 6.9 percent baseline skim reaches the Core; _book then splits it

const sr = (pts) => (pts * 1e4) / RATE_SCORE; // score over 100 points: the rate is wei per 100 points

// ---- one run
export function runMarket(o) {
  const rng = mulberry32(o.seed);
  const p = Object.assign({}, DEFAULTS, {
    // RATE0 is the live rate per reference credit of REF_PTS; the rate is wei per 100 points
    rateStart: (RATE0 * RATE_SCORE) / REF_PTS, rateCap: (3 * RATE0 * RATE_SCORE) / REF_PTS, days: 30, stepSec: 60,
    climbPerMin: o.climbPerMin, recoveryClimbPerMin: o.recoveryClimbPerMin ?? DEFAULTS.recoveryClimbPerMin, idleLoosenPct: o.idleLoosenPct,
    multiplierCap: o.multiplierCap, hourlyBound: o.hourlyBound,
  });
  const core = new Core(p, 0);
  core.payeeOn = true; // the sim starts three weeks past launch, the anti sniper latch is long closed
  core.fund(POT0, 0);
  const pile = [];
  for (let i = 0; i < PILE0; i++) pile.push({ pts: 440, cost: RATE0 / W, t0: -p.creditWindow - 1 }); // the 9 held credits, past their window
  const { book, strat } = buildBoard(rng);
  const coinPrice = 1.335e-7; // eth per coin now (strategy.csv last row), the buyback burn price. the coin price is held flat

  const T = { bought: 0, spent: 0, pts: 0, composed: 0, sold: 0, saleGross: 0, creditSold: 0, burned: 0, worstPP: 0, firstComposeT: -1 };
  let unbid = [], nextSid = 1;
  // the pump attacker (market model, pump scenario): 50 eth swapped on day 2, then 200 credits sold into the risen bid
  const atk = { armed: o.scenario === 'pump', left: 200, revenue: 0, acq: 200 * PE, fee: 50 * 0.069, sold: 0 };
  // the whale dump (day 5): 2000 listings release over one hour with their ask cut to the bid
  let dumpQueue = null;
  const DAY = 86400, MIN = 60, STEPS = p.days * DAY / MIN;
  let lastBuyback = -1e12;

  function engineBuys(t) {
    for (let guard = 0; guard < 300000; guard++) {
      const r = core.ethRate(t), afford = core.ethPot;
      if (afford <= 1e-12) break;
      const bl = book.length ? book[book.length - 1] : null, sl = strat.length ? strat[strat.length - 1] : null;
      let arr, it;
      if (bl && (!sl || bl.need <= sl.need)) { arr = book; it = bl; } else if (sl) { arr = strat; it = sl; } else break;
      if (it.need > r / W) break; // the cheapest listing is above the bid
      const ethCost = (r / W) * sr(it.pts);
      if (it.ask > afford || it.ask > ethCost) break;
      const res = core.buyListing(it.ask, t, it.pts);
      if (!res) break;
      arr.pop();
      const paid = res.cost + res.paid;
      T.bought++; T.spent += paid; T.pts += it.pts;
      T.worstPP = Math.max(T.worstPP, paid / it.pts);
      pile.push({ pts: it.pts, cost: paid, t0: t });
    }
  }
  function creditBuyers(t) {
    if (!core.cr.creditSaleOn || !pile.length) return;
    const n = poisson(rng, (p.creditBuyersPerDay * MIN) / DAY);
    for (let i = 0; i < n; i++) {
      const wtp = PE * Math.exp(p.askSigma * normal(rng));
      let best = -1, bp = Infinity;
      for (let j = 0; j < pile.length; j++) { if (pile[j].t0 > t) break; const pr = core.creditPrice(pile[j], t); if (pr < bp) { bp = pr; best = j; } }
      if (best < 0 || bp > wtp) continue;
      if (core.buyCredit(pile[best], t)) { pile.splice(best, 1); T.creditSold++; }
    }
  }
  function statementBuyers(t) {
    const n = poisson(rng, (stmtArrivalsPerDay(p, t) * MIN) / DAY);
    for (let i = 0; i < n; i++) {
      const wtp = interp(WTP_Q, rng()) * p.PAGE * PE;
      let pick = null, pm = Infinity;
      for (const st of unbid) { const a = core.askingPrice(st, t); if (a <= wtp && a < pm) { pm = a; pick = st; } }
      if (!pick) continue;
      if (core.buy(pick, t)) { unbid.splice(unbid.indexOf(pick), 1); T.sold++; T.saleGross += pm; }
    }
  }
  function composeAll(t) {
    for (;;) {
      let ready = 0;
      while (ready < pile.length && core.pastWindow(pile[ready].t0, t)) ready++;
      if (ready < p.PAGE) break;
      const page = pile.splice(0, p.PAGE);
      let cost = 0, rating = 0;
      for (const c of page) { cost += c.cost; rating += c.pts; }
      const st = core.compose(cost, t, rating); st.id = nextSid++;
      unbid.push(st); T.composed++;
      if (T.firstComposeT < 0) T.firstComposeT = t;
    }
  }
  function buybacks(t) {
    // one slice per buybackDelay blocks (300 s at launch); the swap budget buys and burns coin at the flat price
    while (core.ethToBuyback > 1e-15 && t >= lastBuyback + p.buybackDelay * 12) {
      const info = core.takeBuybackSlice(t);
      if (!info) break;
      T.burned += info.budget / coinPrice;
      lastBuyback = t;
    }
  }
  function attacker(t) {
    if (!atk.armed || atk.left <= 0) return;
    for (let k = 0; k < 10 && atk.left > 0; k++) {
      const quote = (core.ethRate(t) / W) * sr(440); // the payout for a mean-score credit at the current bid
      if (quote <= PE) break; // a rational attacker sells only while the bid beats the market price it paid
      const pay = core.sellForEth(t, 440);
      if (!(pay > 0)) break;
      atk.revenue += pay; atk.left--; atk.sold++;
    }
  }

  for (let s = 0; s <= STEPS; s++) {
    const t = s * MIN, d = Math.floor(t / DAY);
    // scenario board events
    if (o.scenario === 'drought' && t === 3 * DAY) { for (let i = book.length - 1; i >= 0; i--) if (rng() >= 0.2) book.splice(i, 1); }
    if (o.scenario === 'strat' && t === 7 * DAY) { for (const it of strat) { it.ask *= 1.5; it.need *= 1.5; } }
    if (o.scenario === 'whale') {
      if (t === 5 * DAY && !dumpQueue) {
        dumpQueue = [];
        const take = Math.min(2000, book.length);
        for (let i = 0; i < take; i++) { const j = Math.floor(rng() * book.length); const it = book.splice(j, 1)[0]; dumpQueue.push({ it, rel: 5 * DAY + Math.floor(rng() * 3600) }); }
      }
      if (dumpQueue) for (let i = dumpQueue.length - 1; i >= 0; i--) if (dumpQueue[i].rel <= t) {
        const it = dumpQueue[i].it, bid = (core.ethRate(t) / W) * sr(it.pts);
        it.ask = Math.min(it.ask, bid * 0.999); it.need = it.ask / sr(it.pts);
        book.push(it); dumpQueue.splice(i, 1);
      }
    }
    if (o.scenario === 'pump' && t === 2 * DAY) core.addFees(50 * FEE_TO_CORE, t); // the attacker's 50 eth swap pumps the pot

    // fee income for the minute
    const fee = dayVolume(o.path, d, o.scenario) * FEE_TO_CORE * (MIN / DAY);
    if (fee > 0) core.addFees(fee, t);

    engineBuys(t);
    if (atk.armed && t >= 2 * DAY) attacker(t);
    creditBuyers(t);
    statementBuyers(t);
    composeAll(t);
    buybacks(t);
  }

  const end = p.days * DAY;
  const m = {
    ethPerDay: T.spent / p.days,
    credits: T.bought,
    pricePerPointPct: T.pts ? ((T.spent / T.pts) / BOARD_MED_PP) * 100 : 0,
    worstBuyPct: (T.worstPP / BOARD_MED_PP) * 100,
    daysToFirstStatement: T.firstComposeT < 0 ? null : T.firstComposeT / DAY,
    statementsComposed: T.composed,
    statementsSold: T.sold,
    statementRevenue: T.saleGross,
    creditsSold: T.creditSold,
    potDay30: core.ethPot,
    bidDay30: core.ethRate(end) / W,
    ccBurned: T.burned,
  };
  if (o.scenario === 'pump') { m.attackerProfit = atk.revenue - atk.sold / 200 * atk.acq - atk.fee; m.attackerFee = atk.fee; m.attackerSold = atk.sold; }
  return m;
}

// ---- the grid: 6 scenarios x {climb 50/100/200, loosen 200/600/1000, cap 1/4} = 108 runs. the pump reports the attacker
const SCENARIOS = ['base', 'drought', 'whale', 'strat', 'deadWeek', 'pump'];
const CLIMB = { 50: 0.5, 100: 1, 200: 2 }, LOOSEN = { 200: 2, 600: 6, 1000: 10 };
const bound = (cap) => (cap === 4 ? 15000 : 0); // decision 128 ties the hourly bound to the multiplier: cap 1 is today, cap 4 the new rule
const SEEDS = [1, 2, 3];
const mean = (list, k) => { const v = list.map((x) => x[k]).filter((x) => Number.isFinite(x)); return v.length ? v.reduce((a, b) => a + b, 0) / v.length : null; };

function runCombo(scenario, climbBps, loosenBps, cap) {
  const rows = SEEDS.map((seed) => runMarket({ scenario, path: 'base', seed, climbPerMin: CLIMB[climbBps], idleLoosenPct: LOOSEN[loosenBps], multiplierCap: cap, hourlyBound: bound(cap) }));
  const out = {};
  for (const k of Object.keys(rows[0])) out[k] = mean(rows, k);
  return out;
}

if (!(process.argv[1] && process.argv[1].endsWith('market.mjs'))) {
  // imported: expose the pieces, run nothing
} else if (process.argv.includes('--spendcap')) console.log(JSON.stringify(runSpendCapStudy(), null, 2));
else main();

// A bounded stale-bid exposure study. Sellers use the direct bid door and receive its full score-scaled quote.
// Listing purchases pay ask plus a bounded keeper payment and can therefore spend less than this seller model.
export function runSpendCapStudy() {
  const assumptions = {
    seed: 129, initialPotEth: 10, initialReferenceBidEth: DEFAULTS.rateStart / W,
    flatAskEth: 0.005, collapseEndFraction: 0.2, collapseSeconds: 600,
    credits: 500, scoreMix: [{ points: 150, count: 50 }, { points: 300, count: 100 }, { points: 433, count: 200 }, { points: 600, count: 100 }, { points: 750, count: 50 }],
    blockSeconds: 12, sellingHorizonSeconds: 21600, totalHorizonSeconds: 86400,
    capBps: [50, 100, 200], startBucketOffsetsSeconds: [0, 48], bucketSeconds: DEFAULTS.bucketSeconds,
    feesDepositsSalesOrBalancePurchases: false,
    sellerRule: 'Seeded inventory order; each block repeatedly sells the first credit whose score-scaled bid covers its flat per-credit ask. Purchases pay the direct bid, not the ask. Stops at inventory exhaustion or selling horizon.',
    crossingRule: 'First modeled block or fill with the reference-score bid strictly below the flat ask. In the collapse case measure only at or after 600 seconds, below the final market ask; mixed-score credits can still clear after crossing.',
    recoveryRule: 'After a downward crossing, first modeled block after selling stops with the reference-score bid at least the final market ask, 0.005 ETH. Null without a crossing means N/A; null after a crossing means recovery was not observed by the total horizon.',
    arithmetic: 'Number price trajectory and integer-wei bucket accounting; synthetic economic model, not an EVM differential test.',
    settings: { climbBps: DEFAULTS.climbPerMin * 100, recoveryClimbBps: DEFAULTS.recoveryClimbPerMin * 100, dropBps: DEFAULTS.dropPerCreditPct * 100, dropFloorBps: DEFAULTS.dropToPct * 100, idleLoosenBps: DEFAULTS.idleLoosenPct * 100, idleStepSeconds: DEFAULTS.idleStepSeconds, multiplierCapBps: DEFAULTS.climbMultiplierCapBps, rateCapEth: DEFAULTS.rateCap / W, peakHalfLifeSeconds: DEFAULTS.peakHalfLifeHours * 3600 },
  };
  const rows = [];
  for (const scenario of ['flat', 'collapse']) for (const cap of assumptions.capBps) for (const offset of assumptions.startBucketOffsetsSeconds) {
    const rng = mulberry32(assumptions.seed);
    const inventory = assumptions.scoreMix.flatMap(({ points, count }) => Array(count).fill(points));
    for (let i = inventory.length - 1; i > 0; i--) { const j = Math.floor(rng() * (i + 1)); [inventory[i], inventory[j]] = [inventory[j], inventory[i]]; }
    const core = new Core({ ...DEFAULTS, spendCapBps: cap }, offset); core.fund(assumptions.initialPotEth, offset);
    let bought = 0, pointsBought = 0, spent = 0, crossing = null, stopped = null, recovery = null, initialRecovery = null, budgetStallBlocks = 0, unmarketableBlocks = 0;
    const askAt = (t) => scenario === 'flat' ? assumptions.flatAskEth : assumptions.initialReferenceBidEth * (1 - 0.8 * Math.min(t / assumptions.collapseSeconds, 1));
    const checkCrossing = (t) => {
      if (crossing === null && (scenario === 'flat' || t >= assumptions.collapseSeconds) && core.ethRate(t + offset) / W < askAt(t)) crossing = { seconds: t, credits: bought, pointsBought, spentEth: spent, referenceBidEth: core.ethRate(t + offset) / W, askEth: askAt(t) };
    };
    for (let t = 0; t <= assumptions.totalHorizonSeconds; t += assumptions.blockSeconds) {
      checkCrossing(t);
      if (stopped === null && (t >= assumptions.sellingHorizonSeconds || inventory.length === 0)) stopped = { seconds: t, credits: bought, pointsBought, spentEth: spent, royaltyEth: core.royaltyPaid, potEth: core.ethPot, referenceBidEth: core.ethRate(t + offset) / W, reason: inventory.length === 0 ? 'inventory exhausted' : 'selling horizon' };
      if (stopped !== null) {
        if (crossing !== null && recovery === null && core.ethRate(t + offset) / W >= assumptions.flatAskEth) recovery = t - stopped.seconds;
        if (initialRecovery === null && core.ethRate(t + offset) >= DEFAULTS.rateStart) initialRecovery = t - stopped.seconds;
        continue;
      }
      let filled = 0;
      for (;;) {
        const bid = core.ethRate(t + offset) / W;
        // the per point rule (decision 145): a credit of `pts` points is paid the rate times pts * 1e4 / RATE_SCORE
        const index = inventory.findIndex((pts) => bid * pts * 1e4 / RATE_SCORE >= askAt(t));
        if (index < 0) { if (!filled) unmarketableBlocks++; break; }
        const paid = core.sellForEth(t + offset, inventory[index]);
        if (!(paid > 0)) { budgetStallBlocks++; break; }
        pointsBought += inventory[index]; inventory.splice(index, 1); bought++; spent += paid; filled++; checkCrossing(t);
      }
      if (inventory.length === 0) {
        stopped = { seconds: t, credits: bought, pointsBought, spentEth: spent, royaltyEth: core.royaltyPaid, potEth: core.ethPot, referenceBidEth: core.ethRate(t + offset) / W, reason: 'inventory exhausted' };
        if (crossing !== null && core.ethRate(t + offset) / W >= assumptions.flatAskEth) recovery = 0;
        if (core.ethRate(t + offset) >= DEFAULTS.rateStart) initialRecovery = 0;
      }
    }
    rows.push({ scenario, capBps: cap, startBucketOffsetSeconds: offset, crossing, stopped, recoverySecondsAfterStop: recovery, initialBidRecoverySecondsAfterStop: initialRecovery, remainingCredits: inventory.length, pointsBought, remainingPoints: inventory.reduce((sum, score) => sum + score, 0), budgetStallBlocks, unmarketableBlocks, finalPotEth: core.ethPot, finalReferenceBidEth: core.ethRate(assumptions.totalHorizonSeconds + offset) / W });
  }
  return { assumptions, rows };
}

function main() {
const t0 = Date.now();
const grid = {};
for (const sc of SCENARIOS) for (const c of [50, 100, 200]) for (const l of [200, 600, 1000]) for (const cap of [1, 4]) {
  grid[`${sc}|${c}|${l}|${cap}`] = runCombo(sc, c, l, cap);
}
// isolation: the whale and pump under each multiplier cap and each hourly bound separately, to attribute the stranded pot
const iso = {};
for (const sc of ['whale', 'pump']) for (const cap of [1, 4]) for (const b of [0, 15000]) {
  const rows = SEEDS.map((seed) => runMarket({ scenario: sc, path: 'base', seed, climbPerMin: 1, idleLoosenPct: 6, multiplierCap: cap, hourlyBound: b }));
  const o = {}; for (const k of Object.keys(rows[0])) o[k] = mean(rows, k);
  iso[`${sc}|cap${cap}|bound${b}`] = o;
}
const runtime = (Date.now() - t0) / 1000;

// ---- output
fs.mkdirSync(OUT, { recursive: true });
const r = (x, d = 2) => (x == null || !Number.isFinite(x) ? '-' : (+x.toFixed(d)).toString());
const COLS = [
  ['ethPerDay', 'eth/day', 2], ['credits', 'credits', 0], ['pricePerPointPct', 'paid/pt %med', 0], ['worstBuyPct', 'worst %med', 0],
  ['daysToFirstStatement', 'day 1st stmt', 1], ['statementsComposed', 'stmts', 0], ['statementRevenue', 'stmt rev eth', 2],
  ['potDay30', 'pot d30', 2], ['bidDay30', 'bid d30 eth', 4], ['ccBurned', 'cc burned', 0],
];
function table(climbBps, loosenBps, cap) {
  const head = '| scenario | ' + COLS.map((c) => c[1]).join(' | ') + ' | attacker eth (fee) |';
  const sep = '|' + '---|'.repeat(COLS.length + 2);
  const lines = [head, sep];
  for (const sc of SCENARIOS) {
    const m = grid[`${sc}|${climbBps}|${loosenBps}|${cap}`];
    const cells = COLS.map((c) => r(m[c[0]], c[2]));
    const atkCell = sc === 'pump' ? `${r(m.attackerProfit, 3)} (${r(m.attackerFee, 2)})` : '-';
    lines.push('| ' + sc + ' | ' + cells.join(' | ') + ' | ' + atkCell + ' |');
  }
  return lines.join('\n');
}

// recommendation numbers: launch (100/600/4) vs today (50/200/1), and the isolation of the hourly bound
const launch = (sc) => grid[`${sc}|100|600|4`], today = (sc) => grid[`${sc}|50|200|1`];
const lb = launch('base'), tb = today('base'), lw = launch('whale'), tw = today('whale'), lp = launch('pump'), tp = today('pump');
const wB0 = iso['whale|cap4|bound0'], wB1 = iso['whale|cap4|bound15000'], pB0 = iso['pump|cap4|bound0'], pB1 = iso['pump|cap4|bound15000'];

const md = [
  '# the engine bid against the real board, six scenarios, decision 128',
  '',
  `the real board is ${BOARD_RAW.length} OpenSea listings and ${Object.keys(STRAT_READS.price).length} CreditStrategy listings (sim/data), median ask ${(BOARD_MED_PP * 440).toFixed(4)} eth for a 440 point credit (${BOARD_MED_PP.toExponential(2)} eth per point). the run starts from the live state: pot ${POT0} eth, rate 0.0169 eth, pile ${PILE0}. 30 days, one minute steps, base volume path 100 eth day one decaying 5 percent a day, mean of ${SEEDS.length} seeds. the flat market price of a credit is ${PE} eth (notes.md).`,
  '',
  '## launch settings: climb 100 bps/min, idle loosen 600 bps, multiplier cap 4, hourly bound 150 percent (decision 128)',
  '',
  table(100, 600, 4),
  '',
  '## today\'s settings: climb 50 bps/min, idle loosen 200 bps, multiplier cap 1, no hourly bound',
  '',
  table(50, 200, 1),
  '',
  '## recommendation',
  '',
  `1. adopt the multiplier cap 4; drop the hourly bound as specified. the multiplier is low risk: base, drought, strategy reprice and dead week buy the same credits under cap 4 and cap 1 (base ${r(lb.credits, 0)} vs ${r(tb.credits, 0)}), at ${r(lb.pricePerPointPct, 0)} percent of the board median per point either way. the engine against this board is fee limited, not climb limited, so climb 50/100/200 bps buy the same credits and differ only in the day-30 bid.`,
  `2. the hourly bound strands the pot after a sharp drop. a whale dump (2000 asks cut to the bid over an hour) cascades the bid down through the per-minute drop floor; fills then stop and the read is pinned at 150 percent of the collapsed fill, so the engine cannot re-climb to clear the rest of the board. with the bound the whale leaves ${r(lw.potDay30, 0)} eth of pot idle and buys ${r(lw.credits, 0)} credits; without it the engine recovers, spends the pot and buys ${r(tw.credits, 0)}. isolated on the whale at cap 4: bound off ${r(wB0.credits, 0)} credits, pot ${r(wB0.potDay30, 1)} eth; bound on ${r(wB1.credits, 0)} credits, pot ${r(wB1.potDay30, 1)} eth. the cause is the bound, not the multiplier.`,
  `3. the bound turns a harmless pot pump into a cheap griefing stall. the pump is unprofitable under every setting (attacker nets ${r(lp.attackerProfit, 2)} eth against a ${r(lp.attackerFee, 2)} eth swap fee, since the fee and the 3x rate cap already bound it). but with the bound the attacker's 200 credit dump collapses and pins the bid, stranding ${r(pB1.potDay30, 0)} eth of the engine's pot (pump bound off pot ${r(pB0.potDay30, 1)} eth, bound on ${r(pB1.potDay30, 1)} eth) and cutting acquisition from ${r(pB0.credits, 0)} to ${r(pB1.credits, 0)} credits for a ${r(lp.attackerFee, 2)} eth cost. if an idle-overshoot cap is wanted, tether it to a market or floor reference (floorRate, rateStart), not to the last fill, so a collapsed bid can still recover.`,
  '',
  'note: statement revenue is zero in every run. the engine pays about 4x the market sale price for credits against this board (board asks sit far above the market sale price), so composed statements price above what buyers pay for the parts and never clear, matching notes.md fact 9.',
  '',
  `run time ${runtime.toFixed(1)} s for 108 runs (${SCENARIOS.length} scenarios x 18 knob combinations x ${SEEDS.length} seeds) plus the bound isolation.`,
  '',
].join('\n');

fs.writeFileSync(OUT + 'market.json', JSON.stringify({ boardMedianPerPoint: BOARD_MED_PP, marketPrice: PE, start: { pot: POT0, rate: RATE0 / W, pile: PILE0 }, runtimeSec: runtime, grid, boundIsolation: iso }, null, 1));
fs.writeFileSync(OUT + 'market.md', md);
console.log('launch settings (climb 100, loosen 600, cap 4):\n');
console.log(table(100, 600, 4));
console.log(`\nwrote sim/out/market.json and sim/out/market.md; 108 runs in ${runtime.toFixed(1)} s`);
}
