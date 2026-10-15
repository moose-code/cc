// unit checks that the port matches src/Core.sol on hand computed cases. run: node engine.test.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { Core, Pool, DEFAULTS, SETTINGS, CONTROLLER, CREDIT, CREDIT_CONFIG_KEY, creditViolation, simulate, controllerViolation, summary, firstViolation, skimFraction, pathPrice, bountyFeeFraction, stepVolume, W } from './engine.js';

let n = 0;
const near = (a, b, tol, msg) => {
  n++;
  const rel = Math.abs(a - b) / Math.max(Math.abs(b), 1e-300);
  assert.ok(rel <= tol, `${msg}: got ${a}, want ${b}, rel err ${rel}`);
};
const ok = (c, msg) => { n++; assert.ok(c, msg); };
const H = 3600;
// LEGACY: the checks below that hand compute a single bid (a 0.0067 eth opening rate, one percent a minute climb, a 75 percent floor, feeToRedeemBurnBps 0) run on it. the launch values have their own checks against mainnet.json
const LEGACY = { stepSec: 3600, rateStart: 6.668e15, climbPerMin: 1, recoveryClimbPerMin: 1, idleLoosenPct: 0.01, ceilPct: 300, rateCap: 53344000000000000, saleFloorBps: 7500, feeToRedeemBurnBps: 0 };
const simL = (o = {}) => simulate(Object.assign({}, LEGACY, o));
// the sale and stall runs use the launch ceiling (ceilPct 110): at 300 the bid sits far above the market and few statements sell
const simC = (o = {}) => simL(Object.assign({ ceilPct: 110 }, o));
const fresh = (over = {}, pot = 1000) => {
  const p = Object.assign({}, DEFAULTS, LEGACY, over);
  // the ported single rate climb tests set only climbPerMin; match the recovery rate to it unless a test opts into the
  // dual speed, so a fill below the peak climbs at the same rate the assertions were written for
  if (over.recoveryClimbPerMin === undefined) p.recoveryClimbPerMin = p.climbPerMin;
  const c = new Core(p, 0);
  c.addFees(pot, 0);
  return c;
};
const R0 = 6.668e15;

// the launch values are the ones in script/config/mainnet.json, field for field. the file is the other half of the launch package: where it already
// carries a field of the rules in docs/DECISIONS.md section 9 it must match, and a field of the old rules (reserveBps) must be gone from the model
{
  const cfg = JSON.parse(fs.readFileSync(new URL('../script/config/mainnet.json', import.meta.url), 'utf8'));
  // the stepped bid fields of the Core, config name to model name (percent and hours in the model)
  const STEPPED = { dropPerCreditBps: 50, dropFloorBps: 5000, climbPerMinBps: 50, ceilBps: 11000, idleLoosenBps: 200, peakHalfLife: 21600, recoveryClimbPerMinBps: 200, recoveryGapBps: 1000 };
  const STEPPED_SIM = { dropPerCreditPct: 'dropPerCreditBps', dropToPct: 'dropFloorBps', climbPerMin: 'climbPerMinBps', ceilPct: 'ceilBps', idleLoosenPct: 'idleLoosenBps', recoveryClimbPerMin: 'recoveryClimbPerMinBps', recoveryGapPct: 'recoveryGapBps', peakHalfLifeHours: 'peakHalfLife' };
  for (const [k, v] of Object.entries(STEPPED)) near(cfg.settings[k], v, 1e-12, 'launch stepped bid rule ' + k);
  // the sim defaults are the launch bid rule, field for field with the config (bps to percent). the model has one bid rule
  ok(DEFAULTS.bidRule === undefined, 'the bid rule is one rule: the model carries no bidRule key');
  near(DEFAULTS.dropPerCreditPct, cfg.settings.dropPerCreditBps / 100, 1e-12, 'default dropPerCreditPct');
  near(DEFAULTS.dropToPct, cfg.settings.dropFloorBps / 100, 1e-12, 'default dropToPct');
  near(DEFAULTS.climbPerMin, cfg.settings.climbPerMinBps / 100, 1e-12, 'default climbPerMin');
  near(DEFAULTS.ceilPct, cfg.settings.ceilBps / 100, 1e-12, 'default ceilPct');
  near(DEFAULTS.idleLoosenPct, cfg.settings.idleLoosenBps / 100, 1e-12, 'default idleLoosenPct');
  near(DEFAULTS.recoveryClimbPerMin, cfg.settings.recoveryClimbPerMinBps / 100, 1e-12, 'default recoveryClimbPerMin');
  near(DEFAULTS.recoveryGapPct, cfg.settings.recoveryGapBps / 100, 1e-12, 'default recoveryGapPct');
  near(DEFAULTS.peakHalfLifeHours, cfg.settings.peakHalfLife / 3600, 1e-12, 'default peakHalfLifeHours');
  ok(cfg.settings.clampCredits === undefined && DEFAULTS.clampCredits === undefined, 'the clamp divisor is gone from the config and the model');
  near(DEFAULTS.rateStart, cfg.rateStart, 1e-12, 'default rateStart');
  // every other setting of the config is a SETTINGS field with the same value (eth and gwei in the model, wei in the config)
  for (const [k, v] of Object.entries(cfg.settings)) {
    if (k in STEPPED) continue;
    near(SETTINGS[k], k === 'buybackSlice' || k === 'keeperFee' || k === 'callerFee' ? v / 1e18 : k === 'keeperMaxBaseFee' || k === 'callerMaxBaseFee' ? v / 1e9 : v, 1e-12, 'setting ' + k);
  }
  for (const k of Object.keys(SETTINGS)) ok(cfg.settings[STEPPED_SIM[k] ?? k] !== undefined, 'the config carries ' + k);
  for (const k of Object.keys(cfg.settings)) ok(k in STEPPED || k in SETTINGS, 'the model carries ' + k);
  for (const k of Object.keys(CONTROLLER)) near(+CONTROLLER[k], k === 'anchorMinCost' ? +cfg.sale[k] / 1e18 : +cfg.sale[k], 1e-12, 'controller ' + k); // eth in the model, wei in the config
  assert.deepEqual(Object.keys(cfg.sale).sort(), Object.keys(CONTROLLER).sort()); n++; // the sale block and the model carry the same fields
  // the launch rateStart is 100 percent of market
  near(cfg.rateStart, 0.0089 * W, 1e-3, 'launch rateStart is 100 percent of the 0.0089 market');
  // the pool and payee values of the v2 launch
  for (const k of ['baselineSkimBps', 'bountyBps', 'sniperStartBps']) near(DEFAULTS[k], cfg.launch[k], 1e-12, 'launch ' + k);
  near(DEFAULTS.sniperSeconds, cfg.launch.sniperSeconds, 1e-12, 'launch sniperSeconds');
  near(DEFAULTS.sniperEndBps, cfg.launch.baselineSkimBps, 1e-12, 'the sniper skim falls to the baseline');
  ok(cfg.launch.lpFeePips === 0, 'no lp fee, so no lp income in the model');
  near(DEFAULTS.payeePpm, cfg.settings.payeePpm, 1e-12, 'payeePpm');
  // the credit block (the Credit struct of the launch config) is the model's CREDIT, field for field, and the launch values are the ones of FLOW 88 to 90
  assert.deepEqual(Object.keys(cfg.credit).sort(), [...Object.values(CREDIT_CONFIG_KEY), 'royaltyRecipient'].sort()); n++; // the recipient is an address the model has no use for
  for (const [k, ck] of Object.entries(CREDIT_CONFIG_KEY)) near(+CREDIT[k], +cfg.credit[ck], 1e-12, 'credit ' + k);
  assert.deepEqual(CREDIT, { creditCostToPotBps: 10000, chosenComposeOn: false, minCcToChoose: 1e18, creditSaleOn: false, creditWindow: 4 * H, creditFloorBps: 11000, creditStartBps: 30000, royaltyBps: 250 }); n++;
  assert.equal(creditViolation(CREDIT), null); n++;
  assert.equal(firstViolation(SETTINGS), null); n++;
  assert.equal(controllerViolation(CONTROLLER), null); n++;
  // the launch rules: statements fall to cost and stay there (FLOW 85), the balance side starts off (FLOW 86), the redeem burn reserve takes 10 percent of fees and each redemption releases 20 percent of it
  assert.deepEqual(CONTROLLER, { markupBps: 15000, startCapBps: 100000, decayHours: 12, anchorHalfLife: 7 * 24 * H, anchorMinCost: 0.1 }); n++;
  assert.equal(SETTINGS.saleFloorBps, 10000); assert.equal(SETTINGS.feeToBuybackBps, undefined); assert.equal(SETTINGS.feeToRedeemBurnBps, 1000); n += 3;
  assert.equal(SETTINGS.redeemOn, false); assert.equal(SETTINGS.balanceBidOn, false); assert.equal(SETTINGS.balanceMode, undefined); assert.equal(SETTINGS.redeemSlippageBps, 200); assert.equal(SETTINGS.balanceBidMarginBps, 2000); assert.equal(SETTINGS.redeemBurnBps, 2000); n += 6;
  ok(SETTINGS.redeemAfter === undefined && SETTINGS.balanceToBuybackBps === undefined && SETTINGS.xAuctionHalfLife === undefined && SETTINGS.balanceSliceCredits === undefined && SETTINGS.balanceLaneToBuybackBps === undefined && SETTINGS.xRateCap === undefined, 'the balance token auction and the climbing balance bid are gone from the model');
  ok(DEFAULTS.balancePoolSet === false && DEFAULTS.balanceDay === null, 'the balance token pool key is unset and the balance side is off at launch');
}
// the model has the one pile and the atFloor name: no lanes, no composeBalance, no atCost (FLOW 92, 90)
{
  const src = fs.readFileSync(new URL('./engine.js', import.meta.url), 'utf8');
  ok(!/\bLane\b|composeBalance|atCost|xHeld|xPile|ethPile|balanceLane|ethLane|creditScoreModule|scoreModule/.test(src), 'no lanes, no composeBalance, no atCost, no score module in the model');
  ok(Core.prototype.atFloor !== undefined && Core.prototype.atCost === undefined, 'atFloor replaces atCost');
}
// the owner pause (Core.setPaused): the age a price falls with excludes every paused second, a buy refuses while paused, a repeat changes nothing
{
  const c = fresh({}, 10);
  const st = { cost: 1, t0: 0 };
  const before = c.askingPrice(st, 20 * H);
  near(before, 1.30, 1e-12, 'hour 20 of the launch curve');
  c.setSettings({ paused: true }, 20 * H);
  assert.equal(c.isPaused(), true); assert.equal(c.buy(st, 30 * H), null); assert.equal(st.sold, undefined);
  near(c.askingPrice(st, 90 * H), before, 1e-12, 'the price is held through the pause');
  c.setPaused(true, 40 * H); assert.equal(c.pausedSince, 20 * H); // a repeat leaves the start of the pause
  c.setSettings({ paused: false }, 100 * H); c.setPaused(false, 101 * H); assert.equal(c.pausedTotal, 80 * H); // a repeat leaves the total
  near(c.askingPrice(st, 100 * H), before, 1e-12, 'the price at the resume is the price at the pause');
  near(c.askingPrice(st, 101 * H), 1.29, 1e-12, 'the fall continues an hour after the resume');
  const during = { cost: 1, t0: 50 * H, pauseMark: 30 * H }; // composed inside the pause (30 paused hours before it): age zero at the resume
  near(c.askingPrice(during, 100 * H), 1.50, 1e-12, 'a statement composed during the pause starts aging at the resume');
  c.setPaused(true, 110 * H); c.setPaused(false, 112 * H);
  near(c.askingPrice(st, 120 * H), 1.12, 1e-12, 'two pauses (80 and 2 hours): age 38 hours at hour 120');
  assert.throws(() => c.setSettings({ paused: 'yes' }, 0), /paused/);
  assert.equal(c.buy(st, 130 * H) !== null, true); n += 10;
}
// no inventory gate and no dutch statement auction anywhere
{
  const src = fs.readFileSync(new URL('./engine.js', import.meta.url), 'utf8');
  ok(!/inventoryGate|setGate|gated|AUCTION_START|AUCTION_FLOOR|AUCTION_LENGTH|buyStatement|bidMode/.test(src), 'no trace of the gate or the dutch auction');
  ok(!/auctionDuration|buyOnly|houseOwed|collectSales|bidOn|minBid/.test(src), 'no trace of the pnd auction house or auction mode');
  ok(DEFAULTS.inventoryGate === undefined && Core.prototype.setGate === undefined, 'no gate in the defaults or the Core');
  ok(!/reserveBps/.test(src) && DEFAULTS.reserveBps === undefined && Core.prototype.reprice === undefined, 'reserveBps is gone from the model, the reprice step is folded into the first bid');
}
// climb: the price state climbs climbPerMin percent a minute, compounded (CoreLib.climb). the ceiling is raised above its bounds here so it does not bind
{
  const c = fresh({ rateCap: 1e21, ceilPct: 1e6 });
  near(c.ethRate(1 * H), R0 * Math.pow(1.01, 60), 1e-12, 'one hour at 1 percent a minute');
  near(c.ethRate(6 * H), R0 * Math.pow(1.01, 360), 1e-12, 'six hours');
  near(c.ethRate(12 * H), R0 * Math.pow(1.01, 720), 1e-12, 'twelve hours');
}
// the ceiling: ceilPct of the anchor, the larger of the last fill rate and the remembered peak, loosened by idleLoosenPct for every full 10 idle minutes
{
  const c = fresh({ rateCap: 1e21, climbPerMin: 50, recoveryClimbPerMin: 50, ceilPct: 110, idleLoosenPct: 1 }); // 50 percent a minute reaches the ceiling within the first minute
  near(c.ethRate(5 * 60), R0 * 1.1, 1e-12, 'before the first full 10 idle minutes the ceiling is ceilPct of the opening rate');
  near(c.ethRate(H), R0 * 1.1 * 1.06, 1e-12, 'after 60 idle minutes (6 full intervals) the anchor is loosened by 6 percent');
}
// a fill drops the bid by dropPerCreditPct, then the price state climbs from the dropped rate
{
  const c = fresh({ rateCap: 1e21, ceilPct: 1e6 });
  ok(c.spend(1e-9, 0));
  near(c.rateAtCheckpoint, R0 * 0.995, 1e-12, 'one credit drops the bid 0.5 percent');
  near(c.ethRate(H), R0 * 0.995 * Math.pow(1.01, 60), 1e-12, 'an hour after the fill the climb runs from the dropped rate at 1 percent a minute');
}
// funded flag: the pot affords one credit at the rate, pot * 1e18 >= rate
{
  const need = R0 / W;
  const lo = new Core(Object.assign({}, DEFAULTS, LEGACY), 0);
  lo.addFees(need * 0.999, 0);
  assert.equal(lo.funded, false); n++;
  near(lo.ethPrice(100 * H), R0, 1e-12, 'unfunded: the price state holds');
  near(lo.ethRate(100 * H), need * 0.999 * W, 1e-12, 'unfunded: the read is the pot');
  const hi = new Core(Object.assign({}, DEFAULTS, LEGACY), 0);
  hi.addFees(need * 1.001, 0);
  assert.equal(hi.funded, true); n++;
}
// funded clamp: the climb stops where the pot buys one credit, pot * 1e18, or at rateCap
{
  const c = fresh({}, 1e-4);
  near(c.clamp(), 1e-4 * W, 1e-12, 'clamp at pot 0.0001 eth is the pot');
  near(fresh({}, 1000).clamp(), 53344000000000000, 1e-12, 'clamp at pot 1000 eth is the rate cap, 8 times rateStart');
}
// drop on fill: a fill drops the bid dropPerCreditPct of the rate paid, whatever share of the pot it spends. within one minute the bid stays
// at or above dropToPct of the bid at the first fill of that minute
{
  const c = fresh({ rateStart: 1e13 }, 1);
  ok(c.spend(0.1, 0)); // a tenth of the pot
  near(c.rateAtCheckpoint, 1e13 * (1 - 0.005), 1e-12, 'a tenth of the pot drops the bid 0.5 percent');
  near(c.ethPot, 0.9, 1e-12, 'pot after the spend');
  const w = fresh({ rateStart: 1e13 }, 1);
  ok(w.spend(0.5, 0));
  near(w.rateAtCheckpoint, 1e13 * 0.995, 1e-12, 'half the pot spent drops the bid the same 0.5 percent');
  const z = fresh({ rateStart: 1e13, dropPerCreditPct: 5 }, 1);
  ok(z.spend(0.1, 0)); near(z.rateAtCheckpoint, 1e13 * 0.95, 1e-12, 'dropPerCreditPct 5 drops 5 percent');
  const f = fresh({ rateStart: 1e13, dropPerCreditPct: 60 }, 1);
  ok(f.spend(0.1, 0)); near(f.rateAtCheckpoint, 1e13 * 0.5, 1e-12, 'a drop of 60 percent stops at dropToPct (50 percent) of the bid at the first fill');
  ok(f.spend(0.1, 59)); near(f.rateAtCheckpoint, 1e13 * 0.5, 1e-12, 'a second fill in the same minute stays at that floor');
}
// every credit is paid the rate: no score, no window
{
  const c = fresh({}); c.rateAtCheckpoint = 1e13; c.checkpointTime = 0;
  const paid = c.sellForEth(0);
  near(paid, 1e13 / W, 1e-12, 'sellForEth pays the rate for any credit');
  near(c.ethPot, 1000 - 1e13 / W, 1e-12, 'the pot paid it');
  ok(c.spend(500, 0) && c.spend(499.9, 0), 'a spend of most of the pot passes, there is no hourly cap');
  assert.equal(c.spend(1, 0), false); n++; // more than the pot left
}
// buyListing payment (docs/DECISIONS.md 71): counted gas (at most BUYLISTING_GAS) at min(basefee, keeperMaxBaseFee) plus keeperFee, at most the bid less the ask, booked as spend with the cost
{
  const c = fresh({}, 10);
  c.rateAtCheckpoint = 1e16; // ceiling 0.01 eth, base fee 1 gwei, keeperFee 0.0005
  const gas = 470000e-9 + 0.0005;
  const res = c.buyListing(0.008, 0);
  ok(res);
  near(res.paid, gas, 1e-12, 'a large gap pays counted gas at the base fee plus the keeper fee');
  near(c.ethPot, 10 - 0.008 - gas, 1e-12, 'the pot paid the cost and the payment');
  const c2 = fresh({}, 10); c2.rateAtCheckpoint = 1e16;
  near(c2.buyListing(0.0099, 0).paid, 0.0001, 1e-9, 'a gap under the largest payment is the payment');
  assert.equal(c2.buyListing(0.0101, 0), null); n++;
  const c3 = fresh({}, 10); c3.rateAtCheckpoint = 1e16; c3.p.basefeeGwei = 50;
  near(c3.buyListing(0.002, 0).paid, 470000 * 10e-9 + 0.0005, 1e-12, 'a base fee above keeperMaxBaseFee pays at the cap');
}
// compose at the launch settings pays nothing: the pot is unchanged and the statement cost is the plain sum of the credit costs
{
  const c = fresh({}, 10);
  const pot = c.ethPot;
  const st = c.compose(0.8, 0);
  near(st.cost, 0.8, 1e-15, 'the cost is the credit sum');
  near(c.compose(0, 0).cost, 0, 1e-15, 'a zero cost credit sum stays zero');
  assert.equal(c.ethPot, pot); assert.equal(st.reimb, undefined); n += 2;
}
// the asking price of a statement (ControllerV1._quote, then the Core's hard floor): start falls in a straight line to
// saleFloorBps over decayHours hours, then rests. start = min(anchorBps * markupBps / 10000, startCapBps). the price is a share of what the engine PAID, the statement cost
{
  const c = fresh({}, 10);
  const st = { cost: 1, t0: 0 }; // cost 1 eth keeps the percent readable
  const at = (h) => c.askingPrice(st, h * H);
  near(at(0), 1.50, 1e-12, 'asking 150 at hour 0 (anchor 10000, markup 15000)');
  near(at(6), 1.25, 1e-12, 'asking 125 halfway through the 12 hour window');
  near(at(12), 1.00, 1e-12, 'asking 100 (the floor) at hour 12');
  near(at(13), 1.00, 1e-12, 'rests at the floor'); near(at(5000), 1.00, 1e-12, 'floor long after');
  near(c.askingPrice(st, 1), 1.5 - 5000 / 10000 / (12 * 3600), 1e-12, 'the price falls every second');
  near(c.askingPrice({ cost: 2.4, t0: 10 * H }, 16 * H), 2.4 * 1.25, 1e-12, 'age counts from listedAt, price scales with cost');
  near(c.askingPrice({ cost: 1, t0: 100 }, 50), 1.50, 1e-12, 'a clock before listedAt is age zero');
  assert.equal(c.lowestPrice(st, 0), 1.00); n++;
  // the settings are read live: another markup, cap, decayHours and floor
  const d = fresh({ markupBps: 20000, startCapBps: 100000, decayHours: 24, saleFloorBps: 9000 }, 10);
  near(d.askingPrice(st, 0), 2.00, 1e-12, 'start 200');
  near(d.askingPrice(st, 12 * H), 1.45, 1e-12, 'halfway down the 24 hour line from 200 to 90');
  near(d.askingPrice(st, 1000 * H), 0.90, 1e-12, 'the floor setting 90 is where it stops');
  near(fresh({ markupBps: 10000 }, 10).askingPrice(st, 0), 1.00, 1e-12, 'markup 10000 starts at the anchor (the floor), flat');
  near(fresh({ markupBps: 10000 }, 10).askingPrice(st, 40 * H), 1.00, 1e-12, 'a start equal to the floor is flat');
  // the controller settings change at once through setSettings and are validated against the controller bounds
  const e = fresh({}, 10); e.setSettings({ markupBps: 12000, decayHours: 24 }, 5 * H);
  const st5 = { cost: 1, t0: 5 * H };
  near(e.askingPrice(st5, 5 * H), 1.20, 1e-12, 'a changed markup read at once');
  near(e.askingPrice(st5, 17 * H), 1.10, 1e-12, 'halfway down the new 24 hour line from 120 to 100');
  assert.throws(() => e.setSettings({ decayHours: 0 }, 0), /decayHours/); assert.throws(() => e.setSettings({ decayHours: 721 }, 0), /decayHours/); n += 2;
  assert.throws(() => e.setSettings({ markupBps: 9999 }, 0), /markupBps/); assert.throws(() => e.setSettings({ startCapBps: 11999 }, 0), /startCapBps/); n += 2;
  assert.throws(() => e.setSettings({ saleFloorBps: 999 }, 0), /saleFloorBps/); n += 1;
  near(e.c.markupBps, 12000, 1e-12, 'a rejected change leaves the controller alone');
  for (const [k, bad] of [['markupBps', 40001], ['startCapBps', 200001], ['decayHours', 0], ['decayHours', 721], ['anchorHalfLife', 86399], ['anchorHalfLife', 90 * 86400 + 1], ['anchorMinCost', -1], ['anchorMinCost', 10.0001]]) assert.equal(controllerViolation(Object.assign({}, CONTROLLER, { [k]: bad })), k), n++;
  assert.equal(controllerViolation(Object.assign({}, CONTROLLER, { startCapBps: 14999 })), 'startCapBps'); n++;
  assert.equal(controllerViolation(Object.assign({}, CONTROLLER, { markupBps: 40000, startCapBps: 40000, decayHours: 720, anchorHalfLife: 86400 })), null); n++;
  assert.equal(controllerViolation(Object.assign({}, CONTROLLER, { markupBps: 10000, startCapBps: 200000, decayHours: 1, anchorHalfLife: 90 * 86400 })), null); n++;
  // the closed form, written again here: 15000 falling in a straight line to 10000 at hour 12, in bps
  const ref = (h) => (h >= 12 ? 10000 : 15000 - (15000 - 10000) * h / 12) / 10000;
  for (const sec of [0, 1, 59, 12345, 12 * 3600 - 1, 12 * 3600, 12 * 3600 + 1, 100000, 600000]) ok(Math.abs(c.askingPrice(st, sec) - ref(sec / 3600)) < 1e-12, 'the closed form at ' + sec + ' seconds');
  // the price never rises with the age
  let prev = Infinity; for (let sec = 0; sec <= 700000; sec += 997) { const v = c.askingPrice(st, sec); ok(v <= prev + 1e-15, 'non-increasing in the age'); prev = v; }
}
// the anchor: the running level of sale prices in bps of cost. a buy only sale above the anchor now sets it to the mean of the two (the sale price rounded up in bps),
// never above startCapBps. a sale at or below the anchor leaves it and its time. the part above 10000 halves every anchorHalfLife (7 days at launch), continuously.
// the start price follows it, open listings included
{
  const D = 86400;
  const c = fresh({}, 10);
  assert.equal(c.anchorAt(0), 10000); assert.equal(c.startBps(0), 15000); n += 2;
  // a sale at the floor (100 percent, hour 90, past the 12 hour window) is at the anchor: the stored anchor and its time stay
  const lo = c.buy(c.compose(1, 0), 90 * H);
  assert.equal(lo.saleBps, 10000); assert.equal(c.anchorStored, 10000); assert.equal(c.anchorTime, 0); n += 3;
  // a sale at the start price, 15000, moves the anchor to 12500 and the next start to 18750
  const T = 1000 * H;
  const open = c.compose(1, T);
  const hi = c.buy(c.compose(1, T), T);
  assert.equal(hi.saleBps, 15000); assert.equal(c.anchorAt(T), 12500); assert.equal(c.startBps(T), 18750); assert.equal(c.anchorTime, T); n += 4;
  // the listing open since T follows the anchor: its start is now 18750. 52.5 hours later the anchor has decayed to 12013 (floor of 10000 + 2500 * 2^(-52.5 / 168)), the start is 18019
  near(c.askingPrice(open, T), 1.875, 1e-12, 'the start follows the anchor');
  assert.equal(c.anchorAt(T + 52.5 * H), 12013); assert.equal(c.startBps(T + 52.5 * H), 18019); n += 2;
  near(c.askingPrice(open, T + 52.5 * H), (18019 - 5250) / 10000, 1e-12, 'the price follows the decayed anchor: the start less 52.5 hours of 100 bps');
  near(c.askingPrice(open, T + 1000 * H), 0.75, 1e-12, 'the end of the curve is the floor');
  // four sales at the start price in a row (integer math): the anchor is 12500, 15625, 19531, 24413 after them
  const d = fresh({}, 10); const seen = [];
  for (let i = 0; i < 4; i++) { const r = d.buy(d.compose(1, 0), 0); seen.push(r.saleBps, d.anchorAt(0)); }
  assert.deepEqual(seen, [15000, 12500, 18750, 15625, 23437, 19531, 29296, 24413]); n++;
  // two sales at the floor at hour 400 leave the anchor, its time and the fresh start price where they were
  d.compose(1, 0); d.compose(1, 0);
  const startBefore = d.startBps(400 * H), freshAsk = d.askingPrice({ cost: 1, t0: 400 * H }, 400 * H);
  const f1 = d.buy(d.compose(1, 0), 400 * H), f2 = d.buy(d.compose(1, 0), 400 * H);
  assert.equal(f1.saleBps, 7500); assert.equal(f2.saleBps, 7500); assert.equal(d.anchorStored, 24413); assert.equal(d.anchorTime, 0); n += 4;
  assert.equal(d.startBps(400 * H), startBefore); near(d.askingPrice({ cost: 1, t0: 400 * H }, 400 * H), freshAsk, 1e-12, 'the fresh ask'); n++;
  // decay: 30000 reads 20000 after 7 days, 15000 after 14, 24142 after 3.5, and holds 10000 after a year and after 300 half lives
  const k = fresh({}, 10); k.setSettings({ anchorBps: 30000 }, 0);
  assert.equal(k.anchorAt(0), 30000); assert.equal(k.anchorAt(7 * D), 20000); assert.equal(k.anchorAt(14 * D), 15000); assert.equal(k.anchorAt(3.5 * D), 24142); n += 4;
  assert.equal(k.anchorAt(365 * D), 10000); assert.equal(k.anchorAt(300 * 7 * D), 10000); assert.equal(k.startBps(7 * D), 30000); n += 3;
  // a sale above the decayed anchor moves it half way from the decayed value: (20000 + 30000) / 2
  const sb = k.buy(k.compose(1, 7 * D), 7 * D);
  assert.equal(sb.saleBps, 30000); assert.equal(k.anchorStored, 25000); assert.equal(k.anchorTime, 7 * D); n += 3;
  // a new half life stores the anchor now first: 20000 at day 7, then 15000 one new half life (14 days) later
  const m = fresh({}, 10); m.setSettings({ anchorBps: 30000 }, 0); m.setSettings({ anchorHalfLife: 14 * D }, 7 * D);
  assert.equal(m.anchorStored, 20000); assert.equal(m.anchorTime, 7 * D); assert.equal(m.anchorAt(7 * D), 20000); assert.equal(m.anchorAt(21 * D), 15000); n += 4;
  assert.throws(() => m.setSettings({ anchorHalfLife: D - 1 }, 0), /anchorHalfLife/); assert.throws(() => m.setSettings({ anchorHalfLife: 90 * D + 1 }, 0), /anchorHalfLife/); n += 2;
  // a start cap below the anchor now lowers the anchor to the cap and stores it. a cap above the decayed anchor leaves the stored anchor
  const q = fresh({}, 10); q.setSettings({ anchorBps: 80000 }, 0);
  assert.equal(q.anchorAt(7 * D), 45000); q.setSettings({ startCapBps: 60000 }, 7 * D); assert.equal(q.anchorStored, 80000); assert.equal(q.anchorTime, 0); n += 3;
  q.setSettings({ startCapBps: 40000 }, 7 * D); assert.equal(q.anchorStored, 40000); assert.equal(q.anchorTime, 7 * D); n += 2;
  // the cap holds the start and the anchor
  const e = fresh({ startCapBps: 20000 }, 10);
  e.setSettings({ anchorBps: 20000 }, 0);
  assert.equal(e.startBps(0), 20000); n++;
  const r = e.buy(e.compose(1, 0), 0); assert.equal(r.saleBps, 20000); assert.equal(e.anchorAt(0), 20000); n += 2;
  const g = fresh({ markupBps: 12000, startCapBps: 12000, saleFloorBps: 30000 }, 10);
  const rg = g.buy(g.compose(1, 0), 0); assert.equal(rg.saleBps, 30000); assert.equal(g.anchorAt(0), 12000); n += 2; // a hard floor above the cap cannot pull the anchor past the cap
  // a refused sale leaves the anchor alone
  const h = fresh({}, 10); const sold = h.compose(1, 0); h.buy(sold, 0); const a1 = h.anchorAt(0);
  assert.equal(h.buy(sold, 0), null); assert.equal(h.anchorAt(0), a1); n += 2;
  // the owner corrects the anchor (setAnchorBps): between 10000 and startCapBps
  h.setSettings({ anchorBps: 14000 }, 0); assert.equal(h.anchorAt(0), 14000); assert.equal(h.startBps(0), 21000); n += 2;
  assert.throws(() => h.setSettings({ anchorBps: 9999 }, 0), /anchorBps/); assert.throws(() => h.setSettings({ anchorBps: 100001 }, 0), /anchorBps/); n += 2;
  assert.equal(h.anchorAt(0), 14000); n++;
  // anchorMinCost (0.1 eth at launch): a statement that costs less is sold at its start price and leaves the anchor and its time. one that costs the minimum moves it
  const mc = fresh({}, 10);
  const small = mc.buy(mc.compose(0.0999, 0), 0);
  assert.equal(small.saleBps, 15000); assert.equal(mc.anchorStored, 10000); assert.equal(mc.anchorTime, 0); n += 3;
  const edge = mc.buy(mc.compose(0.1, 5 * H), 5 * H);
  assert.equal(edge.saleBps, 15000); assert.equal(mc.anchorStored, 12500); assert.equal(mc.anchorTime, 5 * H); n += 3;
  // the minimum is a setting: 0 lets every statement move the anchor, the owner sets it at once
  mc.setSettings({ anchorMinCost: 0 }, 6 * H); mc.setSettings({ anchorBps: 10000 }, 6 * H);
  mc.buy(mc.compose(0.0001, 6 * H), 6 * H); assert.equal(mc.anchorStored, 12500); n++;
  assert.throws(() => mc.setSettings({ anchorMinCost: 10.0001 }, 6 * H), /anchorMinCost/); n++;
}
// the one floor (decision 105): saleFloorBps is the share of the reference where the curve stops and the share of cost the Core takes at least
{
  const st = { cost: 1, t0: 0 };
  const a = fresh({ saleFloorBps: 7500 }, 10);
  near(a.askingPrice(st, 200 * H), 0.75, 1e-12, 'the curve stops at the floor setting');
  near(a.askingPrice(st, 300 * H), 0.75, 1e-12, 'and stays there');
  near(a.askingPrice(st, 52.5 * H), 0.99375, 1e-12, 'above the floor the curve decides');
  near(a.statementPrice(1, st, 300 * H), 0.75, 1e-12, 'the controller price alone stops at the same floor');
  const b = fresh({ saleFloorBps: 20000 }, 10);
  near(b.askingPrice(st, 0), 2.0, 1e-12, 'a start under the floor is lifted to it');
  near(b.askingPrice(st, 5000 * H), 2.0, 1e-12, 'and the price stays there');
  const c = fresh({ saleFloorBps: 6000 }, 10);
  near(c.askingPrice(st, 1000 * H), 0.60, 1e-12, 'with the floor lowered the price walks to 60');
  near(fresh({ saleFloorBps: 9500 }, 10).askingPrice(st, 1000 * H), 0.95, 1e-12, 'a floor of 95');
  near(fresh({ saleFloorBps: 9500 }, 10).lowestPrice(st, 0), 0.95, 1e-12, 'lowest price is the floor of the reference');
  near(a.floorPrice({ cost: 2 }), 1.5, 1e-12, 'floorPrice is cost times saleFloorBps');
  // the floor is a share of the reference, and the Core still takes the cost based floor
  const rich = { cost: 1, t0: 0, rating: 80 * 433 * 3 }; const r = fresh({ saleFloorBps: 7500, rateStart: 1e16, rateCap: 1e16 }, 10);
  near(r.reference(rich, 0), 2.4, 1e-12, 'the rate term is 0.8 a point group, three of them');
  near(r.askingPrice(rich, 5000 * H), 2.4 * 0.75, 1e-12, 'the curve rests at the floor share of the reference');
  ok(r.askingPrice(rich, 5000 * H) > r.floorPrice(rich), 'above the cost based floor of the Core');
  // sellTo refuses a payment under the floor of the Core even if the controller would ask less
  const s = a.compose(1, 0);
  assert.equal(a.sellTo(s, 0.7499, 0), null); assert.notEqual(a.sellTo(s, 0.75, 0), null); n += 2;
}
// compose holds the statement in the Core from composedAt, asked at age zero at the start price, and stores its rating
{
  const c = fresh({}, 10);
  const st = c.compose(0.8, 0);
  near(c.askingPrice(st, 0), st.cost * 1.5, 1e-12, 'asked at the start price, 150 percent of cost');
  near(fresh({ markupBps: 10000 }, 10).askingPrice({ cost: 1, t0: 0 }, 0), 1.0, 1e-12, 'markupBps 10000');
  near(fresh({ markupBps: 13000 }, 10).askingPrice({ cost: 1, t0: 0 }, 0), 1.3, 1e-12, 'markupBps 13000');
  assert.deepEqual(Object.keys(st).sort(), ['cost', 'pauseMark', 'rating', 't0']); n++; // the record carries cost, composedAt, rating and the pause mark
  assert.equal(c.compose(1, 0, 35200).rating, 35200); n++
  const a100 = c.askingPrice(st, 100);
  near(a100, 0.8 * 1.5 - 0.8 * 100 * 100 / (3600 * 10000), 1e-12, 'the asking price a hundred seconds in');
}
// sellTo pays the asking price and the statement is gone at once
{
  const c = fresh({}, 10);
  const pot0 = c.ethPot;
  const st = c.compose(1, 0);
  const ask = c.askingPrice(st, 50 * H); near(ask, 1.0, 1e-12, 'asking price at hour 50');
  const r = c.sellTo(st, ask, 50 * H);
  ok(r !== null && st.sold === true, 'sold in the same call');
  near(r.toBuyback, 0.5, 1e-12, 'launch split: half to the buyback'); near(r.toPot, 0.5, 1e-12, 'half to the pot');
  near(c.ethPot - pot0, 0.5, 1e-12, 'the pot has it at once'); near(c.ethToBuyback, 0.5, 1e-12, 'the buyback pot has it at once');
  assert.equal(c.anchorAt(50 * H), 10000); n++; // sellTo is the Core door, the anchor moves in the controller's buy
  assert.equal(c.sellTo(st, ask, 31 * H), null); n++; // a statement is sold once
  // overpaying is booked in full, the Core gives no refund
  const o = c.compose(1, 0); const p1 = c.ethPot + c.ethToBuyback;
  c.sellTo(o, 3, 0); near(c.ethPot + c.ethToBuyback - p1, 3, 1e-12, 'what is paid is booked');
}
// the proceeds split: sellTo books saleToBuybackBps to the buyback and the rest to the pot at once
{
  for (const [bps, bb] of [[0, 0], [1000, 0.1], [5000, 0.5], [10000, 1]]) {
    const b = fresh({ saleToBuybackBps: bps }, 10); const pb = b.ethPot;
    const sb = b.compose(1, 0); b.sellTo(sb, 1.5, 0);
    near(b.ethToBuyback, 1.5 * bb, 1e-12, 'buyback share at ' + bps); near(b.ethPot - pb, 1.5 * (1 - bb), 1e-12, 'pot share at ' + bps);
  }
  // a split change applies to the next booking, the Core reads it live
  const c = fresh({}, 10); c.setSettings({ saleToBuybackBps: 2500 }, 0); const p0 = c.ethPot; c.sellTo(c.compose(1, 0), 4, 0);
  near(c.ethToBuyback, 1, 1e-12, 'live split'); near(c.ethPot - p0, 3, 1e-12, 'live split, pot');
}
// feeToRedeemBurnBps: the one split of swap fee eth booked in receive(), the share that fills the redeem burn reserve, the rest to the pot (decision 106)
{
  for (const [bps, rb] of [[0, 0], [2500, 0.25], [5000, 0.5], [10000, 1]]) {
    const c = new Core(Object.assign({}, DEFAULTS, LEGACY, { feeToRedeemBurnBps: bps }), 0);
    const r = c.addFees(8, 0);
    near(c.ethRedeemBurn, 8 * rb, 1e-12, 'fee share to the reserve at ' + bps); near(c.ethPot, 8 * (1 - rb), 1e-12, 'fee share to pot at ' + bps);
    near(r.toRedeemBurn + r.toPot, 8, 1e-12, 'fee split adds up at ' + bps); near(c.feeToRedeemBurn, 8 * rb, 1e-12, 'fee share booked at ' + bps);
    near(c.ethToBuyback, 0, 1e-12, 'a fee never reaches the buyback pot directly at ' + bps);
  }
  assert.equal(SETTINGS.feeToBuybackBps, undefined); assert.equal(new Core(DEFAULTS, 0).feeToBuyback, undefined); n += 2;
  const z = fresh({ feeToRedeemBurnBps: 0 }, 10); near(z.ethRedeemBurn, 0, 1e-12, 'share 0 sends no fee to the reserve'); near(z.ethPot, 10, 1e-12, 'all of it to the pot');
  // the funded flag follows the pot only (the reserve share is not in the pot)
  const h = new Core(Object.assign({}, DEFAULTS, LEGACY, { feeToRedeemBurnBps: 5000 }), 0);
  const need = R0 / W;
  h.addFees(need * 1.5, 0); assert.equal(h.funded, false); h.addFees(need * 1, 0); assert.equal(h.funded, true); n += 2; // pot 1.25 need after the second booking
  // a change applies to the next booking, sale proceeds are not touched by it
  const s = fresh({}, 10); s.setSettings({ feeToRedeemBurnBps: 10000 }, 0); s.addFees(1, 0);
  near(s.ethRedeemBurn, 1, 1e-12, 'live fee share'); near(s.ethPot, 10, 1e-12, 'pot unchanged by a fee booked at 10000');
  s.sellTo(s.compose(1, 0), 2, 0); near(s.ethToBuyback, 1, 1e-12, 'sales follow saleToBuybackBps, not the fee share');
  assert.throws(() => s.setSettings({ feeToRedeemBurnBps: 10001 }, 0), /feeToRedeemBurnBps/); n++;
  assert.throws(() => s.setSettings({ saleFloorBps: 999 }, 0), /saleFloorBps/); n++;
}
// conservation of eth through the Core: fees, sales, spend, redemptions and the buyback slice all come from and go to one ledger (pot, buyback pot, redeem burn reserve)
{
  for (const over of [{}, { feeToRedeemBurnBps: 5000 }, { feeToRedeemBurnBps: 2500, saleToBuybackBps: 7500 }, { feeToRedeemBurnBps: 10000, saleToBuybackBps: 0 }, { basefeeGwei: 40 }, { feeToRedeemBurnBps: 1000 }, { feeToRedeemBurnBps: 2500, redeemBurnBps: 10000, redeemOn: true }]) {
    const c = new Core(Object.assign({}, DEFAULTS, LEGACY, over), 0);
    c.setBalanceModule(0, 1e-5);
    let inflow = 0, out = 0;
    c.addFees(20, 0); inflow += 20;
    c.addFees(3.3, 50); inflow += 3.3;
    if (c.spend(1.2, 100)) out += 1.2; else ok(c.ethPot < 1.2, 'a spend only fails on an empty pot');
    const st = c.compose(0.9, 200, 35200);
    const p0 = c.askingPrice(st, 40 * H); c.buy(st, 40 * H); inflow += p0;
    if (c.s.redeemOn) c.redeemStatement(c.compose(0.9, 200, 35200), 80 * H); // the balance token leaves the eth ledger, the reserve moves into the buyback pot
    const b = c.takeBuybackSlice(50 * H); if (b) out += b.budget + b.tip; // what leaves the buyback pot: the swap budget and the caller payment
    near(c.ethPot + c.ethToBuyback + c.ethRedeemBurn + out, inflow, 1e-12, 'eth conserved ' + JSON.stringify(over));
    near(c.feeToRedeemBurn - c.redeemBurnMoved - c.ethRedeemBurn, 0, 1e-12, 'reserve conserved ' + JSON.stringify(over));
    ok(c.ethPot >= 0 && c.ethToBuyback >= 0 && c.ethRedeemBurn >= 0, 'no negative pot');
  }
}
// setSettings: validates, checkpoints both rates first, applies at once
{
  const c = fresh({}, 1000);
  c.setSettings({ climbPerMin: 2, recoveryClimbPerMin: 2 }, 600);
  near(c.rateAtCheckpoint, R0 * Math.pow(1.01, 10), 1e-12, 'the climb to the change is credited under the old numbers');
  assert.equal(c.checkpointTime, 600); n++;
  near(c.ethRate(660), R0 * Math.pow(1.01, 10) * 1.02, 1e-12, 'the climb goes on at the new speed after the change');
  assert.throws(() => c.setSettings({ saleToBuybackBps: 10001 }, 0), /saleToBuybackBps/); n++;
  assert.throws(() => c.setSettings({ dropPerCreditPct: 0 }, 0), /dropPerCreditPct/); n++;
  assert.throws(() => c.setSettings({ saleFloorBps: 999 }, 0), /saleFloorBps/); n++;
  assert.throws(() => c.setSettings({ rate: 1e10 }, 0), /BadRate/); n++;
  near(c.s.dropPerCreditPct, 0.5, 1e-12, 'a rejected change leaves the settings alone');
  c.setSettings({ rate: 2e13, saleToBuybackBps: 100 }, 20 * H);
  near(c.ethRate(20 * H), 2e13, 1e-12, 'setRate resets the limit'); near(c.s.saleToBuybackBps, 100, 1e-12, 'sale split changed');
  // the clamp reads the live pot
  const d = fresh({ rateCap: 1e18 }, 0.1);
  near(d.clamp(), 0.1 * W, 1e-12, 'clamp is the pot');
  // the tightened bounds of the audit fixes (FC-1 accepted with bounds, FC-2, FC-3, FC-7) and the rate cap (FC-5)
  const bad = (patch, name) => { assert.equal(firstViolation(Object.assign({}, SETTINGS, patch)), name); n++; };
  bad({ dropPerCreditPct: 0 }, 'dropPerCreditPct'); bad({ dropPerCreditPct: 10.01 }, 'dropPerCreditPct'); bad({ dropToPct: 49 }, 'dropToPct'); bad({ climbPerMin: 0 }, 'climbPerMin');
  bad({ ceilPct: 301 }, 'ceilPct'); bad({ ceilPct: 99 }, 'ceilPct'); bad({ idleLoosenPct: 0 }, 'idleLoosenPct'); bad({ recoveryClimbPerMin: 0.4 }, 'recoveryClimbPerMin');
  bad({ recoveryGapPct: 50.01 }, 'recoveryGapPct'); bad({ peakHalfLifeHours: 599 / 3600 }, 'peakHalfLifeHours'); bad({ peakHalfLifeHours: 604801 / 3600 }, 'peakHalfLifeHours');
  bad({ payeePpm: 200001 }, 'payeePpm'); assert.equal(firstViolation(Object.assign({}, SETTINGS, { payeePpm: 200000 })), null); n++;
  bad({ refScore: 0 }, 'refScore'); bad({ refScore: 8000001 }, 'refScore'); assert.equal(firstViolation(Object.assign({}, SETTINGS, { refScore: 8000000 })), null); n++;
  bad({ saleFloorBps: 999 }, 'saleFloorBps'); bad({ saleFloorBps: 40001 }, 'saleFloorBps');
  bad({ buybackSlice: 1.01 }, 'buybackSlice'); bad({ buybackDelay: 0 }, 'buybackDelay'); bad({ buybackDelay: 7201 }, 'buybackDelay');
  bad({ rateCap: 1e13 - 1e6 }, 'rateCap'); bad({ rateCap: 1.1e18 }, 'rateCap');
  // the balance side (FLOW 84, 86, decision 107): the two switches are booleans, slippage at most 10 percent, margin at most 90 percent, the reserve shares at most 100 percent
  bad({ redeemOn: 1 }, 'redeemOn'); bad({ balanceBidOn: 'yes' }, 'balanceBidOn'); bad({ redeemSlippageBps: 1001 }, 'redeemSlippageBps'); bad({ balanceBidMarginBps: 9001 }, 'balanceBidMarginBps');
  bad({ redeemSlippageBps: 201, balanceBidMarginBps: 200 }, 'redeemSlippageBps'); bad({ balanceBidMarginBps: 0 }, 'redeemSlippageBps'); // slippage at most the bid margin
  assert.equal(firstViolation(Object.assign({}, SETTINGS, { redeemSlippageBps: 200, balanceBidMarginBps: 200 })), null); assert.equal(firstViolation(Object.assign({}, SETTINGS, { redeemSlippageBps: 0, balanceBidMarginBps: 0 })), null); n += 2;
  bad({ redeemBurnBps: 10001 }, 'redeemBurnBps'); bad({ feeToRedeemBurnBps: 10001 }, 'feeToRedeemBurnBps');
  assert.equal(firstViolation(Object.assign({}, SETTINGS, { feeToRedeemBurnBps: 10000 })), null); n++;
  assert.equal(firstViolation(Object.assign({}, SETTINGS, { dropPerCreditPct: 1, saleFloorBps: 1000, feeToRedeemBurnBps: 10000, buybackSlice: 1, rateCap: 1e18, redeemOn: true, balanceBidOn: true, redeemSlippageBps: 1000, balanceBidMarginBps: 9000, redeemBurnBps: 10000 })), null); n++;
  assert.equal(SETTINGS.rateCap, 26700000000000000); assert.equal(SETTINGS.rateCap, 3 * DEFAULTS.rateStart); n++;
  const c2 = fresh({}, 10);
  assert.throws(() => c2.setSettings({ feeToRedeemBurnBps: 10001 }, 0), /feeToRedeemBurnBps/); n++;
  c2.setSettings({ redeemOn: true }, 5); assert.equal(c2.s.redeemOn, true); assert.equal(c2.s.balanceBidOn, false); n += 2;
  c2.setSettings({ balanceBidOn: 1 }, 6); assert.equal(c2.s.balanceBidOn, true); n++; // a numeric patch value from the page is read as a flag
}
// rateCap: the climb clamps at it, setRate refuses above it, a lower cap pulls the rate down at the checkpoint
{
  const c = fresh({}, 1000);
  near(c.ethRate(10000 * H), 53344000000000000, 1e-12, 'the climb stops at rateCap with a huge pot');
  assert.throws(() => c.setSettings({ rate: 53344000000001000 }, 0), /BadRate/); n++;
  c.setSettings({ rate: 53344000000000000 }, 10000 * H);
  near(c.ethRate(10000 * H), 53344000000000000, 1e-12, 'setRate to the cap');
  c.setSettings({ rateCap: 2.165e16 }, 10000 * H);
  near(c.rateAtCheckpoint, 2.165e16, 1e-12, 'a lower cap pulls the rate down now');
  near(c.ethRate(11000 * H), 2.165e16, 1e-12, 'and the climb clamps there');
  c.setSettings({ rateCap: 8.66e16 }, 11000 * H);
  near(c.ethRate(12000 * H), 8.66e16, 1e-12, 'a higher cap lets the climb go on');
}
// the redeem burn reserve (FLOW 86): feeToRedeemBurnBps of the fee eth fills it, the rest goes to the pot
{
  const d = new Core(Object.assign({}, DEFAULTS), 0); // launch values: 10 percent of fees to the reserve
  const r = d.addFees(8, 0);
  near(d.ethRedeemBurn, 0.8, 1e-12, 'launch reserve share of the fees'); near(d.ethPot, 7.2, 1e-12, 'the rest to the pot'); near(d.ethToBuyback, 0, 1e-12, 'nothing to the buyback pot'); near(d.feeToRedeemBurn, 0.8, 1e-12, 'booked');
  near(r.toRedeemBurn + r.toPot, 8, 1e-12, 'the fee split adds up');
  const e = new Core(Object.assign({}, DEFAULTS, { feeToRedeemBurnBps: 2500 }), 0);
  e.addFees(10, 0);
  near(e.ethRedeemBurn, 2.5, 1e-12, 'reserve share'); near(e.ethPot, 7.5, 1e-12, 'pot share');
  near(e.ethPot + e.ethToBuyback + e.ethRedeemBurn, 10, 1e-12, 'all of it is booked');
  // the reserve share does not enter the pot, so the funded flag and the clamp follow the pot alone
  const q = new Core(Object.assign({}, DEFAULTS, { rateCap: 1e18 }), 0); q.addFees(0.1, 0); near(q.clamp(), 0.09 * W, 1e-12, 'the clamp is the pot without the reserve');
  // sale proceeds follow saleToBuybackBps only
  const s = new Core(Object.assign({}, DEFAULTS), 0); s.sellTo({ cost: 1, t0: 0 }, 2, 0);
  near(s.ethRedeemBurn, 0, 1e-12, 'a sale does not fill the reserve'); near(s.ethToBuyback, 1, 1e-12, 'a sale sends saleToBuybackBps to the buyback');
}
// redemption eligibility (Core.redeemStatement, ControllerV1.atFloor): a module is set, redeemOn is true, and the statement's curve price has reached its floor, saleFloorBps of its price reference
{
  const mk = (over = {}) => { const c = fresh(Object.assign({ redeemOn: true, balanceBidOn: true, saleFloorBps: 10000 }, over), 10); c.setBalanceModule(0, 1e-5); return c; }; // the launch floors (FLOW 85)
  const c = mk();
  const st = c.compose(1, 0, 35200);
  assert.equal(c.redeemReady(st, 50 * H - 1), false); assert.equal(c.redeemReady(st, 50 * H), true); assert.equal(c.redeemReady(st, 5000 * H), true); n += 3; // the curve reaches its floor, the reference, at hour 50. the rate term scales the reference, not the hour
  assert.equal(fresh({ redeemOn: true, balanceBidOn: true }, 10).redeemReady(c.compose(1, 0), 9999 * H), false); n++; // no module, no redemption
  for (const [over, want] of [[{ redeemOn: false, balanceBidOn: false }, false], [{ redeemOn: false, balanceBidOn: true }, false], [{ redeemOn: true, balanceBidOn: false }, true], [{ redeemOn: true, balanceBidOn: true }, true]]) {
    const m = mk(over);
    assert.equal(m.redeemReady(m.compose(1, 0), 60 * H), want); assert.equal(m.redeemReady(m.compose(1, 0), 0), false); n += 2; // eligible by redeemOn only once the curve is at its floor
  }
  // the one floor: with saleFloorBps 12000 the curve rests at 120 percent of the reference, reached at hour 30, and the statement is eligible from there (ControllerV1.atFloor)
  const hi = mk({ saleFloorBps: 12000 }); const hs = hi.compose(1, 0); assert.equal(hi.redeemReady(hs, 9999 * H), true); assert.equal(hi.redeemReady(hs, 30 * H), true); assert.equal(hi.redeemReady(hs, 29 * H), false); near(hi.curvePrice(hs, 9999 * H), 1.2, 1e-12, 'the sale price is held at the floor'); n += 3;
  const lo = mk({ saleFloorBps: 5000 }); assert.equal(lo.redeemReady(lo.compose(1, 0), 250 * H), true); assert.equal(lo.redeemReady(lo.compose(1, 0), 249 * H), false); n += 2; // 50 hours of fast fall to the knee, 200 hours of slow fall to 50 percent
  // a sold or redeemed statement is gone
  const sold = c.compose(1, 0, 1); c.sellTo(sold, 1.5, 0); assert.equal(c.redeemReady(sold, 60 * H), false);
  const done = c.compose(1, 0, 1); assert.notEqual(c.redeemStatement(done, 60 * H), null); assert.equal(c.redeemReady(done, 61 * H), false); assert.equal(c.redeemStatement(done, 61 * H), null); assert.equal(c.sellTo(done, 9, 61 * H), null); n += 5;
  // the launch curve falls to cost and stays there (FLOW 85): at cost from hour 50 on, never below it
  const L = mk({ saleFloorBps: 10000 }); const ls = L.compose(1, 0, 1);
  near(L.curvePrice(ls, 50 * H), 1, 1e-12, 'launch curve at cost at hour 50'); near(L.curvePrice(ls, 5000 * H), 1, 1e-12, 'and at cost long after'); near(L.curvePrice(ls, 49 * H), 1.01, 1e-12, 'one hour before 101 percent');
  assert.equal(L.redeemReady(ls, 49.5 * H), false); assert.equal(L.redeemReady(ls, 50 * H), true); n += 2;
  // the pause holds the age, so eligibility holds its value through a pause: not at cost when paused at hour 40, at cost 50 hours of age after the resume
  const pz = mk({ saleFloorBps: 10000 }); const ps = pz.compose(1, 0, 1);
  pz.setPaused(true, 40 * H); assert.equal(pz.redeemReady(ps, 90 * H), false); pz.setPaused(false, 100 * H); assert.equal(pz.redeemReady(ps, 109 * H), false); assert.equal(pz.redeemReady(ps, 110 * H), true); n += 3;
  // the value floor does not move eligibility, which reads the curve price
  const vf = mk({ balancePoolSet: true }); const vs = vf.compose(1, 0, 1e6);
  ok(vf.askingPrice(vs, 60 * H) > 1, 'the asking price is above cost'); assert.equal(vf.redeemReady(vs, 60 * H), true); n++;
}
// Core.redeemStatement: the module returns rating * xpPerPoint, at least rating * xpPerPoint * (1 - redeemSlippageBps / 10000) or it reverts. the Core keeps all of it in balancePot.
// a redemption moves redeemBurnBps of the redeem burn reserve to the buyback pot
{
  const mk = (over = {}) => { const c = fresh(Object.assign({ redeemOn: true, balanceBidOn: true, feeToRedeemBurnBps: 1000, saleFloorBps: 10000, balancePoolSet: true }, over), 0); c.setBalanceModule(0, 1e-5); c.addFees(100, 0); return c; };
  const c = mk();
  near(c.ethRedeemBurn, 10, 1e-12, 'reserve'); near(c.ethPot, 90, 1e-12, 'pot');
  const r1 = c.redeemStatement(c.compose(1, 0, 35200), 60 * H);
  near(r1.received, 0.352, 1e-12, 'the module returns rating * xpPerPoint'); near(c.balancePot, 0.352, 1e-12, 'all of it in balancePot');
  near(r1.toBurn, 2, 1e-12, '20 percent of the reserve'); near(c.ethRedeemBurn, 8, 1e-12, 'the reserve falls'); near(c.ethToBuyback, 2, 1e-12, 'the buyback pot gets it'); near(c.redeemBurnMoved, 2, 1e-12, 'booked');
  const r2 = c.redeemStatement(c.compose(1, 0, 100), 60 * H);
  near(r2.toBurn, 1.6, 1e-12, '20 percent of what is left'); near(c.ethRedeemBurn, 6.4, 1e-12, 'reserve after two'); near(c.ethToBuyback, 3.6, 1e-12, 'buyback pot after two');
  near(c.balancePot, 0.352 + 0.001, 1e-12, 'balance token pot after two');
  near(c.ethPot, 90, 1e-12, 'the eth pot is not touched by a redemption');
  // slippage: 2 percent at launch. a module that returns 98 percent passes, 97 percent reverts and changes nothing
  const lo = mk({ redeemPayFrac: 0.98 }); ok(lo.redeemStatement(lo.compose(1, 0, 35200), 60 * H), 'a module under by exactly the tolerance passes');
  near(lo.balancePot, 0.352 * 0.98, 1e-12, 'the Core keeps what arrives');
  const un = mk({ redeemPayFrac: 0.97 }); const us = un.compose(1, 0, 35200);
  assert.equal(un.redeemStatement(us, 60 * H), null); assert.equal(un.balancePot, 0); near(un.ethRedeemBurn, 10, 1e-12, 'unchanged'); assert.equal(us.redeemed, undefined); n += 3;
  const wide = mk({ redeemPayFrac: 0.9, redeemSlippageBps: 1000 }); ok(wide.redeemStatement(wide.compose(1, 0, 35200), 60 * H), 'the tolerance is the setting');
  // redeemOn false refuses, redeemOn true redeems
  const off = mk({ redeemOn: false, balanceBidOn: false }); assert.equal(off.redeemStatement(off.compose(1, 0, 1), 60 * H), null); n++;
  const hold = mk({ redeemOn: true }); ok(hold.redeemStatement(hold.compose(1, 0, 1), 60 * H), 'hold mode redeems'); n++;
  // a statement whose curve price has not reached its floor does not redeem
  assert.equal(c.redeemStatement(c.compose(1, 0, 1), 10 * H), null); n++;
  // redeemBurnBps is a setting read at once; 0 moves nothing, 10000 moves the whole reserve
  const z = mk({ redeemBurnBps: 0 }); z.redeemStatement(z.compose(1, 0, 1), 60 * H); near(z.ethToBuyback, 0, 1e-12, 'redeemBurnBps 0'); near(z.ethRedeemBurn, 10, 1e-12, 'reserve stays');
  const f = mk({ redeemBurnBps: 10000 }); f.redeemStatement(f.compose(1, 0, 1), 60 * H); near(f.ethToBuyback, 10, 1e-12, 'redeemBurnBps 10000'); near(f.ethRedeemBurn, 0, 1e-12, 'whole reserve');
  const live = mk(); live.setSettings({ redeemBurnBps: 5000 }, 1); live.redeemStatement(live.compose(1, 0, 1), 60 * H); near(live.ethToBuyback, 5, 1e-12, 'the setting applies at once');
}
// the balance token bid (Core.sellForBalance, FLOW 84): runs while balanceBidOn is true, pays score * unitPerPoint * (1 - balanceBidMarginBps / 10000) per credit from balancePot,
// and a credit whose price is above the pot is refused. the eth bid stays flat per credit; this bid depends on the score
{
  const mk = (over = {}) => { const c = fresh(Object.assign({ redeemOn: true, balanceBidOn: true, balancePoolSet: true }, over), 10); c.setBalanceModule(0, 1e-5); c.balancePot = 1; return c; };
  const c = mk();
  near(c.xBidPrice(440), 440 * 1e-5 * 0.8, 1e-12, 'score times the per point amount less the 20 percent margin'); near(c.xBidPrice(80), 80 * 1e-5 * 0.8, 1e-12, 'a low score is paid less');
  near(c.xBidPrice(800), 2 * c.xBidPrice(400), 1e-12, 'linear in the score');
  near(c.xBuy(440), 440 * 1e-5 * 0.8, 1e-12, 'a buy pays the price'); near(c.balancePot, 1 - 440 * 1e-5 * 0.8, 1e-12, 'from balancePot'); near(c.xBuy(440), 440 * 1e-5 * 0.8, 1e-12, 'the price does not move with a fill');
  const small = mk(); small.balancePot = 0.003; assert.equal(small.xBuy(440), 0); near(small.balancePot, 0.003, 1e-15, 'a price above the pot is refused and nothing moves'); n++;
  near(small.xBuy(80), 80 * 1e-5 * 0.8, 1e-12, 'a cheaper credit fits'); 
  for (const over of [{ balanceBidOn: false }, { redeemOn: true, balanceBidOn: false }]) { const m = mk(over); assert.equal(m.balanceBidActive(), false); assert.equal(m.xBuy(440), 0); near(m.balancePot, 1, 1e-15, 'no bid with balanceBidOn false'); n += 2; }
  assert.equal(fresh({ redeemOn: true, balanceBidOn: true, balancePoolSet: true }, 10).balanceBidActive(), false); n++; // no module, no bid
  { const np = fresh({ redeemOn: true, balanceBidOn: true }, 10); np.setBalanceModule(0, 1e-5); np.balancePot = 1; assert.equal(np.balanceBidActive(), true); near(np.xBuy(440), 440 * 1e-5 * 0.8, 1e-12, 'the bid works without the pool key'); n += 2; } // the bid records the peak backstop and reads no pool (FLOW 96)
  // the margin is a setting read at once
  const g = mk(); assert.throws(() => g.setSettings({ balanceBidMarginBps: 0 }, 1), /redeemSlippageBps/); n++; g.setSettings({ redeemSlippageBps: 0, balanceBidMarginBps: 0 }, 1); near(g.xBidPrice(100), 100 * 1e-5, 1e-12, 'margin 0 pays the whole value'); g.setSettings({ balanceBidMarginBps: 9000 }, 2); near(g.xBidPrice(100), 100 * 1e-5 * 0.1, 1e-12, 'margin 90 percent');
  // buy at (1 - margin) and redeem at full value: the engine keeps the margin
  const h = mk(); const px = h.xBuy(35200 / 80 * 1); const rec = h.redeemStatement(h.compose(0, 0, 440 * 80), 5000 * H); // redeemed once the curve has reached its floor
  near(rec.received, 440 * 80 * 1e-5, 1e-12, 'the redemption returns the full value'); ok(rec.received > 80 * px, 'more than the 80 credits were bought for');
}
// a credit bought with the balance token enters the one pile at an eth cost (FLOW 96): the floor rate times score / refScore
// (CoreLib.sellForBalance), at least 1 wei. the floor rate is the larger of the price state and the remembered peak. it reads the price state and the peak,
// so the pool price never moves it and the bid needs no pool key
{
  const mk = (over = {}, pot = 10) => { const c = fresh(Object.assign({ redeemOn: true, balanceBidOn: true, balancePoolSet: true, rateStart: 1e15, rateCap: 1e16, climbPerMin: 0.5, recoveryClimbPerMin: 2, idleLoosenPct: 2, saleFloorBps: 10000 }, over), pot); c.setBalanceModule(0, 1e-5); c.balancePot = 1; return c; };
  // the peak is 0.001 eth per credit; 440 points is above refScore (4330000/1e4 = 433), so the backstop scales to 0.001 * 440 / 433
  const c = mk(); const r = c.xBuyCredit(440, 0); near(r.paid, 0.00352, 1e-12, 'the tokens paid'); near(r.cost, 0.001 * 440 / 433, 1e-12, 'the cost is the scaled peak backstop'); n += 2;
  const lo = mk({ balancePoolMult: 0.1 }), rl = lo.xBuyCredit(440, 0); near(rl.cost, 0.001 * 440 / 433, 1e-12, 'a pushed down pool price does not move the cost'); n++;
  const hi = mk({ balancePoolMult: 3 }), rh = hi.xBuyCredit(440, 0); near(rh.cost, 0.001 * 440 / 433, 1e-12, 'a pushed up pool price does not move the cost'); n++;
  const empty = mk({ rateStart: 4e15 }, 0); empty.balancePot = 1; const re = empty.xBuyCredit(1, 0); near(re.cost, 4e-3 / 433, 1e-12, 'an empty pot leaves the floor at the opening rate, scaled to one point'); n++;
  const under = mk(), ru = under.xBuyCredit(100, 0); near(ru.cost, 0.001 * 100 / 433, 1e-12, 'a score under refScore scales the cost down'); n++;
  const np = mk({ balancePoolSet: false }); const rn = np.xBuyCredit(440, 0); near(rn.cost, 0.001 * 440 / 433, 1e-12, 'the bid works with no pool key and records the backstop'); n++;
  const off = mk({ balanceBidOn: false }); assert.equal(off.xBuyCredit(440, 0), null); n++;
}
// Core.sellForBalance and Core.redeemStatement read unitPerPoint from the module in the call (decision 104), Core.releaseRedeemBurn (owner) moves reserve eth to the buyback pot
{
  const mk = (over = {}) => { const c = fresh(Object.assign({ redeemOn: true, balanceBidOn: true, feeToRedeemBurnBps: 1000, saleFloorBps: 10000, balancePoolSet: true }, over), 0); c.setBalanceModule(0, 1e-5); c.addFees(100, 0); c.balancePot = 1; return c; };
  const c = mk();
  near(c.xpLive, 1e-5, 1e-15, 'a module set reports its unit'); assert.equal(c.xpPerPoint, undefined); assert.equal(c.refreshUnitPerPoint, undefined); n += 2;
  // the module lowers its rate: the bid follows it
  c.moduleReports(6e-6);
  near(c.xBidPrice(440), 440 * 6e-6 * 0.8, 1e-12, 'the bid pays the live unit when it is lower');
  // the module raises its rate: the bid follows it as well
  c.moduleReports(2e-5);
  near(c.xBidPrice(440), 440 * 2e-5 * 0.8, 1e-12, 'the bid pays the live unit when it is higher');
  near(c.xBuy(440), 440 * 2e-5 * 0.8, 1e-12, 'a buy pays the live unit');
  // redemption: the module pays rating * live and the Core requires the slippage floor on the same live unit, so a moving unit never underpays by itself
  const up = c.redeemStatement(c.compose(1, 0, 35200), 60 * H);
  near(up.received, 35200 * 2e-5, 1e-12, 'the module pays at its live unit'); n++;
  const lo = mk(); lo.moduleReports(9.7e-6); ok(lo.redeemStatement(lo.compose(1, 0, 35200), 60 * H), 'a lower live unit redeems: the minimum follows it');
  const short = mk({ redeemPayFrac: 0.97 }); short.moduleReports(9.7e-6); assert.equal(short.redeemStatement(short.compose(1, 0, 35200), 60 * H), null); n++; // 3 percent under the live unit: Underpaid
  near(lo.xBidPrice(100), 100 * 9.7e-6 * 0.8, 1e-12, 'the bid follows the unit');
  const none = fresh({ redeemOn: true, balanceBidOn: true }, 10); assert.equal(none.balanceBidActive(), false); n++; // no module
  const zero = mk(); zero.moduleReports(0); assert.equal(zero.redeemStatement(zero.compose(1, 0, 35200), 60 * H), null); n++; // BadModule
  near(zero.xBidPrice(100), 0, 1e-15, 'a zero live unit pays nothing'); assert.equal(zero.xBuy(100), 0); assert.equal(zero.balanceBidActive(), false); n += 2;
  // releaseRedeemBurn: min(amount, reserve) moves to the buyback pot, the totals hold
  const r = mk(); near(r.ethRedeemBurn, 10, 1e-12, 'reserve');
  near(r.releaseRedeemBurn(4), 4, 1e-12, 'moves the amount'); near(r.ethRedeemBurn, 6, 1e-12, 'reserve falls'); near(r.ethToBuyback, 4, 1e-12, 'buyback pot rises'); near(r.redeemBurnMoved, 4, 1e-12, 'booked');
  near(r.releaseRedeemBurn(1e9), 6, 1e-12, 'capped at the reserve'); near(r.ethRedeemBurn, 0, 1e-12, 'reserve empty'); near(r.ethToBuyback, 10, 1e-12, 'whole reserve in the buyback pot');
  assert.equal(r.releaseRedeemBurn(1), null); const z0 = mk(); assert.equal(z0.releaseRedeemBurn(0), null); n += 2;
  near(r.ethPot, 90, 1e-12, 'the eth pot is untouched');
  // in a run: the schedule applies the owner calls, books close, the buyback pot is fed
  const base = { days: 30, seed: 4, balanceDay: 5, xpPerPoint: 3e-5 / 440, feeToRedeemBurnBps: 1000 };
  const mkRun = (schedule) => simulate(Object.assign({ stepSec: 3600 }, DEFAULTS, base, { schedule }));
  const none2 = mkRun([]), rel = mkRun([{ day: 10, patch: { releaseRedeemBurn: 1e9 } }]);
  const hr = 10 * 24 + 1; ok(none2.S.redeemBurn[hr] > 0 && rel.S.redeemBurn[hr] < 0.5 * none2.S.redeemBurn[hr] && rel.S.redeemBurnMoved[hr] > none2.S.redeemBurnMoved[hr], 'the owner release on day 10 drains the reserve to the buyback and books the move');
  ok(Math.abs(rel.stats.buybackCheck) < 1e-9 && Math.abs(rel.stats.redeemCheck) < 1e-9 && Math.abs(rel.stats.potCheck) < 1e-6, 'books close after a release'); n += 2;
  const low = mkRun([{ day: 8, patch: { moduleUnit: 3e-6 / 440 } }]);
  near(low.core.xpLive, 3e-6 / 440, 1e-18, 'the unit is the one the module reports now'); n++;
  ok(Math.abs(low.stats.potCheck) < 1e-6, 'books close with a lowered module unit'); n++;
}
// the pool term of valueOf (ControllerV1.valueOf, decision 104): points * unitPerPoint at the pool price joins the rate term once the pool key is set, with the unit read from the module at every call.
// the curve, the anchor and the redemption test read the engine price. refScore is raised to its bound and the rate cap holds the eth bid at the opening rate, so the rate term of the
// reference stays under cost
{
  const U = 2 / 60000, RS = { refScore: 8000000, rateCap: 8900000000000000, saleFloorBps: 10000 };
  const st = { cost: 1, t0: 0, rating: 60000 }; // pool term 2 eth
  const unset = fresh(Object.assign({ redeemOn: true, balanceBidOn: true }, RS), 10); unset.setBalanceModule(0, U);
  near(unset.askingPrice(st, 0), 1.5, 1e-12, 'pool key unset: the curve on the cost'); near(unset.poolTerm(60000), 0, 1e-15, 'and no pool term');
  const set = fresh(Object.assign({ redeemOn: true, balanceBidOn: true, balancePoolSet: true }, RS), 10);
  near(set.askingPrice(st, 0), 1.5, 1e-12, 'no balance module: the curve on the cost'); set.setBalanceModule(0, U);
  near(set.poolTerm(60000), 2, 1e-12, 'the pool term'); near(set.reference(st, 0), 2, 1e-12, 'the pool term lifts the reference above the cost');
  near(set.askingPrice(st, 0), 3, 1e-12, 'the curve starts at 150 percent of the lifted reference'); near(set.askingPrice(st, 40 * H), 2.2, 1e-12, 'and falls on it'); near(set.askingPrice(st, 100 * H), 2, 1e-12, 'to the floor, 100 percent of the reference');
  near(set.askingPrice({ cost: 1, t0: 0, rating: 1000 }, 0), 1.5, 1e-12, 'a low pool term leaves the reference at the cost');
  near(set.lowestPrice(st, 0), 2, 1e-12, 'the lowest price is the floor of the reference');
  assert.equal(set.atFloor(st, 49 * H), false); assert.equal(set.atFloor(st, 50 * H), true); n += 2; // eligibility reads the age, whatever lifts the reference
  const r = set.buy(set.compose(1, 0, 60000), 0);
  near(r.price, 3, 1e-12, 'the engine price'); near(r.royalty, 3 * 0.025, 1e-12, 'the royalty on it'); assert.equal(r.saleBps, 15000); assert.equal(set.anchorAt(0), 12500); n += 3; // the anchor moves on the curve in bps of the reference
  near(set.ethPot + set.ethToBuyback, 10 + 3, 1e-12, 'the Core books the engine price only'); near(set.royaltyOwed, 0.075, 1e-12, 'the controller owes the royalty');
  near(set.claimRoyalty(), 0.075, 1e-12, 'a claim pays it'); near(set.royaltyOwed, 0, 1e-15, 'and zeroes it'); assert.equal(set.claimRoyalty(), null); n += 2; // ZeroAmount
  // the unit is the one the module reports now, at the pool price (balancePoolMult)
  set.moduleReports(U / 2); near(set.poolTerm(60000), 1, 1e-12, 'a lower unit lowers the term'); set.moduleReports(U * 3); near(set.poolTerm(60000), 6, 1e-12, 'a higher unit raises it'); set.moduleReports(0); near(set.poolTerm(60000), 0, 1e-15, 'a zero unit leaves no term');
  const dn = fresh(Object.assign({ redeemOn: true, balanceBidOn: true, balancePoolSet: true, balancePoolMult: 0.5 }, RS), 10); dn.setBalanceModule(0, U); near(dn.poolTerm(60000), 1, 1e-12, 'a pool price at half the unit halves the term');
  // a small term cannot lower the price: the bound is the cost
  const lowv = fresh({ balancePoolSet: true }, 10); lowv.setBalanceModule(0, 1e-9);
  near(lowv.askingPrice({ cost: 1, t0: 0, rating: 10 }, 5000 * H), 0.75, 1e-12, 'the floor holds under a small term');
  const launch = fresh({ balancePoolSet: true, saleFloorBps: 10000 }, 10); launch.setBalanceModule(0, 1e-9);
  near(launch.askingPrice({ cost: 1, t0: 0, rating: 10 }, 5000 * H), 1, 1e-12, 'at the launch floor the price never goes under cost');
  n += 4;
}
// the price reference (ControllerV1.referenceOf, FLOW 95): reference = max(cost, ethPrice * rating / refScore), the eth bid rate before the pot clamp times the rating over
// refScore, computed at each call. the curve, its floor, the knee, the start price and the anchor are fractions of it. the Core hard floor stays on cost. refScore is the
// per-credit score in ten-thousandths of a point (4,330,000 = 433 points). the rate cap holds the eth bid at 1e16 so ethPrice / W is 0.01 per credit and the rate term of 80
// credits at 433 points is 0.8
{
  const L = { saleFloorBps: 10000, rateStart: 1e16, rateCap: 1e16 }, c = fresh(L, 10);
  near(c.ethPrice(0) / W, 0.01, 1e-15, 'the pinned per-credit eth rate'); n++;
  near(c.reference({ cost: 5, rating: 80 * 433 }, 0), 5, 1e-12, 'a cost over the rate term references cost'); // rate term 0.8 < 5
  near(c.reference({ cost: 0.5, rating: 80 * 433 }, 0), 0.8, 1e-12, 'the rate term over cost references the rate term'); // 0.01 * 80 = 0.8
  near(c.reference({ cost: 1, rating: 80 * 433 * 2 }, 0), 1.6, 1e-12, 'twice the rating references twice the rate term');
  near(c.reference({ cost: 2 }, 0), 2, 1e-12, 'a record without a rating references its cost'); n += 4;
  // the fix to decision 90: two statements of equal rating reference the same amount whatever each cost, once the rate term binds
  near(c.reference({ cost: 0.1, rating: 80 * 433 }, 0), c.reference({ cost: 0.4, rating: 80 * 433 }, 0), 1e-12, 'equal rating references the same whatever the cost');
  near(c.reference({ cost: 0.1, rating: 80 * 433 }, 0), 0.8, 1e-12, 'the shared rate term'); n += 2;
  const rich = { cost: 0.1, t0: 0, rating: 80 * 433 }; // reference 0.8, rate bound
  near(c.curvePrice(rich, 0), 0.8 * 1.5, 1e-12, 'the start price is 150 percent of the reference'); near(c.curvePrice(rich, 50 * H), 0.8, 1e-12, 'the floor is 100 percent of the reference at hour 50');
  near(c.curvePrice(rich, 5000 * H), 0.8, 1e-12, 'and stays there'); near(c.lowestPrice(rich, 0), 0.8, 1e-12, 'the lowest price is the reference'); n += 4;
  assert.equal(c.atFloor(rich, 49 * H), false); assert.equal(c.atFloor(rich, 50 * H), true); n += 2;
  // the Core hard floor is on cost: a rate term over cost raises the price, never the hard floor
  near(c.floorPrice(rich), 0.1, 1e-12, 'the hard floor is saleFloorBps of cost'); n++;
  // the reference moves with the eth bid at the call: doubling the stored rate doubles the reference
  const m = fresh({ saleFloorBps: 10000, rateStart: 1e16, rateCap: 2e16 }, 10);
  near(m.reference(rich, 0), 0.8, 1e-12, 'the reference at the opening rate'); m.setSettings({ rate: 2e16 }, 1);
  near(m.ethPrice(1) / W, 0.02, 1e-12, 'the owner doubled the eth bid'); near(m.reference(rich, 1), 1.6, 1e-12, 'the reference doubled with it'); n += 3;
  // a buy at the start price moves the anchor by the same bps at any rating (the sale price in bps of the reference)
  const r1 = c.buy({ cost: 0.1, t0: 0, rating: 80 * 433 }, 0), d = fresh(L, 10), r2 = d.buy({ cost: 0.1, t0: 0, rating: 80 * 433 * 2 }, 0);
  assert.equal(r1.saleBps, 15000); assert.equal(r2.saleBps, 15000); assert.equal(c.anchorAt(0), d.anchorAt(0)); near(r2.price, 2 * r1.price, 1e-12, 'twice the rating is paid twice as much'); n += 4;
  // refScore is a controller setting read at once: a higher refScore shrinks the rate term, and cost binds once it falls under cost
  const e = fresh(L, 10); near(e.reference({ cost: 0.6, rating: 80 * 433 }, 0), 0.8, 1e-12, 'before the change the rate term binds'); e.setSettings({ refScore: 8000000 }, 0); near(e.reference({ cost: 0.6, rating: 80 * 433 }, 0), 0.6, 1e-12, 'refScore 800 points shrinks the rate term under cost, which is the reference'); n += 2;
  assert.throws(() => e.setSettings({ refScore: 0 }, 2), /refScore/); assert.throws(() => e.setSettings({ refScore: 8000001 }, 2), /refScore/); n += 2;
}
// the credit sale window (ControllerV1.creditPrice, FLOW 88, 92, 93, 94): off at launch. floor = max(cost, floorRate, valueOf(score)) * creditFloorBps / 10000 (decision 115), start = floor *
// creditStartBps / 10000, a straight line over creditWindow from the acquisition time, resting at the floor. Core.sellCreditTo takes at least the cost, creditCostToPotBps of the cost
// to the pot and the rest of the payment to the buyback pot. compose waits for the window while the sale is on
{
  // the rate is flat here (the contract minimum climb), so the floor is the cost; the long run check below climbs
  const mk = (over = {}, pot = 10) => fresh(Object.assign({ creditSaleOn: true, rateStart: 1e15, rateCap: 1e16, climbPerMin: 0.01, recoveryClimbPerMin: 0.01, idleLoosenPct: 2 }, over), pot);
  const cr = { pts: 440, cost: 0.002, t0: 0 }, W4 = 4 * H;
  const c = mk();
  ok(DEFAULTS.creditSaleOn === false && fresh({}, 10).cr.creditSaleOn === false, 'the credit sale is off at launch'); n++;
  near(c.ethPrice(0) / W, 1e-3, 1e-9, 'the eth bid before the clamp'); // the bid is under the cost here: the cost term wins
  near(c.creditFloor(cr, 0), 0.002 * 1.1, 1e-12, 'floor = cost * 11000 / 10000'); near(c.creditPrice(cr, 0), 0.002 * 1.1 * 3, 1e-12, 'start = floor * 30000 / 10000');
  near(c.creditPrice(cr, W4 / 2), 0.002 * 1.1 * 2, 1e-12, 'half way down at half the window'); near(c.creditPrice(cr, W4), 0.002 * 1.1, 1e-12, 'the floor at the end of the window'); near(c.creditPrice(cr, W4 + 60), 0.002 * 1.1, 1e-12, 'and just after it'); const cl = mk({ climbPerMin: 0.5, recoveryClimbPerMin: 2 }); near(cl.creditPrice(cr, 1000 * H), 0.01 * (440 / 433) * 1.1, 1e-9, 'long after the window the floor follows the climbed floor rate capped at rateCap, scaled by the score');
  n += 6;
  // the rate term: a cost under it is floored at it, read before the pot clamp (an empty pot does not zero it). 440 points scales it by 440 / 433, a score under refScore scales it down
  const e = mk({ rateStart: 4e15, rateCap: 1e16 }, 0.0001);
  near(e.ethRate(0), 0.0001 * W, 1e-12, 'the clamped read is the pot'); near(e.ethPrice(0) / W, 4e-3, 1e-12, 'the price state is unclamped'); near(e.creditFloor(cr, 0), 4e-3 * (440 / 433) * 1.1, 1e-12, 'the floor follows the unclamped rate term');
  const low = { pts: 200, cost: 0.0001, t0: 0 }; near(e.valueOf(200, 0), 4e-3 * (200 / 433), 1e-12, 'a score under refScore scales the rate term down'); near(e.creditFloor(low, 0), 4e-3 * 1.1, 1e-12, 'the floor rate itself floors the credit sale (decision 115), whatever the score'); n += 5;
  // the pool term: score * unit at the pool price, 0 until the pool key and the module are set, and the unit is the one the module reports now
  const b = mk({ redeemOn: true, balanceBidOn: true, balancePoolSet: true }); near(b.poolTerm(440), 0, 1e-15, 'no module: pool term 0'); b.setBalanceModule(0, 1e-5);
  near(b.poolTerm(440), 440 * 1e-5, 1e-12, 'pool term = score * unit'); near(b.creditFloor(cr, 0), 440 * 1e-5 * 1.1, 1e-12, 'a pool term over the cost sets the floor');
  b.moduleReports(5e-6); near(b.poolTerm(440), 440 * 5e-6, 1e-12, 'the unit the module reports now'); near(b.creditFloor({ pts: 440, cost: 0.003, t0: 0 }, 0), 0.003 * 1.1, 1e-12, 'a pool term under the cost leaves the cost'); n += 5;
  assert.equal(mk({ balancePoolSet: false }).poolTerm(440), 0); n++;
  // valueOf is the larger of the rate term and the pool term, and the royalty adds royaltyBps of the price on top of every credit sale
  near(b.valueOf(440, 0), Math.max(b.poolTerm(440), (b.floorRate(0) / W) * (440 / 433)), 1e-12, 'valueOf is the larger term'); near(b.valueOf(0, 0), 0, 1e-15, 'no points, no value');
  near(c.grossCreditPrice(cr, 0), c.creditPrice(cr, 0) * 1.025, 1e-12, 'the gross credit price adds royaltyBps 250'); n += 3;
  // sellCreditTo and buyCredit: the cost share to the pot, the rest to the buyback pot, never under the cost
  const s = mk(), pot0 = s.ethPot, sold = { pts: 440, cost: 0.004, t0: 0 }, price = s.creditPrice(sold, W4);
  const res = s.buyCredit(sold, W4); ok(res !== null && sold.sold === true, 'sold at once'); near(res.price, price, 1e-12, 'the price paid'); near(res.toPot, 0.004, 1e-12, 'creditCostToPotBps 10000: the cost to the pot'); near(res.toBuyback, price - 0.004, 1e-12, 'the markup to the buyback pot');
  near(s.ethPot - pot0, 0.004, 1e-12, 'the pot has the cost'); near(s.ethToBuyback, price - 0.004, 1e-12, 'the buyback pot has the rest'); n += 6;
  assert.equal(s.sellCreditTo({ pts: 1, cost: 0.004, t0: 0 }, 0.00399, 0), null); ok(s.sellCreditTo({ pts: 1, cost: 0.004, t0: 0 }, 0.004, 0) !== null, 'the cost is the hard floor'); assert.equal(s.buyCredit(sold, W4), null); n += 3; // a credit sells once
  const half = mk({ creditCostToPotBps: 5000 }); const hs = { pts: 1, cost: 0.004, t0: 0 }, hp = half.ethPot; const hr = half.buyCredit(hs, W4);
  near(hr.toPot, 0.002, 1e-12, 'creditCostToPotBps 5000: half the cost to the pot'); near(half.ethPot - hp, 0.002, 1e-12, 'booked'); near(half.ethToBuyback, hr.price - 0.002, 1e-12, 'the rest to the buyback pot'); n += 3;
  // off: no sale. paused: no sale. the window gates compose only while the sale is on
  assert.equal(fresh({}, 10).buyCredit({ pts: 1, cost: 0.004, t0: 0 }, 0), null); const pz = mk(); pz.setPaused(true, 0); assert.equal(pz.buyCredit({ pts: 1, cost: 0.004, t0: 0 }, 5), null); n += 2;
  assert.equal(c.pastWindow(0, W4 - 1), false); assert.equal(c.pastWindow(0, W4), true); assert.equal(fresh({}, 10).pastWindow(0, 0), true); n += 3;
  // bounds of the credit settings (src/lib/CreditBounds.sol) and the setters, at once
  assert.throws(() => c.setSettings({ creditWindow: 59 }, 1), /creditWindow/); assert.throws(() => c.setSettings({ creditFloorBps: 9999 }, 1), /creditFloorBps/); assert.throws(() => c.setSettings({ creditStartBps: 200001 }, 1), /creditStartBps/);
  assert.throws(() => c.setSettings({ creditCostToPotBps: 10001 }, 1), /creditCostToPotBps/); n += 4;
  c.setSettings({ creditSaleOn: false, creditWindow: 7200, creditFloorBps: 12000, creditStartBps: 20000, chosenComposeOn: true, minCcToChoose: 5 }, 1);
  assert.equal(c.cr.creditSaleOn, false); assert.equal(c.cr.creditWindow, 7200); assert.equal(c.cr.chosenComposeOn, true); n += 3;
}

// buyback slice and the caller payment (docs/DECISIONS.md 61): the caller is paid 270,000 gas at min(basefee, keeperMaxBaseFee) plus keeperFee out of the slice.
// the swap budget is the slice less the largest payment (600,000 gas at the capped rate plus keeperFee), the unspent part of that reserve goes back to the pot
{
  const c = fresh(); c.ethToBuyback = 2.5; // 1 gwei base fee, keeperFee 0.0005, keeperMaxBaseFee 10 gwei
  const a = c.takeBuybackSlice(1000);
  near(a.slice, 0.5, 1e-12, 'slice is at most 0.5 eth');
  near(a.tip, 270000e-9 + 0.0005, 1e-12, 'payment is 270,000 gas at 1 gwei plus the keeper fee');
  near(a.budget, 0.5 - (600000e-9 + 0.0005), 1e-12, 'the swap budget is the slice less the reserve');
  near(c.ethToBuyback, 2.0 + (600000e-9 - 270000e-9), 1e-12, 'the unspent reserve is back in the buyback pot');
  assert.equal(c.takeBuybackSlice(1000 + 299), null); n++; // 25 blocks = 300 s
  ok(c.takeBuybackSlice(1000 + 300));
  near(c.ethToBuyback, 1.5 + 2 * (600000e-9 - 270000e-9), 1e-12, 'pool after two slices');
  // a base fee above keeperMaxBaseFee is paid at the cap
  const hi = fresh({ basefeeGwei: 50 }); hi.ethToBuyback = 2.5;
  near(hi.takeBuybackSlice(0).tip, 270000 * 10e-9 + 0.0005, 1e-12, 'paid at the 10 gwei cap');
  const lo = fresh({ basefeeGwei: 5 }); lo.ethToBuyback = 2.5;
  near(lo.takeBuybackSlice(0).tip, 270000 * 5e-9 + 0.0005, 1e-12, 'below the cap the actual base fee');
  // a slice under twice the largest payment is not called (SliceTooSmall), nothing moves. the reserve is 600,000 gas at 10 gwei plus 0.0005 = 0.0065
  const small = fresh({ basefeeGwei: 50, buybackSlice: 0.0131 }); small.ethToBuyback = 0.0129;
  assert.equal(small.takeBuybackSlice(0), null); near(small.ethToBuyback, 0.0129, 1e-15, 'the pot is untouched'); assert.equal(small.lastBuybackTime, -1e12); n += 2;
  small.ethToBuyback = 0.0131; ok(small.takeBuybackSlice(0), 'a slice of exactly twice the payment is called');
  // a small pot pays a share of the fee: the swap budget over the largest budget the setting allows
  const part = fresh({ basefeeGwei: 10 }); part.ethToBuyback = 0.0265; // slice 0.0265, budget 0.02, largest budget 0.5 - 0.0065
  near(part.takeBuybackSlice(0).tip, 270000 * 10e-9 + 0.0005 * 0.02 / (0.5 - 0.0065), 1e-12, 'the keeper fee scales with the budget');
  // the buybackSlice bound at its edge: 2 * (600,000 gas * keeperMaxBaseFee + keeperFee)
  ok(firstViolation(Object.assign({}, SETTINGS, { buybackSlice: 0.0131 })) === null, 'just above twice the launch payment is inside'); n++;
  assert.equal(firstViolation(Object.assign({}, SETTINGS, { buybackSlice: 0.0129 })), 'buybackSlice'); n++;
  const free = fresh({ keeperFee: 0, basefeeGwei: 1 }); free.ethToBuyback = 1;
  near(free.takeBuybackSlice(0).tip, 270000e-9, 1e-12, 'no keeper fee leaves the gas refund');
  assert.throws(() => free.setSettings({ keeperFee: 0.0051 }, 0), /keeperFee/); assert.throws(() => free.setSettings({ keeperMaxBaseFee: 0.9 }, 0), /keeperMaxBaseFee/);
  assert.throws(() => free.setSettings({ keeperMaxBaseFee: 101 }, 0), /keeperMaxBaseFee/); n += 3;
  ok(firstViolation(Object.assign({}, SETTINGS, { keeperFee: 0.005, keeperMaxBaseFee: 100 })) === null, 'the upper bounds are inside'); n++;
  ok(SETTINGS.keeperTipBps === undefined, 'keeperTipBps is gone from the model'); n++;
}
// launch position: whole supply single sided, price 2.513e-8 eth per coin at the start tick
{
  const p = new Pool(DEFAULTS);
  near(p.price, 2.5131970949402153e-8, 1e-12, 'start price');
  near(p.coinInPool(), 1e9, 1e-9, 'whole supply in the position');
  const out = p.buy(80);
  near(p.price * 1e9, 439.7878, 1e-4, 'fdv after 80 eth net buys, matches the observed day one end price');
  near(p.ethInPool(), 80, 1e-9, 'eth in the position');
  const back = p.sell(80);
  near(back.eth, 80, 1e-12, 'round trip eth'); near(back.coin, out, 1e-9, 'round trip coin');
  near(p.price, 2.5131970949402153e-8, 1e-9, 'back at the start');
  ok(p.sell(1).eth < 1e-9); // nothing to sell below the start tick
}
// skim schedule: anti sniper 90 points falling to the 6.9 point baseline over 30 minutes. the Core gets 90 percent of the baseline
// plus the whole extra, after the window the payee takes 75,185 ppm of the income
{
  near(skimFraction(DEFAULTS, 0), 0.9, 1e-12, 'launch skim'); near(skimFraction(DEFAULTS, 900), (0.9 + 0.069) / 2, 1e-12, 'midway');
  near(skimFraction(DEFAULTS, 1800), 0.069, 1e-12, 'end of window'); near(skimFraction(DEFAULTS, 99999), 0.069, 1e-12, 'baseline');
  near(bountyFeeFraction(DEFAULTS, 0.069), 0.0665022, 1e-12, 'Core 6.65022 points'); near(bountyFeeFraction(DEFAULTS, 0.9), 0.0665022 + 0.831, 1e-12, 'extra to the Core');
  // Core._book: the payee takes payeePpm of each book once payeeOn. the first book at or after sniperSeconds with income sets payeeOn and takes 0
  const pc = new Core(DEFAULTS, 0);
  pc.addFees(100, 1799); near(pc.ethPot, 90, 1e-12, 'before the window the pot gets 90 of 100, the reserve 10'); near(pc.payeeOwed, 0, 1e-12, 'the payee gets 0 before the window');
  pc.addFees(100, 1800); near(pc.ethPot, 180, 1e-12, 'the first book at the window end shares 0'); ok(pc.payeeOn && pc.payeeOwed === 0, 'the payee share starts');
  pc.addFees(100, 1900); near(pc.payeeOwed, 7.5185, 1e-12, 'the payee takes payeePpm after the window');
  near(pc.ethPot, 180 + 83.23335, 1e-9, 'the pot gets the income less the payee and the reserve share');
  near(pc.ethRedeemBurn, 20 + 9.24815, 1e-9, 'the reserve takes feeToRedeemBurnBps of the income after the payee');
  const pz = new Core(DEFAULTS, 0); pz.addFees(0, 5000); ok(!pz.payeeOn, 'a zero income book leaves payeeOn false');
  // Core.fund: whole, the payee and reserve shares are 0
  const pf = new Core(DEFAULTS, 0); pf.addFees(100, 1900); pf.fund(50, 1900);
  near(pf.ethPot, 90 + 50, 1e-12, 'fund adds to the pot whole'); near(pf.ethRedeemBurn, 10, 1e-12, 'fund books a reserve share of 0'); near(pf.payeeOwed, 0, 1e-12, 'and a payee share of 0');
  let d0 = 0;
  for (let t = 0; t < 3600; t += 120) d0 += stepVolume(DEFAULTS, t, 120);
  near(d0, 1557 * 0.586, 1e-9, 'first hour volume');
  for (let h = 1; h < 24; h++) d0 += stepVolume(DEFAULTS, h * 3600, 3600);
  near(d0, 1557, 1e-9, 'day one volume');
}
// whole runs: deterministic, every eth identity closes, nothing negative
{
  const a = simC({ days: 20, seed: 3 }), b = simC({ days: 20, seed: 3 }), c = simC({ days: 20, seed: 4 });
  assert.deepEqual(a.S.pot, b.S.pot); n++;
  assert.notDeepEqual(a.S.pot, c.S.pot); n++;
  for (const r of [a, simC({ days: 40, saleFloorBps: 6000, seed: 5 }), simC({ days: 40, feeToRedeemBurnBps: 2500, seed: 6 }), simC({ days: 40, basefeeGwei: 40, seed: 9 }), simC({ days: 40, buyerWaits: 'floor', feeToRedeemBurnBps: 10000, seed: 8 }), simC({ days: 40, balanceDay: 12, xpPerPoint: 3e-5 / 440, stmtPick: 'random' }), simC({ days: 40, balanceDay: 12, balanceDayMode: 1, feeToRedeemBurnBps: 1000, seed: 11 }), simC({ days: 40, balanceDay: 12, balancePoolSet: true, feeToRedeemBurnBps: 3000, seed: 12 })]) {
    ok(Math.abs(r.stats.potCheck) < 1e-6, 'pot accounting ' + r.stats.potCheck);
    ok(Math.abs(r.stats.buybackCheck) < 1e-9, 'buyback accounting ' + r.stats.buybackCheck);
    ok(Math.abs(r.stats.redeemCheck) < 1e-9, 'redeem burn reserve accounting ' + r.stats.redeemCheck);
    ok(Math.abs(r.stats.saleCheck) < 1e-9, 'sale accounting ' + r.stats.saleCheck);
    ok(Math.abs(r.stats.royaltyCheck) < 1e-9, 'royalty accounting ' + r.stats.royaltyCheck);
    for (const k of ['pot', 'toBuyback', 'locked', 'burned']) ok(r.S[k].every((x) => x >= -1e-12), k + ' negative');
    ok(r.S.burned[r.H] <= 1e9);
  }
  // the engine never stops buying because statements are unsold: no buyers at all, statements pile up, credits keep coming
  const none = simC({ days: 30, stmtPerDay: 0, stmtFloorPerDay: 0, seed: 3 });
  ok(none.T.sold === 0 && none.S.waiting[none.H] > 100, 'no statement sells, many wait');
  ok(none.S.credits[none.H] > 0.8 * simC({ days: 30, seed: 3 }).S.credits[30 * 24], 'credits keep coming with no statement buyers, at least 80 percent of the base run at day 30');
  // every sale clears at or above the hard floor (cost * saleFloorBps) and at or above the price the buyer saw
  const bo = simC({ days: 30, seed: 3 });
  ok(bo.T.sold > 0 && bo.T.soldPrice >= bo.T.soldFloor * (1 - 1e-9), 'sales clear at or above the hard floor');
  ok(bo.stats.saleOverCost >= 0.75 && bo.stats.saleOverCost <= 1.5, 'average sale price over cost sits between the floor and the start');
  const boEnd = bo.core.anchorAt(bo.H * 3600); ok(boEnd >= 10000 && boEnd <= bo.core.c.startCapBps, 'the anchor stays between 10000 and the cap'); ok(bo.stats.finalAnchorBps === boEnd, 'stats carry the anchor');
  // the pessimistic run: a buyer who waits for the floor pays the lowest price of every statement it takes, and none sells young
  const wf = simC({ days: 30, seed: 3, buyerWaits: 'floor' });
  ok(wf.T.sold > 0 && wf.stats.saleOverCost >= 0.75 - 1e-9 && wf.stats.saleAtFloorShare === 1, 'waiting buyers pay the floor, saleFloorBps of the reference, which is at least 75 percent of the cost (FLOW 90)');
  ok(wf.stats.saleAgeHours >= 150, 'and only after the asking price has reached it');
  // a settings change mid run: controller settings on day 5, the floors and splits on day 10, all read at once
  const sw = simC({ days: 20, seed: 3, schedule: [{ day: 5, patch: { markupBps: 13000, decayHours: 24 } }, { day: 10, patch: { saleFloorBps: 6000, feeToRedeemBurnBps: 2500, saleToBuybackBps: 7500 } }] });
  assert.equal(sw.core.c.floorBps, undefined); assert.equal(sw.core.s.saleFloorBps, 6000); n += 2;
  assert.equal(sw.core.c.markupBps, 13000); assert.equal(sw.core.c.decayHours, 24); assert.equal(sw.core.s.saleToBuybackBps, 7500); assert.equal(sw.core.s.feeToRedeemBurnBps, 2500); assert.equal(sw.T.settingsChanges, 2); n += 4;
  ok(sw.core.feeToRedeemBurn > 0, 'the fee share starts at its change'); ok(Math.abs(sw.stats.potCheck) < 1e-6, 'accounting closes across settings changes');
  ok(Math.abs(sw.stats.buybackCheck) < 1e-9, 'buyback accounting closes across settings changes');
  const f0 = simC({ days: 20, seed: 3 }), f1 = simC({ days: 20, seed: 3, feeToRedeemBurnBps: 10000 });
  assert.equal(f0.core.feeToRedeemBurn, 0); ok(f1.core.feeToRedeemBurn > 0.9 * f1.S.cumFees[f1.H], 'at 10000 every fee goes to the reserve'); n++;
  ok(f1.T.sold >= 0 && f1.S.credits[f1.H] < f0.S.credits[f0.H], 'sending the fees to the reserve leaves less to buy credits');
  // the buyer's willingness to pay is a multiple of the MARKET cost of 80 credits, the asking price a share of what the engine PAID: a low willingness
  // sells less under the same asking curve (the engine paid more than market for most parts), and lowering the asking curve lets it buy again
  const w55 = simC({ days: 30, seed: 3, wtpMult: 0.55 }), w100 = simC({ days: 30, seed: 3 });
  ok(w55.T.sold > 0 && w55.T.sold < 0.7 * w100.T.sold, 'a lower willingness to pay sells fewer statements at the same asking prices');
  const w55low = simC({ days: 30, seed: 3, wtpMult: 0.55, markupBps: 10000, saleFloorBps: 3000 });
  ok(w55low.T.sold > 1.8 * w55.T.sold, 'the same buyers buy more when the asking curve is lower'); ok(w55low.stats.saleOverCost < 0.5, 'and they pay a lower share of cost');
  const p2 = simC({ days: 30, balanceDay: 10, xpPerPoint: 3e-5 / 440, seed: 3 });
  ok(p2.T.redeemed > 0 && p2.T.redeemedAge > 0, 'held statements are redeemed through the balanceModule');
  const s = summary(a); ok(s.credits > 0 && s.statements > 0 && (s.potGoneDay === null || s.potGoneDay > 1), 'summary reads the run: the pot is spent after day one, or lasts the 20 days');
}
// whole runs at the launch values (FLOW 85, 86): statements fall to their reference and wait there while redeemOn is false, the redeem burn reserve takes 10 percent of the fees,
// the balance side in hold mode redeems at the floor and stops the bid, the balance side on adds the balance token bid, whose credits join the one pile (FLOW 92)
{
  const base = { days: 30, seed: 3, stepSec: 300 };
  const L = simulate(base);
  const closes = (r, tag) => { ok(Math.abs(r.stats.potCheck) < 1e-6 && Math.abs(r.stats.saleCheck) < 1e-9 && Math.abs(r.stats.buybackCheck) < 1e-9 && Math.abs(r.stats.redeemCheck) < 1e-9, 'accounting closes ' + tag); };
  closes(L, 'at launch');
  ok(L.core.s.redeemOn === false && L.core.s.balanceBidOn === false && L.T.redeemed === 0 && L.T.boughtX === 0 && L.core.balancePot === 0, 'both switches false: no redemption, no balance token bid');
  ok(L.T.sold > 0 && L.T.soldPrice >= L.T.soldCost * (1 - 1e-9), 'every sale clears at or above cost (the launch hard floor)');
  // the start price follows the anchor, so the curve reaches its floor, the reference, (startBps - 10000) / 100 hours after listing
  const endSec = L.H * 3600, hoursToCost = (L.core.startBps(endSec) - 10000) / 100, old = L.unbid.filter((st) => endSec - st.t0 >= hoursToCost * H);
  ok(L.unbid.length > 100 && old.length > 20, 'statements wait'); ok(old.every((st) => Math.abs(L.core.askingPrice(st, endSec) - L.core.reference(st, endSec)) < 1e-12 * L.core.reference(st, endSec)), 'and every one past that age is asked at its reference');
  ok(L.unbid.every((st) => L.core.askingPrice(st, endSec) >= st.cost * (1 - 1e-12)), 'none is asked under its cost');
  near(L.core.feeToRedeemBurn, 0.1 * (L.T.fees + L.T.feesBuyback - L.core.payeeOwed), 1e-9, 'the reserve takes 10 percent of the fees booked'); near(L.core.ethRedeemBurn, L.core.feeToRedeemBurn, 1e-12, 'the reserve equals the fee share, redemptions and releases aside');
  ok(L.core.redeemBurnMoved === 0, 'no redemption, no move to the buyback');
  // the pot buys with the other 90 percent
  const noRes = simulate(Object.assign({ feeToRedeemBurnBps: 0 }, base));
  ok(noRes.S.credits[noRes.H] > L.S.credits[L.H] * 0.99 - 1, 'a reserve share of 0 leaves the pot with the whole fee stream, at least as many credits');
  // hold: redemptions at the floor, the bid stopped
  const hold = simulate(Object.assign({ balanceDay: 10, balanceDayMode: 1 }, base));
  closes(hold, 'in hold');
  ok(hold.T.redeemed > 0 && hold.T.boughtX === 0 && hold.core.balancePot > 0, 'hold mode redeems and keeps the balance token without a bid');
  ok(hold.core.redeemBurnMoved > 0 && hold.core.ethRedeemBurn < hold.core.feeToRedeemBurn, 'each redemption moves part of the reserve to the buyback');
  ok(hold.T.redeemedAge / hold.T.redeemed >= 50 * H - 1, 'a statement redeems no earlier than its curve reaches its floor (hour 50)');
  ok(hold.T.redeemedValue > 0 && hold.core.balancePot === hold.T.xRecv, 'the balance token pot is what the redemptions returned');
  // on: the bid buys credits at the margin under their value into the one pile and the statements built from them sell or redeem like the rest. the bid needs no pool key (FLOW 96)
  const on = simulate(Object.assign({ balanceDay: 10, balancePoolSet: true }, base));
  closes(on, 'with the bid');
  ok(on.T.boughtX > 0 && on.core.redeemBurnMoved > 0, 'the bid buys and redemptions release the reserve');
  ok(on.T.redeemed > 0 && on.core.balancePot > 0, 'statements redeem');
  ok(on.S.credits[on.H] > hold.S.credits[hold.H], 'the bid adds credits'); ok(on.T.composed > hold.T.composed, 'and they compose into statements through the one pile');
  const noKey = simulate(Object.assign({ balanceDay: 10 }, base)); ok(noKey.T.boughtX > 0 && noKey.T.redeemed > 0, 'the bid buys without the pool key and redemptions run (FLOW 96)'); closes(noKey, 'without the pool key');
  // a later switch off stops the bid at once
  const off = simulate(Object.assign({ balanceDay: 10, balancePoolSet: true, schedule: [{ day: 12, patch: { redeemOn: false, balanceBidOn: false } }] }, base));
  ok(off.T.boughtX > 0 && off.S.xBought[off.H] === off.S.xBought[12 * 24 + 1], 'both switches false on day 12 ends the bid and the redemptions'); ok(off.S.redeemed[off.H] === off.S.redeemed[12 * 24 + 1], 'no redemption after the switch off'); closes(off, 'after a switch off');
  // the pool key (value floor) raises the price a buyer pays and changes nothing else about eligibility
  const pool = simulate(Object.assign({ balanceDay: 10, balanceDayMode: 1, balancePoolSet: true, xpPerPoint: 4e-4 }, base));
  closes(pool, 'with the value floor');
}
// whole runs with the credit sale window (FLOW 88): the books close, every credit sells at or above its cost, the proceeds split by creditCostToPotBps, compose waits for the window,
// and a run with the sale off is the run without the feature. chosen composition (FLOW 89) with a composer that names the richest credits builds richer statements
{
  const base = { days: 30, seed: 3, stepSec: 300 };
  const off = simulate(base), on = simulate(Object.assign({ creditSaleOn: true }, base));
  ok(Math.abs(off.stats.creditCheck) < 1e-12 && off.T.creditSold === 0 && off.stats.potCheck < 1e-6, 'the sale is off at launch: no credit sells'); n++;
  assert.deepEqual(simulate(Object.assign({ creditCostToPotBps: 5000 }, base)).S.credits, off.S.credits); n++; // a setting of a feature that is off changes nothing
  ok(on.T.creditSold > 50, 'credits sell through the window'); ok(Math.abs(on.stats.creditCheck) < 1e-9, 'the sale proceeds split exactly');
  ok(Math.abs(on.stats.potCheck) < 1e-6 && Math.abs(on.stats.saleCheck) < 1e-9 && Math.abs(on.stats.buybackCheck) < 1e-9 && Math.abs(on.stats.redeemCheck) < 1e-9, 'accounting closes with the credit sale');
  ok(on.T.creditGross >= on.T.creditCost * 1.1 * (1 - 1e-9), 'every credit sells at or above 110 percent of its cost (the floor, creditFloorBps 11000)'); near(on.T.creditToPot, on.T.creditCost, 1e-9, 'creditCostToPotBps 10000: the cost goes back to the pot');
  near(on.T.creditToBuyback, on.T.creditGross - on.T.creditCost, 1e-9, 'and the markup to the buyback pot'); n += 6;
  // the royalty (decision 112): royaltyBps of every engine price, statements and credits, is owed on top and never reaches the pots
  near(on.T.royalty, 0.025 * (on.T.saleGross + on.T.creditGross), 1e-9, 'royaltyBps 250 of every sale and credit sale'); near(on.core.royaltyOwed, on.T.royalty, 1e-12, 'owed to the recipient');
  const noRoy = simulate(Object.assign({ creditSaleOn: true, royaltyBps: 0 }, base)); near(noRoy.T.royalty, 0, 1e-15, 'royaltyBps 0 collects nothing'); n += 3;
  const maxRoy = simulate(Object.assign({ creditSaleOn: true, royaltyBps: 1000 }, base)); near(maxRoy.T.royalty, 0.1 * (maxRoy.T.saleGross + maxRoy.T.creditGross), 1e-9, 'royaltyBps 1000'); n++;
  assert.throws(() => on.core.setSettings({ royaltyBps: 1001 }, 1), /royaltyBps/); n++;
  const half = simulate(Object.assign({ creditSaleOn: true, creditCostToPotBps: 5000 }, base));
  near(half.T.creditToPot, 0.5 * half.T.creditCost, 1e-9, 'creditCostToPotBps 5000'); ok(half.T.creditToBuyback > on.T.creditToBuyback * 0.9 && Math.abs(half.stats.creditCheck) < 1e-9, 'the rest goes to the buyback pot'); n += 2;
  // compose waits for the window: with a 4 hour window no statement is composed from a credit younger than that
  const w = simulate(Object.assign({ creditSaleOn: true, creditWindow: 48 * H }, base)), seen = [];
  const watch = simulate(Object.assign({ creditSaleOn: true, creditWindow: 48 * H, onStep: (t, core, Pe, rr, T) => { if (T.composed > seen.length) seen.push(t); } }, base));
  ok(w.T.composed > 0 && w.T.composed <= off.T.composed, 'a longer window composes later, not more'); ok(watch.pile.every((c) => c.t0 <= watch.H * 3600), 'the pile holds credits of any age'); n += 2;
  ok(seen.length > 0 && seen[0] >= 48 * H, 'no statement before a credit has waited out a 48 hour window'); n++;
  const paused = simulate(Object.assign({ creditSaleOn: true, schedule: [{ day: 1, patch: { paused: true } }] }, base)); ok(paused.T.creditMiss > 0 && paused.T.creditSold < on.T.creditSold, 'sales are paused, credit sales too'); n++;
  const mid = simulate(Object.assign({ schedule: [{ day: 10, patch: { creditSaleOn: true } }] }, base)); ok(mid.T.creditSold > 0 && mid.S.creditSold[10 * 24] === 0, 'the owner turns the sale on mid run'); n++;
  // chosen composition: a composer that names the richest ready credits builds richer statements than compose() does from the oldest
  const win = { creditSaleOn: true, creditWindow: 24 * H, days: 30, seed: 4, stepSec: 300, stmtPerDay: 2 };
  const std = simulate(win), pick = simulate(Object.assign({ chosenComposeOn: true, composeChoice: 'richest' }, win));
  ok(pick.T.composedChosen > 0 && std.T.composedChosen === 0, 'composeChosen runs only when the owner opens it'); ok(pick.T.stRating / pick.T.composed > std.T.stRating / std.T.composed, 'and the statements it builds are richer');
  const gated = simulate(Object.assign({ composeChoice: 'richest' }, win)); assert.equal(gated.T.composedChosen, 0); assert.deepEqual(gated.S.composed, std.S.composed); n += 4; // the composer needs chosenComposeOn
  ok(Math.abs(pick.stats.potCheck) < 1e-6 && Math.abs(pick.stats.creditCheck) < 1e-9, 'the books close with chosen composition'); n++;
}
// sub-hour step: five minute and one minute steps give the same economy within 10 percent, and the books close. the hourly step is a
// different run here: the stepped rule reads its drop floor and climb per minute, and an hour step distorts it
{
  const h = simL({ days: 30, seed: 1 }), h2 = simL({ days: 30, seed: 1, stepSec: 3600 });
  assert.deepEqual(h.S.credits, h2.S.credits); n++;
  const m5 = simL({ days: 30, seed: 1, stepSec: 300 }), m1 = simL({ days: 30, seed: 1, stepSec: 60 });
  near(m5.S.credits[m5.H], m1.S.credits[m1.H], 0.1, 'credits at a five minute step are within 10 percent of the one minute step');
  for (const m of [m5, m1]) {
    ok(Math.abs(m.stats.potCheck) < 1e-6 && Math.abs(m.stats.saleCheck) < 1e-6, 'accounting closes at a sub hour step');
    assert.equal(m.S.pot.length, h.S.pot.length); n++;
  }
  assert.throws(() => simL({ days: 2, stepSec: 7 })); n++;
}
// bid rule: the stepped rule (CoreLib.climb and drop)
{
  const R = 1e13, MIN = 60;
  const mk = (over) => fresh(Object.assign({ rateStart: R, idleLoosenPct: 0 }, over), 1000); // idleLoosenPct 0 here: the ceiling is ceilPct of the anchor
  // stepped: a fixed drop per credit, a floor of dropToPct of the bid at the first fill of the timestamp, a ceiling of ceilPct of the last rate paid
  {
    const c = mk({ dropPerCreditPct: 0.5, dropToPct: 80, climbPerMin: 1, ceilPct: 125 });
    ok(c.spend(0.001, 0));
    near(c.rateAtCheckpoint, R * 0.995, 1e-12, 'one credit drops the bid 0.5 percent');
    ok(c.spend(0.001, 0)); near(c.rateAtCheckpoint, R * 0.995 * 0.995, 1e-12, 'a second credit in the same minute drops it again');
    for (let i = 0; i < 100; i++) c.spend(0.001, 0);
    near(c.rateAtCheckpoint, R * 0.8, 1e-12, 'a burst of fills in one minute cannot drop the bid below 80 percent of the bid at its first fill');
    // the next minute opens a new burst from the current bid
    c.spend(0.001, 60); near(c.rateAtCheckpoint, R * 0.8 * 1.01 * 0.995, 1e-9, 'a new timestamp starts a new burst, after one minute of climb');
    // ceiling: the bid never climbs above 125 percent of the last rate paid
    near(c.ethRate(60 + 1000 * MIN), c.lastPaidRate * 1.25, 1e-12, 'ceiling is ceilPct of the last rate paid');
    near(c.lastPaidRate, R * 0.8 * 1.01, 1e-9, 'the last rate paid is the rate of the last fill');
    // climb below the ceiling: 10 minutes at 1 percent
    const t = 60 + 1000 * MIN; c.checkpoint(t); c.spend(0.001, t);
    const r0 = c.rateAtCheckpoint; near(c.ethRate(t + 10 * MIN), Math.min(r0 * Math.pow(1.01, 10), c.lastPaidRate * 1.25), 1e-12, 'climb after 10 minutes');
    // before any fill the ceiling is the opening bid times ceilPct
    const d = mk({ climbPerMin: 2, ceilPct: 110 });
    near(d.ethRate(1000 * MIN), R * 1.1, 1e-12, 'opening ceiling is rateStart times ceilPct');
    near(d.ethRate(3 * MIN), R * Math.pow(1.02, 3), 1e-12, 'climb 2 percent a minute');
  }
  // CoreLib.drop: the minute floor belongs to the bucket now / 60. fills at seconds 0 and 59 share one floor, a fill at second 60 starts a new one
  {
    const c = mk({ dropPerCreditPct: 10, dropToPct: 80, climbPerMin: 0.1, recoveryClimbPerMin: 0.1, ceilPct: 300 });
    c.spend(0.001, 0); c.spend(0.001, 30); c.spend(0.001, 59); // 0.9, 0.81, then the floor 0.8 of the first fill
    near(c.rateAtCheckpoint, R * 0.8, 1e-12, 'seconds 0 to 59 are one bucket, the floor holds at 80 percent of the first fill');
    const first = c.rateAtCheckpoint; c.spend(0.001, 60);
    near(c.rateAtCheckpoint, first * Math.pow(1.001, 1 / 60) * 0.9, 1e-6, 'second 60 is a new bucket: no floor from the earlier fills');
  }
  // stepped recovery: after a fill the price state is below the remembered peak and climbs at recoveryClimbPerMin until it
  // reaches the peak, then at climbPerMin. the peak decays over peakHalfLifeHours and anchors the ceiling
  {
    const R = 1e13, MIN = 60;
    const c = fresh({ rateStart: R, climbPerMin: 0.5, recoveryClimbPerMin: 2, ceilPct: 150, peakHalfLifeHours: 6, dropToPct: 50, dropPerCreditPct: 50 }, 1000);
    // one fill drops the bid to 50 percent of R, the peak stays at R
    ok(c.spend(0.001, 0));
    near(c.rateAtCheckpoint, R * 0.5, 1e-12, 'the fill halves the bid');
    near(c.peakRate, R, 1e-12, 'the peak stays at the pre fill price');
    // one minute later the bid climbs at the fast recovery rate (2 percent), not the slow rate
    near(c.ethRate(MIN), R * 0.5 * 1.02, 1e-9, 'below the peak the bid climbs at recoveryClimbPerMin');
    // the fast climb reaches the peak, then the slow rate takes over: faster than a pure slow climb would be
    const slowOnly = fresh({ rateStart: R, climbPerMin: 0.5, recoveryClimbPerMin: 0.5, ceilPct: 150, peakHalfLifeHours: 6, dropToPct: 50, dropPerCreditPct: 50 }, 1000);
    ok(slowOnly.spend(0.001, 0));
    ok(c.ethRate(30 * MIN) > slowOnly.ethRate(30 * MIN), 'recovery reaches the pre fill price sooner than the slow climb');
    // the ceiling anchors on the peak, so right after the fill the bid may climb back toward the pre fill level
    ok(c.stepCeil(MIN) > R, 'the ceiling anchors on the remembered peak, above the dropped rate');
  }
  // the recovery gap: a fill that walks the bid down less than recoveryGapPct leaves the bid above the recovery level,
  // so it climbs at the slow rate, not the recovery rate (CoreLib._recover gapped level, review M1)
  {
    const R = 1e13, MIN = 60;
    // a single credit drop of 0.5 percent stays inside the 10 percent gap: the climb is the slow climbPerMin
    const c = fresh({ rateStart: R, climbPerMin: 0.5, recoveryClimbPerMin: 2, recoveryGapPct: 10, ceilPct: 150, peakHalfLifeHours: 6, dropToPct: 50, dropPerCreditPct: 0.5 }, 1000);
    ok(c.spend(0.001, 0));
    near(c.rateAtCheckpoint, R * 0.995, 1e-12, 'the single credit drop is 0.5 percent');
    near(c.ethRate(MIN), R * 0.995 * 1.005, 1e-9, 'inside the gap the bid climbs at the slow rate');
    // a zero gap restores the old rule: the same small drop starts on the fast recovery climb, so a minute later the
    // bid is higher than under the gap (the fast leg here is short because the drop is only 0.5 percent under the peak)
    const g0 = fresh({ rateStart: R, climbPerMin: 0.5, recoveryClimbPerMin: 2, recoveryGapPct: 0, ceilPct: 150, peakHalfLifeHours: 6, dropToPct: 50, dropPerCreditPct: 0.5 }, 1000);
    ok(g0.spend(0.001, 0));
    ok(g0.ethRate(MIN) > c.ethRate(MIN), 'with no gap the small drop climbs faster than under the gap');
  }
  // whole runs: books close, the stepped bid stays at or under its ceiling at the end of a run, the throttler sells at its fraction of the market
  const rs = (share) => share * 0.0089e18;
  for (const o of [{ ceilPct: 110 }, { ceilPct: 150, climbPerMin: 2, recoveryClimbPerMin: 2 }]) {
    const r = simL(Object.assign({ days: 6, seed: 2, stepSec: 60, rateStart: rs(1), climbPerMin: 1 }, o));
    ok(Math.abs(r.stats.potCheck) < 1e-6 && Math.abs(r.stats.saleCheck) < 1e-6, 'accounting closes under ceilPct ' + o.ceilPct);
    ok(r.S.credits[r.H] > 0 && r.stats.idleHoursMax >= 0);
    ok(r.core.ethRate(r.H * 3600) <= r.core.stepCeil(r.H * 3600) * (1 + 1e-9) || r.core.ethRate(r.H * 3600) <= r.core.clamp(), 'the bid is under its ceiling or the pot at the end of a run');
  }
  const a = simL({ days: 4, seed: 2, stepSec: 60, rateStart: rs(1) }), b = simL({ days: 4, seed: 2, stepSec: 60, rateStart: rs(1), throttler: true });
  ok(a.T.throttled === 0 && b.T.throttled > 0, 'the throttler sells credits when on');
  ok(Math.abs(b.stats.potCheck) < 1e-6, 'accounting closes with the throttler');
  // market paths
  const q = (path, h, o = {}) => pathPrice(Object.assign({}, DEFAULTS, { pricePath: path }, o), h * 3600) / DEFAULTS.priceP0;
  near(q('falling', 24), 0.5, 1e-12, 'falling halves over day one'); near(q('falling', 500), 0.5, 1e-12, 'falling stays flat after');
  near(q('rising', 7 * 24), 2, 1e-12, 'rising doubles over 7 days'); near(q('rising', 24 * 30), 2, 1e-12, 'rising stays flat after');
  near(q('whipsaw', 48), 1, 1e-12, 'whipsaw before the fall'); near(q('whipsaw', 60), 0.4, 1e-12, 'whipsaw falls 60 percent in 12 hours');
  near(q('whipsaw', 108), 1, 1e-12, 'whipsaw recovers over 2 days'); near(q('whipsaw', 300), 1, 1e-12, 'whipsaw flat after');
}
// clamp, askFloor
{
  const R = 1e13, MIN = 60;
  const c1 = fresh({ rateStart: R, climbPerMin: 50, ceilPct: 1000, rateCap: 1e18 }, 0.1);
  near(c1.clamp(), 0.1 * W, 1e-12, 'clamp affords one credit: the pot');
  const f = simL({ days: 3, seed: 2, askFloor: 0.8 });
  const g = simL({ days: 3, seed: 2 }); ok(f.stats.costVsMarket >= g.stats.costVsMarket - 0.2, 'a floor on seller asks does not lower the price paid');
}
// idle loosening of the stepped ceiling anchor, gap path, forced fill, bot drain, stall metric
{
  const R = 1e13, MIN = 60;
  const c = fresh({ rateStart: R, climbPerMin: 100, ceilPct: 110, idleLoosenPct: 1 }, 1000);
  near(c.ethRate(5 * MIN), R * 1.1, 1e-12, 'before the first interval the ceiling is ceilPct of the anchor');
  near(c.ethRate(25 * MIN), R * 1.1 * (1 + 0.01 * 2), 1e-12, 'two idle intervals raise the anchor by 1 percent of itself each, linearly');
  ok(c.spend(0.001, 25 * MIN)); const lp = c.lastPaidRate;
  near(c.ethRate(25 * MIN + 9 * MIN), Math.min(c.rateAtCheckpoint * Math.pow(2, 9), lp * 1.1), 1e-12, 'a fill resets the idle clock');
  near(c.ethRate(25 * MIN + 31 * MIN), lp * 1.1 * (1 + 0.01 * 3), 1e-12, 'three intervals after the fill');
  const o = fresh({ rateStart: R, climbPerMin: 100, ceilPct: 110, idleLoosenPct: 0.01 }, 1000);
  near(o.ethRate(10000 * MIN), R * 1.1 * (1 + 0.0001 * Math.floor(10000 * MIN / 600)), 1e-12, 'the contract minimum idleLoosenPct 0.01 loosens the ceiling by 0.01 percent per full 10 idle minutes');
  const q = (h, g) => pathPrice(Object.assign({}, DEFAULTS, { pricePath: 'gap', gapPct: g, gapHour: 6 }), h * 3600) / DEFAULTS.priceP0;
  near(q(5.9, 30), 1, 1e-12, 'gap path before the jump'); near(q(6, 30), 1.3, 1e-12, 'gap path after the jump'); near(q(80, 100), 2, 1e-12, 'gap path stays');
  const rs = (share) => share * 0.0089e18;
  const base = { days: 2, seed: 2, stepSec: 60, rateStart: rs(1) };
  const ff = simC(Object.assign({ forceFillHour: 6, forceFillFrac: 0.5 }, base));
  ok(Math.abs(ff.stats.potCheck) < 1e-6, 'accounting closes with a forced fill'); ok(ff.T.throttled === 0, 'a forced fill is not counted as a throttler credit');
  const st0 = simC(Object.assign({ pricePath: 'gap', gapPct: 300, gapHour: 6, idleLoosenPct: 0.01, days: 3 }, { seed: 2, stepSec: 60, rateStart: rs(1) }));
  const st1 = simC(Object.assign({ pricePath: 'gap', gapPct: 300, gapHour: 6, idleLoosenPct: 2, days: 3 }, { seed: 2, stepSec: 60, rateStart: rs(1) }));
  ok(st0.stats.stallHours > st1.stats.stallHours, 'idle loosening shortens the stall after a gap up'); ok(st0.stats.stallRuns.length >= 1 && st0.stats.stallHoursMax > 2, 'a stall run is recorded');
}
// stepped: the clamp bounds the bid that is read and paid, and is never stored. the drop and the anchor use the price state rate
{
  const R = 1e13, MIN = 60;
  const c = fresh({ rateStart: R, climbPerMin: 1, ceilPct: 125 }, 3e-6);
  const clamp = c.clamp(); ok(clamp < R / 3, 'the clamp of a 3e-6 eth pot is far under the stored rate');
  near(c.ethRate(0), clamp, 1e-12, 'the read bid is held at the clamp');
  near(c.priceRate(0), R, 1e-12, 'the price state rate is the stored rate');
  const paid = c.sellForEth(0); near(paid, clamp / W, 1e-12, 'a fill pays the read (clamped) bid');
  near(c.lastPaidRate, R, 1e-12, 'the anchor is the price state rate at the fill, not the clamped bid');
  near(c.rateAtCheckpoint, R * 0.995, 1e-12, 'the drop applies to the price state rate');
  c.addFees(1000, 10 * MIN);
  near(c.ethRate(10 * MIN), R * 0.995, 1e-12, 'the price state held its value while above the clamp, it did not climb');
  near(c.ethRate(20 * MIN), Math.min(R * 0.995 * Math.pow(1.01, 10), R * 1.25), 1e-9, 'once the pot affords it the price state climbs again from the held value');
  const z = fresh({ rateStart: R, climbPerMin: 1, ceilPct: 125, dropPerCreditPct: 1 }, 0);
  near(z.ethRate(0) + 1e-30, 1e-30, 1e-6, 'an empty pot reads 0 whether funded or not'); ok(!z.funded);
  const w = fresh({ rateStart: R, dropPerCreditPct: 1, dropToPct: 80 }, 1000);
  w.spend(0.001, 0); w.rateAtCheckpoint = R * 0.5; w.checkpointTime = 0; w.lastPaidRate = R * 0.5; w.spend(0.001, 0);
  near(w.rateAtCheckpoint, R * 0.5 * 0.99, 1e-9, 'the minute floor restarts at a price that is already under it');
  const e = fresh({ rateStart: R / 10, climbPerMin: 1, ceilPct: 1000 }, 5e-6);
  near(e.priceRate(1000 * MIN), e.clamp(), 1e-12, 'the climb target is the clamp when it is under the ceiling'); near(e.ethRate(1000 * MIN), e.clamp(), 1e-12, 'read at the clamp');
  const d = fresh({ rateStart: R, climbPerMin: 1, ceilPct: 125, rateCap: R * 1.2 }, 1000);
  near(d.ethRate(100 * MIN), R * 1.2, 1e-12, 'rateCap bounds the price state'); d.rateAtCheckpoint = R * 3; near(d.ethRate(100 * MIN), R * 1.2, 1e-12, 'a stored rate above a bound reads as the bound');
}
// the unmodified defaults are the launch run: minute steps, the launch fee split, books close
{
  const r = simulate({ days: 6, seed: 3 });
  ok(r.params.stepSec === 60, 'the default run is the launch rule at minute steps');
  ok(Math.abs(r.stats.potCheck) < 1e-6 && Math.abs(r.stats.saleCheck) < 1e-6, 'accounting closes on the default run');
  ok(r.stats.rateMaxBidRatio < 1.6, 'the default bid stays under 1.6x the market (rate cap and ceiling): ' + r.stats.rateMaxBidRatio);
  ok(summary(r, 6).credits > 5000, 'the default run buys credits in week one');
}
console.log(`ok, ${n} checks passed`);
