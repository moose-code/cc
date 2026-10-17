// Focused numerical model checks and integer vectors. EVM parity requires separate Solidity execution.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { runSpendCapStudy } from './market.mjs';
import { Core, SpendBucket, balanceConversion, Pool, DEFAULTS, SETTINGS, CONTROLLER, CREDIT, CREDIT_CONFIG_KEY, creditViolation, simulate, controllerViolation, quoteViolation, QUOTE, summary, firstViolation, skimFraction, pathPrice, bountyFeeFraction, stepVolume, W, UNIT_PER_POINT, DECIMALS, redeemQuote } from './engine.js';

let n = 0;
const near = (a, b, tol, msg) => {
  n++;
  const rel = Math.abs(a - b) / Math.max(Math.abs(b), 1e-300);
  assert.ok(rel <= tol, `${msg}: got ${a}, want ${b}, rel err ${rel}`);
};
const ok = (c, msg) => { n++; assert.ok(c, msg); };
const H = 3600;
// LEGACY: the checks below that hand compute a single bid (a 0.0067 eth opening rate, one percent a minute climb, feeToRedeemBurnBps 0) run on it, with the 12 hour statement line, the anchor fraction 5000, the credit start 30000 and no reserve floor the curve checks were written for. the launch floor (saleFloorBps 10000) and split (saleToBuybackBps 5000 with no artist or operator cut) are kept so the hand computed curves rest at cost; the launch values have their own checks against mainnet.json
const LEGACY = { spendCapBps: 10000, multiplierCap: 1, stepSec: 3600, rateStart: 6.668e15, climbPerMin: 1, recoveryClimbPerMin: 1, dropPerCreditPct: 0.5, idleLoosenPct: 0.01, ceilPct: 300, rateCap: 53344000000000000, saleToBuybackBps: 5000, saleToArtistBps: 0, saleToOperatorBps: 0, feeToRedeemBurnBps: 0, decayHours: 12, anchorMoveBps: 5000, creditStartBps: 30000, reserveWei: 0 };
// whole market runs price the rate per 100 points: the per credit rates above are per 433 point credit (the calibration credit), and so is the 0.5 percent drop, so simL rescales them by 100 / 433 (the drop to whole basis points)
const PER_100 = 100 / 433;
const simL = (o = {}) => simulate(Object.assign({}, LEGACY, { rateStart: LEGACY.rateStart * PER_100, rateCap: LEGACY.rateCap * PER_100, dropPerCreditPct: Math.round(LEGACY.dropPerCreditPct * PER_100 * 100) / 100 }, o));
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
// promise: carries a field of the rules in docs/DECISIONS.md section 9 it must match, and a field of the old rules (reserveBps) must be gone from the model
{
  const cfg = JSON.parse(fs.readFileSync(new URL('../script/config/mainnet.json', import.meta.url), 'utf8'));
  // the stepped bid fields of the Core, config name to model name (percent and hours in the model)
  const STEPPED = { dropPer100PointsBps: 115, dropFloorBps: 1, climbPerMinBps: 200, ceilBps: 11000, idleLoosenBps: 600, peakHalfLife: 21600, recoveryClimbPerMinBps: 200, recoveryGapBps: 1000 };
  const STEPPED_SIM = { dropPerCreditPct: 'dropPer100PointsBps', dropToPct: 'dropFloorBps', climbPerMin: 'climbPerMinBps', ceilPct: 'ceilBps', idleLoosenPct: 'idleLoosenBps', recoveryClimbPerMin: 'recoveryClimbPerMinBps', recoveryGapPct: 'recoveryGapBps', peakHalfLifeHours: 'peakHalfLife' };
  for (const [k, v] of Object.entries(STEPPED)) near(cfg.settings[k], v, 1e-12, 'launch stepped bid rule ' + k);
  // the sim defaults are the launch bid rule, field for field with the config (bps to percent). the model has one bid rule
  ok(DEFAULTS.bidRule === undefined, 'the bid rule is one rule: the model carries no bidRule key');
  near(DEFAULTS.dropPerCreditPct, cfg.settings.dropPer100PointsBps / 100, 1e-12, 'default dropPerCreditPct');
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
    near(SETTINGS[k], k === 'buybackSlice' || k === 'keeperFee' || k === 'callerFee' || k === 'swapFeeCc' || k === 'reserveWei' ? v / 1e18 : k === 'keeperMaxBaseFee' || k === 'callerMaxBaseFee' ? v / 1e9 : v, 1e-12, 'setting ' + k);
  }
  for (const k of Object.keys(SETTINGS)) ok(cfg.settings[STEPPED_SIM[k] ?? k] !== undefined, 'the config carries ' + k);
  for (const k of Object.keys(cfg.settings)) ok(k in STEPPED || k in SETTINGS, 'the model carries ' + k);
  for (const k of Object.keys(CONTROLLER)) near(+CONTROLLER[k], k === 'anchorMinCost' ? +cfg.sale[k] / 1e18 : +cfg.sale[k], 1e-12, 'controller ' + k); // eth in the model, wei in the config
  assert.deepEqual(Object.keys(cfg.sale).sort(), Object.keys(CONTROLLER).sort()); n++; // the sale block and the model carry the same fields
  // the launch rateStart is 100 percent of market
  near(cfg.rateStart, 0.0049 * W, 1e-4, 'launch rateStart is 0.0049 eth per 100 points (decision 145, refreshed 2026-10-16)');
  // the launch rate cap is the config value and 3 times rateStart
  near(SETTINGS.rateCap, cfg.settings.rateCap, 1e-12, 'launch rateCap'); near(cfg.settings.rateCap, 3 * cfg.rateStart, 1e-12, 'launch rateCap is 3 times rateStart');
  // the pool and payee values of the v2 launch
  for (const k of ['baselineSkimBps', 'bountyBps', 'sniperStartBps']) near(DEFAULTS[k], cfg.launch[k], 1e-12, 'launch ' + k);
  near(DEFAULTS.sniperSeconds, cfg.launch.sniperSeconds, 1e-12, 'launch sniperSeconds');
  near(DEFAULTS.sniperEndBps, cfg.launch.baselineSkimBps, 1e-12, 'the sniper skim falls to the baseline');
  ok(cfg.launch.lpFeePips === undefined, 'the lp fee is implicit on the master stack (decision 126), so the model has no lp income');
  near(SETTINGS.payeePpm, cfg.settings.payeePpm, 1e-12, 'payeePpm'); near(SETTINGS.payeePpm, 0, 1e-12, 'payeePpm 0 at launch (decision 120)');
  near(SETTINGS.saleToArtistBps, cfg.settings.saleToArtistBps, 1e-12, 'saleToArtistBps'); near(SETTINGS.saleToOperatorBps, cfg.settings.saleToOperatorBps, 1e-12, 'saleToOperatorBps');
  near(SETTINGS.swapFeeCc, cfg.settings.swapFeeCc / 1e18, 1e-12, 'swapFeeCc whole coins'); near(SETTINGS.swapFeeCc, 10000, 1e-12, 'swapFeeCc is ten thousand coins');
  // the fee split (decision 120): 10 points of volume skim, bountyBps 9000 to the engine, 10000 - bountyBps the protocol leg
  near(cfg.launch.baselineSkimBps, 1000, 1e-12, 'baseline skim 10 points'); near(cfg.launch.bountyBps, 9000, 1e-12, 'bounty 9000'); near(10000 - cfg.launch.bountyBps, 1000, 1e-12, 'the protocol leg is 1000'); n += 3;
  // the credit block (the Credit struct of the launch config) is the model's CREDIT, field for field, and the launch values are the ones of FLOW 88 to 90
  assert.deepEqual(Object.keys(cfg.credit).sort(), Object.values(CREDIT_CONFIG_KEY).sort()); n++; // the config credit block is the model's CREDIT, field for field (decision 123 dropped royaltyRecipient)
  for (const [k, ck] of Object.entries(CREDIT_CONFIG_KEY)) near(+CREDIT[k], +cfg.credit[ck], 1e-12, 'credit ' + k);
  assert.deepEqual(CREDIT, { creditCostToPotBps: 8000, chosenComposeOn: false, minCcToChoose: 1e18, creditSaleOn: true, creditWindow: 4 * H, creditSpreadBps: 1000, creditStartBps: 15000 }); n++;
  ok(CREDIT.royaltyBps === undefined && cfg.credit.royaltyBps === undefined, 'the royalty is gone from the model and the config (decision 123)'); n++;
  assert.equal(creditViolation(CREDIT), null); n++;
  assert.equal(firstViolation(SETTINGS), null); n++;
  assert.equal(controllerViolation(CONTROLLER), null); n++;
  // the launch rules: statements fall to cost and stay there (FLOW 85), the balance bid starts off and redeemOn is true (decision 119), the whole engine share of the skim goes to the buying pot at launch (feeToRedeemBurnBps 0, decision 155; the phase-2 wiring sets it to 1,000), and each redemption releases 20 percent of the redeem burn reserve
  assert.deepEqual(CONTROLLER, { markupBps: 15000, startCapBps: 100000, decayHours: 4, anchorHalfLife: 7 * 24 * H, anchorMinCost: 0.1, anchorMoveBps: 0 }); n++;
  assert.equal(SETTINGS.saleFloorBps, 10000); assert.equal(SETTINGS.feeToBuybackBps, undefined); assert.equal(SETTINGS.feeToRedeemBurnBps, 0); n += 3;
  assert.equal(SETTINGS.redeemOn, true); assert.equal(SETTINGS.balanceBidOn, false); assert.equal(SETTINGS.balanceMode, undefined); assert.equal(SETTINGS.redeemSlippageBps, 200); assert.equal(SETTINGS.balanceBidMarginBps, 1000); assert.equal(SETTINGS.redeemBurnBps, 2000); n += 6;
  ok(SETTINGS.redeemAfter === undefined && SETTINGS.balanceToBuybackBps === undefined && SETTINGS.xAuctionHalfLife === undefined && SETTINGS.balanceSliceCredits === undefined && SETTINGS.balanceLaneToBuybackBps === undefined && SETTINGS.xRateCap === undefined, 'the balance token auction is gone from the model');
  ok(DEFAULTS.balancePoolSet === false && DEFAULTS.balanceDay === null, 'the balance token pool key is unset and the balance side is off at launch');
}
// promise: the model has the one pile and the atFloor name: no lanes, no composeBalance, no atCost (FLOW 92, 90)
{
  const src = fs.readFileSync(new URL('./engine.js', import.meta.url), 'utf8');
  ok(!/\bLane\b|composeBalance|atCost|xHeld|xPile|ethPile|balanceLane|ethLane|creditScoreModule|scoreModule/.test(src), 'no lanes, no composeBalance, no atCost, no score module in the model');
  ok(Core.prototype.atFloor !== undefined && Core.prototype.atCost === undefined, 'atFloor replaces atCost');
}
// promise: the owner pause (Core.setPaused): the age a price falls with excludes every paused second, a buy refuses while paused, a repeat changes nothing
{
  const c = fresh({}, 10); // start 150 percent, floor 100 percent (the launch saleFloorBps 10000), a straight 12 hour line on cost 1
  const price = (h) => 1.5 - (0.5 * Math.min(h, 12)) / 12;
  const st = { cost: 1, t0: 0 };
  const before = c.askingPrice(st, 4 * H);
  near(before, price(4), 1e-12, 'hour 4 of the launch curve');
  c.setSettings({ paused: true }, 4 * H);
  assert.equal(c.isPaused(), true); assert.equal(c.buy(st, 8 * H), null); assert.equal(st.sold, undefined);
  near(c.askingPrice(st, 50 * H), before, 1e-12, 'the price is held through the pause');
  c.setPaused(true, 20 * H); assert.equal(c.pausedSince, 4 * H); // a repeat leaves the start of the pause
  c.setSettings({ paused: false }, 54 * H); c.setPaused(false, 55 * H); assert.equal(c.pausedTotal, 50 * H); // a repeat leaves the total
  near(c.askingPrice(st, 54 * H), before, 1e-12, 'the price at the resume is the price at the pause');
  near(c.askingPrice(st, 55 * H), price(5), 1e-12, 'the fall continues an hour after the resume');
  const during = { cost: 1, t0: 20 * H, pauseMark: 16 * H }; // composed inside the pause (16 paused hours before it): age zero at the resume
  near(c.askingPrice(during, 54 * H), price(0), 1e-12, 'a statement composed during the pause starts aging at the resume');
  c.setPaused(true, 60 * H); c.setPaused(false, 62 * H);
  near(c.askingPrice(st, 62 * H), price(10), 1e-12, 'two pauses (50 and 2 hours): age 10 hours at hour 62');
  assert.throws(() => c.setSettings({ paused: 'yes' }, 0), /paused/);
  assert.equal(c.buy(st, 70 * H) !== null, true); n += 10;
}
// promise: no inventory gate and no dutch statement auction anywhere
{
  const src = fs.readFileSync(new URL('./engine.js', import.meta.url), 'utf8');
  ok(!/inventoryGate|setGate|gated|AUCTION_START|AUCTION_FLOOR|AUCTION_LENGTH|buyStatement|bidMode/.test(src), 'no trace of the gate or the dutch auction');
  ok(!/auctionDuration|buyOnly|houseOwed|collectSales|bidOn|minBid/.test(src), 'no trace of the pnd auction house or auction mode');
  ok(DEFAULTS.inventoryGate === undefined && Core.prototype.setGate === undefined, 'no gate in the defaults or the Core');
  ok(!/reserveBps/.test(src) && DEFAULTS.reserveBps === undefined && Core.prototype.reprice === undefined, 'reserveBps is gone from the model, the reprice step is folded into the first bid');
}
// promise: climb: the price state climbs climbPerMin percent a minute, compounded (CoreLib.climb). the ceiling is raised above its bounds here so it does not bind
{
  const c = fresh({ rateCap: 1e21, ceilPct: 1e6 });
  near(c.ethRate(1 * H), R0 * Math.pow(1.01, 60), 1e-12, 'one hour at 1 percent a minute');
  near(c.ethRate(6 * H), R0 * Math.pow(1.01, 360), 1e-12, 'six hours');
  near(c.ethRate(12 * H), R0 * Math.pow(1.01, 720), 1e-12, 'twelve hours');
}
// promise: the ceiling: ceilPct of the anchor, the larger of the last fill rate and the remembered peak, loosened by idleLoosenPct for every full 10 idle minutes
{
  const c = fresh({ rateCap: 1e21, climbPerMin: 50, recoveryClimbPerMin: 50, ceilPct: 110, idleLoosenPct: 1 }); // 50 percent a minute reaches the ceiling within the first minute
  near(c.ethRate(5 * 60), R0 * 1.1, 1e-12, 'before the first full 10 idle minutes the ceiling is ceilPct of the opening rate');
  near(c.ethRate(H), R0 * 1.1 * 1.06, 1e-12, 'after 60 idle minutes (6 full intervals) the anchor is loosened by 6 percent');
}
// promise: decision 128: the climb multiplier m = clamp(ethPot / (rate * PAGE), 1, multiplierCap), evaluated at each checkpoint. one, three and ten pages
{
  const mult = (cap, pages) => {
    const c = fresh({ multiplierCap: cap });
    c.ethPot = (pages * c.rateAtCheckpoint * c.s.pointsPerPage / 100) / W; // eth that buys exactly `pages` pages of pointsPerPage points at the rate
    c.checkpoint(0);
    return c.checkpointMult;
  };
  near(mult(4, 1), 1, 1e-9, 'one page of pot gives a multiplier of 1');
  near(mult(4, 3), 3, 1e-9, 'three pages of pot gives a multiplier of 3');
  near(mult(4, 10), 4, 1e-9, 'ten pages of pot caps the multiplier at multiplierCap 4');
  near(mult(1, 10), 1, 1e-9, 'multiplierCap 1 holds the multiplier at 1, the rule in force today');
}
// promise: decision 128: the read is held at or below hourlyBound / 10000 of the highest fill rate of the past hour (the last fill when the hour has none)
{
  const open = { multiplierCap: 1, rateCap: 1e21, ceilPct: 1e6, climbPerMin: 50, recoveryClimbPerMin: 50 }; // the climb is free to run far above the fills
  const c = fresh(Object.assign({ hourlyBound: 15000 }, open), 1000);
  c.rateAtCheckpoint = 1e13; c.checkpointTime = 0; c.lastPaidRate = 1e13;
  ok(c.spend(1e-6, 0), 'a fill at rate 1e13'); // records the fill rate 1e13 in minute bucket 0
  const t = 30 * 60; // still inside the hour, so the fill of minute 0 is the reference
  const u = fresh(Object.assign({ hourlyBound: 0 }, open), 1000); // the same state with no bound
  u.rateAtCheckpoint = 1e13; u.checkpointTime = 0; u.lastPaidRate = 1e13; u.spend(1e-6, 0);
  ok(u.ethRate(t) > 2e13, 'with no bound the read climbs far above the fill');
  near(c.ethRate(t), 1.5e13, 1e-9, 'the bound holds the read at 150 percent of the fill rate');
}
// promise: a fill drops the bid by dropPerCreditPct, then the price state climbs from the dropped rate
{
  const c = fresh({ rateCap: 1e21, ceilPct: 1e6 });
  ok(c.spend(1e-9, 0));
  near(c.rateAtCheckpoint, R0 * 0.995, 1e-12, 'one credit drops the bid 0.5 percent');
  near(c.ethRate(H), R0 * 0.995 * Math.pow(1.01, 60), 1e-12, 'an hour after the fill the climb runs from the dropped rate at 1 percent a minute');
}
// promise: funded flag: the pot affords one credit at the rate, pot * 1e18 >= rate
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
// promise: funded clamp: the climb stops where the pot buys one credit, pot * 1e18, or at rateCap
{
  const c = fresh({}, 1e-4);
  near(c.clamp(), 1e-4 * W, 1e-12, 'clamp at pot 0.0001 eth is the pot');
  near(fresh({}, 1000).clamp(), 53344000000000000, 1e-12, 'clamp at pot 1000 eth is the rate cap, 8 times rateStart');
}
// drop on fill: a fill drops the bid dropPerCreditPct of the rate paid, whatever share of the pot it spends. within one minute the bid stays
// promise: at or above dropToPct of the bid at the first fill of that minute
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
  const f = fresh({ rateStart: 1e13, dropPerCreditPct: 60, dropToPct: 50 }, 1);
  ok(f.spend(0.1, 0)); near(f.rateAtCheckpoint, 1e13 * 0.5, 1e-12, 'a drop of 60 percent stops at dropToPct (50 percent) of the bid at the first fill');
  ok(f.spend(0.1, 59)); near(f.rateAtCheckpoint, 1e13 * 0.5, 1e-12, 'a second fill in the same minute stays at that floor');
}
// promise: every credit is paid the rate: no score, no window
{
  const c = fresh({}); c.rateAtCheckpoint = 1e13; c.checkpointTime = 0;
  const paid = c.sellForEth(0);
  near(paid, 1e13 / W, 1e-12, 'sellForEth pays the rate for any credit');
  near(c.ethPot, 1000 - 1e13 / W, 1e-12, 'the pot paid it');
  ok(c.spend(500, 0) && c.spend(499.9, 0), 'a spend of most of the pot passes, there is no hourly cap');
  assert.equal(c.spend(1, 0), false); n++; // more than the pot left
}
// promise: buyListing payment (docs/DECISIONS.md 71): counted gas (at most BUYLISTING_GAS) at min(basefee, keeperMaxBaseFee) plus keeperFee, at most the bid less the ask, booked as spend with the cost
{
  const c = fresh({}, 10);
  c.rateAtCheckpoint = 1e16; // ceiling 0.01 eth, base fee 1 gwei, keeperFee 0.0003 (launch)
  const gas = 470000e-9 + 0.0003;
  const res = c.buyListing(0.008, 0);
  ok(res);
  near(res.paid, gas, 1e-12, 'a large gap pays counted gas at the base fee plus the keeper fee');
  near(c.ethPot, 10 - 0.008 - gas, 1e-12, 'the pot paid the cost and the payment');
  const c2 = fresh({}, 10); c2.rateAtCheckpoint = 1e16;
  near(c2.buyListing(0.0099, 0).paid, 0.0001, 1e-9, 'a gap under the largest payment is the payment');
  assert.equal(c2.buyListing(0.0101, 0), null); n++;
  const c3 = fresh({}, 10); c3.rateAtCheckpoint = 1e16; c3.p.basefeeGwei = 50;
  near(c3.buyListing(0.002, 0).paid, 470000 * 5e-9 + 0.0003, 1e-12, 'a base fee above keeperMaxBaseFee pays at the cap');
}
// promise: compose at the launch settings pays nothing: the pot is unchanged and the statement cost is the plain sum of the credit costs
{
  const c = fresh({}, 10);
  const pot = c.ethPot;
  const st = c.compose(0.8, 0);
  near(st.cost, 0.8, 1e-15, 'the cost is the credit sum');
  near(c.compose(0, 0).cost, 0, 1e-15, 'a zero cost credit sum stays zero');
  assert.equal(c.ethPot, pot); assert.equal(st.reimb, undefined); n += 2;
}
// the asking price of a statement (ControllerV1._quote, then the Core's hard floor): start falls in a straight line to
// promise: saleFloorBps over decayHours hours, then rests. start = min(anchorBps * markupBps / 10000, startCapBps). the price is a share of what the engine PAID, the statement cost
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
  assert.throws(() => e.setSettings({ decayHours: 0 }, 0), /decayHours/); assert.throws(() => e.setSettings({ decayHours: 2 ** 32 }, 0), /decayHours/); n += 2;
  assert.throws(() => e.setSettings({ markupBps: 2 ** 32 }, 0), /markupBps/); assert.throws(() => e.setSettings({ startCapBps: 11999 }, 0), /startCapBps/); n += 2;
  assert.throws(() => e.setSettings({ saleFloorBps: 65536 }, 0), /saleFloorBps/); n += 1;
  near(e.c.markupBps, 12000, 1e-12, 'a rejected change leaves the controller alone');
  for (const [k, bad] of [['markupBps', 2 ** 32], ['startCapBps', 2 ** 32], ['decayHours', 0], ['decayHours', 2 ** 32], ['anchorHalfLife', 0], ['anchorHalfLife', 2 ** 32], ['anchorMinCost', -1], ['anchorMinCost', Number(1n << 128n) / W], ['anchorMoveBps', 10001]]) assert.equal(controllerViolation(Object.assign({}, CONTROLLER, { [k]: bad })), k), n++;
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
// promise: the start price follows it, open listings included
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
  near(c.askingPrice(c.compose(1, T + 52.5 * H), T + 52.5 * H), 18019 / 10000, 1e-12, 'a fresh listing starts at the decayed anchor start, 18019 bps');
  near(c.askingPrice(open, T + 1000 * H), 1, 1e-12, 'the open listing rests at the floor (cost)');
  // four sales at the start price in a row (integer math): the anchor is 12500, 15625, 19531, 24413 after them
  const d = fresh({}, 10); const seen = [];
  for (let i = 0; i < 4; i++) { const r = d.buy(d.compose(1, 0), 0); seen.push(r.saleBps, d.anchorAt(0)); }
  assert.deepEqual(seen, [15000, 12500, 18750, 15625, 23437, 19531, 29296, 24413]); n++;
  // two sales at the floor at hour 400 leave the anchor, its time and the fresh start price where they were
  d.compose(1, 0); d.compose(1, 0);
  const startBefore = d.startBps(400 * H), freshAsk = d.askingPrice({ cost: 1, t0: 400 * H }, 400 * H);
  const f1 = d.buy(d.compose(1, 0), 400 * H), f2 = d.buy(d.compose(1, 0), 400 * H);
  assert.equal(f1.saleBps, 10000); assert.equal(f2.saleBps, 10000); assert.equal(d.anchorStored, 24413); assert.equal(d.anchorTime, 0); n += 4;
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
  assert.throws(() => m.setSettings({ anchorHalfLife: 0 }, 0), /anchorHalfLife/); assert.throws(() => m.setSettings({ anchorHalfLife: 2 ** 32 }, 0), /anchorHalfLife/); n += 2;
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
  assert.throws(() => mc.setSettings({ anchorMinCost: -1 }, 6 * H), /anchorMinCost/); n++;
}
// promise: the one floor (decision 105): saleFloorBps is the share of the reference where the curve stops and the share of cost the Core takes at least
{
  const st = { cost: 1, t0: 0 };
  const a = fresh({ saleFloorBps: 7500 }, 10);
  near(a.askingPrice(st, 200 * H), 0.75, 1e-12, 'the curve stops at the floor setting');
  near(a.askingPrice(st, 300 * H), 0.75, 1e-12, 'and stays there');
  near(a.askingPrice(st, 6 * H), 1.125, 1e-12, 'above the floor the curve decides: halfway down the 12 hour line from 150 to 75');
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
  const rich = { cost: 1, t0: 0, rating: 80 * 100 * 3 }; const r = fresh({ saleFloorBps: 7500, rateStart: 1e16, rateCap: 1e16 }, 10);
  near(r.reference(rich, 0), 2.4, 1e-12, 'the rate term is 0.8 a point group, three of them');
  near(r.askingPrice(rich, 5000 * H), 2.4 * 0.75, 1e-12, 'the curve rests at the floor share of the reference');
  ok(r.askingPrice(rich, 5000 * H) > r.floorPrice(rich), 'above the cost based floor of the Core');
  // sellTo refuses a payment under the floor of the Core even if the controller would ask less
  const s = a.compose(1, 0);
  assert.equal(a.sellTo(s, 0.7499, 0), null); assert.notEqual(a.sellTo(s, 0.75, 0), null); n += 2;
}
// promise: compose holds the statement in the Core from composedAt, asked at age zero at the start price, and stores its rating
{
  const c = fresh({}, 10);
  const st = c.compose(0.8, 0);
  near(c.askingPrice(st, 0), st.cost * 1.5, 1e-12, 'asked at the start price, 150 percent of cost');
  near(fresh({ markupBps: 10000 }, 10).askingPrice({ cost: 1, t0: 0 }, 0), 1.0, 1e-12, 'markupBps 10000');
  near(fresh({ markupBps: 13000 }, 10).askingPrice({ cost: 1, t0: 0 }, 0), 1.3, 1e-12, 'markupBps 13000');
  assert.deepEqual(Object.keys(st).sort(), ['cost', 'pauseMark', 'rating', 't0']); n++; // the record carries cost, composedAt, rating and the pause mark
  assert.equal(c.compose(1, 0, 35200).rating, 35200); n++
  const a100 = c.askingPrice(st, 100);
  near(a100, 0.8 * 1.5 - 0.8 * 0.5 * 100 / (12 * 3600), 1e-12, 'the asking price a hundred seconds in');
}
// promise: sellTo pays the asking price and the statement is gone at once
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
// promise: the proceeds split: sellTo books saleToBuybackBps to the buyback and the rest to the pot at once
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
// promise: feeToRedeemBurnBps: the one split of swap fee eth booked in receive(), the share that fills the redeem burn reserve, the rest to the pot (decision 106)
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
  assert.throws(() => s.setSettings({ saleFloorBps: 65536 }, 0), /saleFloorBps/); n++;
}
// promise: conservation of eth through the Core: fees, sales, spend, redemptions and the buyback slice all come from and go to one ledger (pot, buyback pot, redeem burn reserve)
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
// promise: setSettings: validates, checkpoints both rates first, applies at once
{
  const c = fresh({}, 1000);
  c.setSettings({ climbPerMin: 2, recoveryClimbPerMin: 2 }, 600);
  near(c.rateAtCheckpoint, R0 * Math.pow(1.01, 10), 1e-12, 'the climb to the change is credited under the old numbers');
  assert.equal(c.checkpointTime, 600); n++;
  near(c.ethRate(660), R0 * Math.pow(1.01, 10) * 1.02, 1e-12, 'the climb goes on at the new speed after the change');
  assert.throws(() => c.setSettings({ saleToBuybackBps: 10001 }, 0), /saleToBuybackBps/); n++;
  assert.throws(() => c.setSettings({ dropPerCreditPct: 655.36 }, 0), /dropPerCreditPct/); n++;
  assert.throws(() => c.setSettings({ saleFloorBps: 65536 }, 0), /saleFloorBps/); n++;
  assert.throws(() => c.setSettings({ rate: 0 }, 0), /BadRate/); n++;
  near(c.s.dropPerCreditPct, 0.5, 1e-12, 'a rejected change leaves the settings alone');
  c.setSettings({ rate: 2e13, saleToBuybackBps: 100 }, 20 * H);
  near(c.ethRate(20 * H), 2e13, 1e-12, 'setRate resets the limit'); near(c.s.saleToBuybackBps, 100, 1e-12, 'sale split changed');
  // the clamp reads the live pot
  const d = fresh({ rateCap: 1e18 }, 0.1);
  near(d.clamp(), 0.1 * W, 1e-12, 'clamp is the pot');
  // promise: taste settings use their integer widths; shares and divisors retain semantic bounds.
  const bad = (patch, name) => { assert.equal(firstViolation(Object.assign({}, SETTINGS, patch)), name); n++; };
  for (const [k, value] of Object.entries({ dropPerCreditPct: 655.36, dropToPct: 100.01, recoveryGapPct: 100.01, peakHalfLifeHours: 0, bucketSeconds: 0, idleStepSeconds: 0, payeePpm: 1000001, pointsPerPage: 0, spendCapBps: 10001, balanceBidCapBps: 9999, climbMultiplierCapBps: 9999, saleFloorBps: 65536, buybackDelay: 65536, rateCap: 0, redeemSlippageBps: 10001, balanceBidMarginBps: 10001, redeemBurnBps: 10001, feeToRedeemBurnBps: 10001 })) bad({ [k]: value }, k);
  bad({ redeemOn: 1 }, 'redeemOn'); bad({ balanceBidOn: 'yes' }, 'balanceBidOn');
  bad({ saleToArtistBps: 5001, saleToOperatorBps: 5000 }, 'saleToOperatorBps');
  assert.equal(firstViolation(Object.assign({}, SETTINGS, { dropPerCreditPct: 0.01, climbPerMin: 0.01, idleLoosenPct: 0.01, saleFloorBps: 0, recoveryClimbPerMin: 0.01, buybackDelay: 1, payeePpm: 1e6, pointsPerPage: 1, spendCapBps: 1, sniperSeconds: 0 })), null); n++;
  assert.equal(SETTINGS.rateCap, 3 * DEFAULTS.rateStart); n++;
  const c2 = fresh({}, 10);
  assert.throws(() => c2.setSettings({ feeToRedeemBurnBps: 10001 }, 0), /feeToRedeemBurnBps/); n++;
  c2.setSettings({ redeemOn: true }, 5); assert.equal(c2.s.redeemOn, true); assert.equal(c2.s.balanceBidOn, false); n += 2;
  c2.setSettings({ balanceBidOn: 1 }, 6); assert.equal(c2.s.balanceBidOn, true); n++; // a numeric patch value from the page is read as a flag
}
// promise: rateCap: the climb clamps at it, setRate refuses above it, a lower cap pulls the rate down at the checkpoint
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
// promise: the redeem burn reserve (FLOW 86): feeToRedeemBurnBps of the fee eth fills it, the rest goes to the pot
{
  const d = new Core(Object.assign({}, DEFAULTS), 0); // launch values: 0 to the reserve, the phase-2 wiring sets it to 1,000
  const r = d.addFees(8, 0);
  near(d.ethRedeemBurn, 0, 1e-12, 'launch reserve share of the fees'); near(d.ethPot, 8, 1e-12, 'the whole engine share to the pot'); near(d.ethToBuyback, 0, 1e-12, 'nothing to the buyback pot'); near(d.feeToRedeemBurn, 0, 1e-12, 'booked');
  near(r.toRedeemBurn + r.toPot, 8, 1e-12, 'the fee split adds up');
  const e = new Core(Object.assign({}, DEFAULTS, { feeToRedeemBurnBps: 2500 }), 0);
  e.addFees(10, 0);
  near(e.ethRedeemBurn, 2.5, 1e-12, 'reserve share'); near(e.ethPot, 7.5, 1e-12, 'pot share');
  near(e.ethPot + e.ethToBuyback + e.ethRedeemBurn, 10, 1e-12, 'all of it is booked');
  // the reserve share does not enter the pot, so the funded flag and the clamp follow the pot alone
  const q = new Core(Object.assign({}, DEFAULTS, { rateCap: 1e18, reserveWei: 0, feeToRedeemBurnBps: 1000 }), 0); q.addFees(0.1, 0); near(q.clamp(), 0.09 * W, 1e-12, 'the clamp is the pot without the redeem burn share');
  // sale proceeds: the artist and operator cuts come off first, then saleToBuybackBps of the rest to the buyback (decision 123)
  const s = new Core(Object.assign({}, DEFAULTS), 0); s.sellTo({ cost: 1, t0: 0 }, 2, 0); // cuts 2 * (0.025 + 0.005) = 0.06, rest 1.94, buyback 1.94 * 0.25
  near(s.ethRedeemBurn, 0, 1e-12, 'a sale does not fill the reserve'); near(s.ethToBuyback, 1.94 * 0.25, 1e-12, 'a sale sends saleToBuybackBps of the rest to the buyback'); near(s.artistPaid + s.operatorPaid, 0.06, 1e-12, 'the cuts are pushed out');
}
// promise: redemption eligibility (Core.redeemStatement, ControllerV1.atFloor): a module is set, redeemOn is true, and the statement's curve price has reached its floor, saleFloorBps of its price reference
{
  const mk = (over = {}) => { const c = fresh(Object.assign({ redeemOn: true, balanceBidOn: true, saleFloorBps: 10000 }, over), 10); c.setBalanceModule(0, 1e-5); return c; }; // the launch floors (FLOW 85)
  const c = mk();
  const st = c.compose(1, 0, 35200);
  assert.equal(c.redeemReady(st, 12 * H - 1), false); assert.equal(c.redeemReady(st, 12 * H), true); assert.equal(c.redeemReady(st, 5000 * H), true); n += 3; // the curve reaches its floor, the reference, at hour 12 (decayHours). the rate term scales the reference, not the hour
  assert.equal(fresh({ redeemOn: true, balanceBidOn: true }, 10).redeemReady(c.compose(1, 0), 9999 * H), false); n++; // no module, no redemption
  for (const [over, want] of [[{ redeemOn: false, balanceBidOn: false }, false], [{ redeemOn: false, balanceBidOn: true }, false], [{ redeemOn: true, balanceBidOn: false }, true], [{ redeemOn: true, balanceBidOn: true }, true]]) {
    const m = mk(over);
    assert.equal(m.redeemReady(m.compose(1, 0), 60 * H), want); assert.equal(m.redeemReady(m.compose(1, 0), 0), false); n += 2; // eligible by redeemOn only once the curve is at its floor
  }
  // the one floor: with saleFloorBps 12000 the curve rests at 120 percent of the reference, reached at hour 12 (decayHours), and the statement is eligible from there (ControllerV1.atFloor)
  const hi = mk({ saleFloorBps: 12000 }); const hs = hi.compose(1, 0); assert.equal(hi.redeemReady(hs, 9999 * H), true); assert.equal(hi.redeemReady(hs, 12 * H), true); assert.equal(hi.redeemReady(hs, 12 * H - 1), false); near(hi.curvePrice(hs, 9999 * H), 1.2, 1e-12, 'the sale price is held at the floor'); n += 3;
  const lo = mk({ saleFloorBps: 5000 }); assert.equal(lo.redeemReady(lo.compose(1, 0), 12 * H), true); assert.equal(lo.redeemReady(lo.compose(1, 0), 12 * H - 1), false); n += 2; // the straight line to 50 percent of the reference is done at hour 12
  // a sold or redeemed statement is gone
  const sold = c.compose(1, 0, 1); c.sellTo(sold, 1.5, 0); assert.equal(c.redeemReady(sold, 60 * H), false);
  const done = c.compose(1, 0, 1); assert.notEqual(c.redeemStatement(done, 60 * H), null); assert.equal(c.redeemReady(done, 61 * H), false); assert.equal(c.redeemStatement(done, 61 * H), null); assert.equal(c.sellTo(done, 9, 61 * H), null); n += 5;
  // the launch curve falls to cost and stays there (FLOW 85): at cost from hour 12 (decayHours) on, never below it
  const L = mk({ saleFloorBps: 10000 }); const ls = L.compose(1, 0, 1);
  near(L.curvePrice(ls, 12 * H), 1, 1e-12, 'launch curve at cost at hour 12'); near(L.curvePrice(ls, 5000 * H), 1, 1e-12, 'and at cost long after'); near(L.curvePrice(ls, 11 * H), 1 + 0.5 / 12, 1e-12, 'one hour before, one slope step above cost');
  assert.equal(L.redeemReady(ls, 12 * H - 1), false); assert.equal(L.redeemReady(ls, 12 * H), true); n += 2;
  // the pause holds the age, so eligibility holds its value through a pause: not at the floor when paused at hour 6, at the floor 12 hours of age after the resume
  const pz = mk({ saleFloorBps: 10000 }); const ps = pz.compose(1, 0, 1);
  pz.setPaused(true, 6 * H); assert.equal(pz.redeemReady(ps, 90 * H), false); pz.setPaused(false, 100 * H); assert.equal(pz.redeemReady(ps, 105 * H), false); assert.equal(pz.redeemReady(ps, 106 * H), true); n += 3;
  // the value floor does not move eligibility, which reads the curve price
  const vf = mk({ balancePoolSet: true }); const vs = vf.compose(1, 0, 1e6);
  ok(vf.askingPrice(vs, 60 * H) > 1, 'the asking price is above cost'); assert.equal(vf.redeemReady(vs, 60 * H), true); n++;
}
// Core.redeemStatement: the module returns rating * xpPerPoint, at least rating * xpPerPoint * (1 - redeemSlippageBps / 10000) or it reverts. the Core keeps all of it in balancePot.
// promise: a redemption moves redeemBurnBps of the redeem burn reserve to the buyback pot
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
// the rising balance token bid (Core.sellForBalance, decision 122): a second price state in bps of par, floor 10000 - balanceBidMarginBps,
// cap 10000 (par, so a payout never exceeds the score value), clamp the module available as bps of par. it opens at the floor, climbs
// promise: with the shared settings, drops per credit on a fill, and pays score * unit * rate / 10000
{
  const unit = 1e-5;
  const mk = (over = {}) => { const c = fresh(Object.assign({ redeemOn: true, balanceBidOn: true, balancePoolSet: true }, over), 10); c.setBalanceModule(0, unit); c.balancePot = 1; return c; };
  const c = mk();
  // the open is the floor, 90 percent of par at the launch margin 1000
  near(c.balanceRate(0), 9000, 1e-9, 'the bid opens at the floor, 9000 bps of par');
  near(c.balanceBidOf(440, 0), 440 * unit * 0.9, 1e-12, 'score times the per point value at the floor'); near(c.balanceBidOf(80, 0), 80 * unit * 0.9, 1e-12, 'a low score is paid less');
  near(c.balanceBidOf(800, 0), 2 * c.balanceBidOf(400, 0), 1e-12, 'linear in the score at one rate');
  // it climbs toward par (the cap) and rests there, never above the score value
  ok(c.balanceRate(5 * 60) > 9000 && c.balanceRate(5 * 60) < 10000, 'climbing between the floor and par');
  near(c.balanceRate(60 * 60), 10000, 1e-9, 'it reaches par and the cap holds it there'); near(c.balanceBidOf(440, 60 * 60), 440 * unit, 1e-12, 'at par the payout is the full score value');
  // a fill at the open pays the floor and the drop is bounded at the floor
  const d = mk(); near(d.xBuy(440, 0), 440 * unit * 0.9, 1e-12, 'a fill pays the floor rate'); near(d.balancePot, 1 - 440 * unit * 0.9, 1e-12, 'from the module holding'); ok(d.balanceRate(0) >= 9000 - 1e-9, 'the drop is bounded at the floor');
  // a module too short to pay the floor refuses the whole fill (PotTooSmall) but balanceBidOf still reports the floor payout
  const small = mk(); small.balancePot = 433 * unit * 0.9 / 2; // half the floor par of the 433 point credit, so available cannot cover its floor payout
  assert.equal(small.xBuy(433, 0), 0); near(small.balancePot, 433 * unit * 0.9 / 2, 1e-15, 'nothing moves'); n++;
  near(small.balanceBidOf(433, 0), 433 * unit * 0.9, 1e-12, 'balanceBidOf reports the floor payout'); ok(small.balanceBidOf(433, 0) > 0, 'never 0 for a credit the module cannot pay the floor for');
  // the bid off, or no module: the rate reports the floor and a sell pays nothing
  for (const over of [{ balanceBidOn: false }, { redeemOn: true, balanceBidOn: false }]) { const m = mk(over); assert.equal(m.balanceBidActive(), false); near(m.balanceRate(60 * 60), 9000, 1e-9, 'the floor while off'); assert.equal(m.xBuy(440, 0), 0); near(m.balancePot, 1, 1e-15, 'no bid with balanceBidOn false'); n += 3; }
  assert.equal(fresh({ redeemOn: true, balanceBidOn: true, balancePoolSet: true }, 10).balanceBidActive(), false); n++; // no module, no bid
  { const np = fresh({ redeemOn: true, balanceBidOn: true }, 10); np.setBalanceModule(0, unit); np.balancePot = 1; assert.equal(np.balanceBidActive(), true); near(np.xBuy(440, 0), 440 * unit * 0.9, 1e-12, 'the bid works without the pool key'); n += 2; }
  // the margin sets the floor and opens a fresh instance there; a margin raise does not pull a climbed rate down
  const g0 = mk({ balanceBidMarginBps: 0 }); near(g0.balanceRate(0), 10000, 1e-9, 'margin 0 opens at par'); near(g0.balanceBidOf(100, 0), 100 * unit, 1e-12, 'the whole value');
  const g9 = mk({ balanceBidMarginBps: 9000 }); near(g9.balanceRate(0), 1000, 1e-9, 'margin 90 percent opens at 1000 bps of par'); near(g9.balanceBidOf(100, 0), 100 * unit * 0.1, 1e-12, 'the floor payout at margin 90 percent');
  // buy near the floor and redeem at full value: the engine keeps at most the margin
  const h = mk(); const px = h.xBuy(35200 / 80, 0); const rec = h.redeemStatement(h.compose(0, 0, 440 * 80), 5000 * H); // redeemed once the curve has reached its floor
  near(rec.received, 440 * 80 * unit, 1e-12, 'the redemption returns the full value'); ok(rec.received > 80 * px, 'more than the 80 credits were bought for');
}
// a credit bought with the balance token enters the one pile at an eth cost (FLOW 96): the floor rate times score / refScore
// (CoreLib.sellForBalance), at least 1 wei. the floor rate is the larger of the price state and the remembered peak. it reads the price state and the peak,
// promise: so the pool price never moves it and the bid needs no pool key
{
  const mk = (over = {}, pot = 10) => { const c = fresh(Object.assign({ redeemOn: true, balanceBidOn: true, balancePoolSet: true, rateStart: 1e15, rateCap: 1e16, climbPerMin: 0.5, recoveryClimbPerMin: 2, idleLoosenPct: 2, saleFloorBps: 10000 }, over), pot); c.setBalanceModule(0, 1e-5); c.balancePot = 1; return c; };
  // the peak is 0.001 eth per credit; 440 points is above refScore (4330000/1e4 = 433), so the backstop scales to 0.001 * 440 / 100
  const c = mk(); const r = c.xBuyCredit(440, 0); near(r.paid, 440 * 1e-5 * 0.9, 1e-12, 'the tokens paid at the floor'); near(r.cost, 0.001 * 440 / 100, 1e-12, 'the cost is the scaled peak backstop'); n += 2;
  const lo = mk({ balancePoolMult: 0.1 }), rl = lo.xBuyCredit(440, 0); near(rl.cost, 0.001 * 440 / 100, 1e-12, 'a pushed down pool price does not move the cost'); n++;
  const hi = mk({ balancePoolMult: 3 }), rh = hi.xBuyCredit(440, 0); near(rh.cost, 0.001 * 440 / 100, 1e-12, 'a pushed up pool price does not move the cost'); n++;
  const empty = mk({ rateStart: 4e15 }, 0); empty.balancePot = 1; const re = empty.xBuyCredit(1, 0); near(re.cost, 4e-3 / 100, 1e-12, 'an empty pot leaves the floor at the opening rate, scaled to one point'); n++;
  const under = mk(), ru = under.xBuyCredit(100, 0); near(ru.cost, 0.001 * 100 / 100, 1e-12, 'a score under refScore scales the cost down'); n++;
  const np = mk({ balancePoolSet: false }); const rn = np.xBuyCredit(440, 0); near(rn.cost, 0.001 * 440 / 100, 1e-12, 'the bid works with no pool key and records the backstop'); n++;
  const off = mk({ balanceBidOn: false }); assert.equal(off.xBuyCredit(440, 0), null); n++;
}
// promise: Core.sellForBalance and Core.redeemStatement read unitPerPoint from the module in the call (decision 104), Core.releaseRedeemBurn (owner) moves reserve eth to the buyback pot
{
  const mk = (over = {}) => { const c = fresh(Object.assign({ redeemOn: true, balanceBidOn: true, feeToRedeemBurnBps: 1000, saleFloorBps: 10000, balancePoolSet: true }, over), 0); c.setBalanceModule(0, 1e-5); c.addFees(100, 0); c.balancePot = 1; return c; };
  const c = mk();
  near(c.xpLive, 1e-5, 1e-15, 'a module set reports its unit'); assert.equal(c.xpPerPoint, undefined); assert.equal(c.refreshUnitPerPoint, undefined); n += 2;
  // the module lowers its rate: the bid follows it
  c.moduleReports(6e-6);
  near(c.balanceBidOf(440, 0), 440 * 6e-6 * 0.9, 1e-12, 'the bid pays the live unit when it is lower');
  // the module raises its rate: the bid follows it as well
  c.moduleReports(2e-5);
  near(c.balanceBidOf(440, 0), 440 * 2e-5 * 0.9, 1e-12, 'the bid pays the live unit when it is higher');
  near(c.xBuy(440, 0), 440 * 2e-5 * 0.9, 1e-12, 'a buy pays the live unit');
  // redemption: the module pays rating * live and the Core requires the slippage floor on the same live unit, so a moving unit never underpays by itself
  const up = c.redeemStatement(c.compose(1, 0, 35200), 60 * H);
  near(up.received, 35200 * 2e-5, 1e-12, 'the module pays at its live unit'); n++;
  const lo = mk(); lo.moduleReports(9.7e-6); ok(lo.redeemStatement(lo.compose(1, 0, 35200), 60 * H), 'a lower live unit redeems: the minimum follows it');
  const short = mk({ redeemPayFrac: 0.97 }); short.moduleReports(9.7e-6); assert.equal(short.redeemStatement(short.compose(1, 0, 35200), 60 * H), null); n++; // 3 percent under the live unit: Underpaid
  near(lo.balanceBidOf(100, 0), 100 * 9.7e-6 * 0.9, 1e-12, 'the bid follows the unit');
  const none = fresh({ redeemOn: true, balanceBidOn: true }, 10); assert.equal(none.balanceBidActive(), false); n++; // no module
  const zero = mk(); zero.moduleReports(0); assert.equal(zero.redeemStatement(zero.compose(1, 0, 35200), 60 * H), null); n++; // BadModule
  near(zero.balanceBidOf(100, 0), 0, 1e-15, 'a zero live unit pays nothing'); assert.equal(zero.xBuy(100, 0), 0); assert.equal(zero.balanceBidActive(), false); n += 2;
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
// promise: reference stays under cost
{
  const U = 2 / 60000, RS = { rateStart: 1e15, rateCap: 1e15, saleFloorBps: 10000 };
  const st = { cost: 1, t0: 0, rating: 60000 }; // pool term 2 eth
  const unset = fresh(Object.assign({ redeemOn: true, balanceBidOn: true }, RS), 10); unset.setBalanceModule(0, U);
  near(unset.askingPrice(st, 0), 1.5, 1e-12, 'pool key unset: the curve on the cost'); near(unset.poolTerm(60000), 0, 1e-15, 'and no pool term');
  const set = fresh(Object.assign({ redeemOn: true, balanceBidOn: true, balancePoolSet: true }, RS), 10);
  near(set.askingPrice(st, 0), 1.5, 1e-12, 'no balance module: the curve on the cost'); set.setBalanceModule(0, U);
  near(set.poolTerm(60000), 2, 1e-12, 'the pool term'); near(set.reference(st, 0), 2, 1e-12, 'the pool term lifts the reference above the cost');
  near(set.askingPrice(st, 0), 3, 1e-12, 'the curve starts at 150 percent of the lifted reference'); near(set.askingPrice(st, 6 * H), 2.5, 1e-12, 'and falls on it'); near(set.askingPrice(st, 100 * H), 2, 1e-12, 'to the floor, 100 percent of the reference');
  near(set.askingPrice({ cost: 1, t0: 0, rating: 1000 }, 0), 1.5, 1e-12, 'a low pool term leaves the reference at the cost');
  near(set.lowestPrice(st, 0), 2, 1e-12, 'the lowest price is the floor of the reference');
  assert.equal(set.atFloor(st, 12 * H - 1), false); assert.equal(set.atFloor(st, 12 * H), true); n += 2; // eligibility reads the age, whatever lifts the reference
  const r = set.buy(set.compose(1, 0, 60000), 0);
  near(r.price, 3, 1e-12, 'the engine price'); assert.equal(r.saleBps, 15000); assert.equal(set.anchorAt(0), 12500); n += 2; // the anchor moves on the curve in bps of the reference
  near(set.ethPot + set.ethToBuyback, 10 + 3, 1e-12, 'the Core books the engine price (no royalty, the launch cuts are 0 here)');
  // the unit is the one the module reports now, at the pool price (balancePoolMult)
  set.moduleReports(U / 2); near(set.poolTerm(60000), 1, 1e-12, 'a lower unit lowers the term'); set.moduleReports(U * 3); near(set.poolTerm(60000), 6, 1e-12, 'a higher unit raises it'); set.moduleReports(0); near(set.poolTerm(60000), 0, 1e-15, 'a zero unit leaves no term');
  const dn = fresh(Object.assign({ redeemOn: true, balanceBidOn: true, balancePoolSet: true, balancePoolMult: 0.5 }, RS), 10); dn.setBalanceModule(0, U); near(dn.poolTerm(60000), 1, 1e-12, 'a pool price at half the unit halves the term');
  // a small term cannot lower the price: the bound is the cost
  const lowv = fresh({ balancePoolSet: true, saleFloorBps: 7500 }, 10); lowv.setBalanceModule(0, 1e-9);
  near(lowv.askingPrice({ cost: 1, t0: 0, rating: 10 }, 5000 * H), 0.75, 1e-12, 'the floor holds under a small term');
  const launch = fresh({ balancePoolSet: true, saleFloorBps: 10000 }, 10); launch.setBalanceModule(0, 1e-9);
  near(launch.askingPrice({ cost: 1, t0: 0, rating: 10 }, 5000 * H), 1, 1e-12, 'at the launch floor the price never goes under cost');
  n += 4;
}
// the price reference (ControllerV1.referenceOf, FLOW 95): reference = max(cost, ethPrice * rating / refScore), the eth bid rate before the pot clamp times the rating over
// refScore, computed at each call. the curve, its floor, the knee, the start price and the anchor are fractions of it. the Core hard floor stays on cost. refScore is the
// per-credit score in ten-thousandths of a point (4,330,000 = 433 points). the rate cap holds the eth bid at 1e16 so ethPrice / W is 0.01 per credit and the rate term of 80
// promise: credits at 433 points is 0.8
{
  const L = { saleFloorBps: 10000, rateStart: 1e16, rateCap: 1e16 }, c = fresh(L, 10);
  near(c.ethPrice(0) / W, 0.01, 1e-15, 'the pinned per-credit eth rate'); n++;
  near(c.reference({ cost: 5, rating: 80 * 100 }, 0), 5, 1e-12, 'a cost over the rate term references cost'); // rate term 0.8 < 5
  near(c.reference({ cost: 0.5, rating: 80 * 100 }, 0), 0.8, 1e-12, 'the rate term over cost references the rate term'); // 0.01 * 80 = 0.8
  near(c.reference({ cost: 1, rating: 80 * 100 * 2 }, 0), 1.6, 1e-12, 'twice the rating references twice the rate term');
  near(c.reference({ cost: 2 }, 0), 2, 1e-12, 'a record without a rating references its cost'); n += 4;
  // the fix to decision 90: two statements of equal rating reference the same amount whatever each cost, once the rate term binds
  near(c.reference({ cost: 0.1, rating: 80 * 100 }, 0), c.reference({ cost: 0.4, rating: 80 * 100 }, 0), 1e-12, 'equal rating references the same whatever the cost');
  near(c.reference({ cost: 0.1, rating: 80 * 100 }, 0), 0.8, 1e-12, 'the shared rate term'); n += 2;
  const rich = { cost: 0.1, t0: 0, rating: 80 * 100 }; // reference 0.8, rate bound
  near(c.curvePrice(rich, 0), 0.8 * 1.5, 1e-12, 'the start price is 150 percent of the reference'); near(c.curvePrice(rich, 50 * H), 0.8, 1e-12, 'the floor is 100 percent of the reference at hour 50');
  near(c.curvePrice(rich, 5000 * H), 0.8, 1e-12, 'and stays there'); near(c.lowestPrice(rich, 0), 0.8, 1e-12, 'the lowest price is the reference'); n += 4;
  assert.equal(c.atFloor(rich, 12 * H - 1), false); assert.equal(c.atFloor(rich, 12 * H), true); n += 2;
  // the Core hard floor is on cost: a rate term over cost raises the price, never the hard floor
  near(c.floorPrice(rich), 0.1, 1e-12, 'the hard floor is saleFloorBps of cost'); n++;
  // the reference moves with the eth bid at the call: doubling the stored rate doubles the reference
  const m = fresh({ saleFloorBps: 10000, rateStart: 1e16, rateCap: 2e16 }, 10);
  near(m.reference(rich, 0), 0.8, 1e-12, 'the reference at the opening rate'); m.setSettings({ rate: 2e16 }, 1);
  near(m.ethPrice(1) / W, 0.02, 1e-12, 'the owner doubled the eth bid'); near(m.reference(rich, 1), 1.6, 1e-12, 'the reference doubled with it'); n += 3;
  // a buy at the start price moves the anchor by the same bps at any rating (the sale price in bps of the reference)
  const r1 = c.buy({ cost: 0.1, t0: 0, rating: 80 * 100 }, 0), d = fresh(L, 10), r2 = d.buy({ cost: 0.1, t0: 0, rating: 80 * 100 * 2 }, 0);
  assert.equal(r1.saleBps, 15000); assert.equal(r2.saleBps, 15000); assert.equal(c.anchorAt(0), d.anchorAt(0)); near(r2.price, 2 * r1.price, 1e-12, 'twice the rating is paid twice as much'); n += 4;
  // refScore is a controller setting read at once: a higher refScore shrinks the rate term, and cost binds once it falls under cost
  const e = fresh(L, 10); near(e.reference({ cost: 0.6, rating: 80 * 100 }, 0), 0.8, 1e-12, 'the rate term binds at the opening rate'); e.setSettings({ rate: 5e15 }, 0); near(e.reference({ cost: 0.6, rating: 80 * 100 }, 0), 0.6, 1e-12, 'a lower rate shrinks the rate term under cost, which is the reference'); n += 2;
  assert.throws(() => e.setSettings({ pointsPerPage: 0 }, 2), /pointsPerPage/); assert.throws(() => e.setSettings({ pointsPerPage: 2 ** 32 }, 2), /pointsPerPage/); n += 2;
}
// the credit sale window (ControllerV1.creditPrice, FLOW 88, 92, 93, 94): off at launch. floor = max(cost, valueOf(score)) * floorMultBps / 10000 (decisions 115, 150, 153), start = floor *
// creditStartBps / 10000, a straight line over creditWindow from the acquisition time, resting at the floor. Core.sellCreditTo takes at least the cost, creditCostToPotBps of the cost
// promise: to the pot and the rest of the payment to the buyback pot. compose waits for the window while the sale is on
{
  // the rate is flat here (the contract minimum climb), so the floor is the cost; the long run check below climbs
  // creditSpreadBps 1000 at the 10000 cap is the 1.1 floor these checks were written for; the launch spread has its own checks below
  const mk = (over = {}, pot = 10) => fresh(Object.assign({ creditSaleOn: true, rateStart: 4e14, rateCap: 1e16, climbPerMin: 0.01, recoveryClimbPerMin: 0.01, idleLoosenPct: 2, creditSpreadBps: 1000 }, over), pot);
  const cr = { pts: 440, cost: 0.002, t0: 0 }, W4 = 4 * H;
  const c = mk();
  ok(DEFAULTS.creditSaleOn === true && fresh({}, 10).cr.creditSaleOn === true, 'the credit sale is on at launch (decision 119)'); n++;
  near(c.ethPrice(0) / W, 4e-4, 1e-9, 'the eth bid before the clamp'); // the 440 point rate term is under the cost here: the cost term wins
  near(c.creditFloor(cr, 0), 0.002 * 1.1, 1e-12, 'floor = cost * 11000 / 10000'); near(c.creditPrice(cr, 0), 0.002 * 1.1 * 3, 1e-12, 'start = floor * 30000 / 10000');
  near(c.creditPrice(cr, W4 / 2), 0.002 * 1.1 * 2, 1e-12, 'half way down at half the window'); near(c.creditPrice(cr, W4), 0.002 * 1.1, 1e-12, 'the floor at the end of the window'); near(c.creditPrice(cr, W4 + 60), 0.002 * 1.1, 1e-12, 'and just after it'); const cl = mk({ climbPerMin: 0.5, recoveryClimbPerMin: 2 }); near(cl.creditPrice(cr, 1000 * H), 0.01 * (440 / 100) * 1.1, 1e-9, 'long after the window the floor follows the climbed floor rate capped at rateCap, scaled by the score');
  n += 6;
  // the rate term: a cost under it is floored at it, read before the pot clamp (an empty pot does not zero it). 440 points scales it by 440 / 100, a score under 100 points scales it down
  const e = mk({ rateStart: 4e15, rateCap: 1e16 }, 0.0001);
  near(e.ethRate(0), 0.0001 * W, 1e-12, 'the clamped read is the pot'); near(e.ethPrice(0) / W, 4e-3, 1e-12, 'the price state is unclamped'); near(e.creditFloor(cr, 0), 4e-3 * (440 / 100) * 1.1, 1e-12, 'the floor follows the unclamped rate term');
  const low = { pts: 200, cost: 0.0001, t0: 0 }; near(e.valueOf(200, 0), 4e-3 * (200 / 100), 1e-12, 'a score under 100 points scales the rate term down'); near(e.creditFloor(low, 0), 4e-3 * (200 / 100) * 1.1, 1e-12, 'the credit sale floor scales the rate term by its score'); n += 5;
  // the pool term: score * unit at the pool price, 0 until the pool key and the module are set, and the unit is the one the module reports now
  const b = mk({ redeemOn: true, balanceBidOn: true, balancePoolSet: true }); near(b.poolTerm(440), 0, 1e-15, 'no module: pool term 0'); b.setBalanceModule(0, 1e-5);
  near(b.poolTerm(440), 440 * 1e-5, 1e-12, 'pool term = score * unit'); near(b.creditFloor(cr, 0), 440 * 1e-5 * 1.1, 1e-12, 'a pool term over the cost sets the floor');
  b.moduleReports(5e-6); near(b.poolTerm(440), 440 * 5e-6, 1e-12, 'the unit the module reports now'); near(b.creditFloor({ pts: 440, cost: 0.003, t0: 0 }, 0), 0.003 * 1.1, 1e-12, 'a pool term under the cost leaves the cost'); n += 5;
  assert.equal(mk({ balancePoolSet: false }).poolTerm(440), 0); n++;
  // valueOf is the larger of the rate term and the pool term; the credit price has no royalty on top (decision 123)
  near(b.valueOf(440, 0), Math.max(b.poolTerm(440), (b.floorRate(0) / W) * (440 / 100)), 1e-12, 'valueOf is the larger term'); near(b.valueOf(0, 0), 0, 1e-15, 'no points, no value');
  ok(c.grossCreditPrice === undefined, 'the gross credit price is gone with the royalty'); n += 3;
  // sellCreditTo and buyCredit (cuts 0 here): creditCostToPotBps of the cost to the pot, the rest to the buyback pot, never under the cost
  const s = mk(), pot0 = s.ethPot, sold = { pts: 440, cost: 0.004, t0: 0 }, price = s.creditPrice(sold, W4);
  const res = s.buyCredit(sold, W4); ok(res !== null && sold.sold === true, 'sold at once'); near(res.price, price, 1e-12, 'the price paid'); near(res.toPot, 0.004 * 0.8, 1e-12, 'creditCostToPotBps 8000: 80 percent of the cost to the pot'); near(res.toBuyback, price - 0.004 * 0.8, 1e-12, 'the rest to the buyback pot');
  near(s.ethPot - pot0, 0.004 * 0.8, 1e-12, 'the pot has the cost share'); near(s.ethToBuyback, price - 0.004 * 0.8, 1e-12, 'the buyback pot has the rest'); n += 6;
  assert.equal(s.sellCreditTo({ pts: 1, cost: 0.004, t0: 0 }, 0.00399, 0), null); ok(s.sellCreditTo({ pts: 1, cost: 0.004, t0: 0 }, 0.004, 0) !== null, 'saleFloorBps 10000 of the cost is the hard floor'); assert.equal(s.buyCredit(sold, W4), null); n += 3; // a credit sells once
  const half = mk({ creditCostToPotBps: 5000 }); const hs = { pts: 1, cost: 0.004, t0: 0 }, hp = half.ethPot; const hr = half.buyCredit(hs, W4);
  near(hr.toPot, 0.002, 1e-12, 'creditCostToPotBps 5000: half the cost to the pot'); near(half.ethPot - hp, 0.002, 1e-12, 'booked'); near(half.ethToBuyback, hr.price - 0.002, 1e-12, 'the rest to the buyback pot'); n += 3;
  // off: no sale. paused: no sale. the window gates compose only while the sale is on
  assert.equal(fresh({ creditSaleOn: false }, 10).buyCredit({ pts: 1, cost: 0.004, t0: 0 }, 0), null); const pz = mk(); pz.setPaused(true, 0); assert.equal(pz.buyCredit({ pts: 1, cost: 0.004, t0: 0 }, 5), null); n += 2;
  assert.equal(c.pastWindow(0, W4 - 1), false); assert.equal(c.pastWindow(0, W4), true); assert.equal(fresh({ creditSaleOn: false }, 10).pastWindow(0, 0), true); n += 3;
  // bounds of the credit settings (src/lib/CreditBounds.sol) and the setters, at once
  assert.throws(() => c.setSettings({ creditWindow: 2 ** 32 }, 1), /creditWindow/); assert.throws(() => c.setSettings({ creditSpreadBps: 65536 }, 1), /creditSpreadBps/); assert.throws(() => c.setSettings({ creditStartBps: 2 ** 32 }, 1), /creditStartBps/);
  assert.throws(() => c.setSettings({ creditCostToPotBps: 10001 }, 1), /creditCostToPotBps/); n += 4;
  c.setSettings({ creditSaleOn: false, creditWindow: 7200, creditSpreadBps: 2000, creditStartBps: 20000, chosenComposeOn: true, minCcToChoose: 5 }, 1);
  assert.equal(c.cr.creditSaleOn, false); assert.equal(c.cr.creditWindow, 7200); assert.equal(c.cr.chosenComposeOn, true); n += 3;
}

// promise: packet B (decision 154): the credit floor multiplier is (10000 + creditSpreadBps) of the live cap, sellCreditTo floors on
// saleFloorBps, the reserve keeps the queue's payments out of the bids, the return lock refuses a sold credit, eligibility is by age
{
  const c = fresh({ creditSaleOn: true }, 10);
  near(c.floorMultBps(), 11000, 1e-12, 'launch spread 1000 at the cap 10000'); c.setSettings({ balanceBidCapBps: 11000 }, 1); near(c.floorMultBps(), 12100, 1e-12, 'at the hard cap 11000 of decision 152');
  c.setSettings({ creditSpreadBps: 0, balanceBidCapBps: 10000 }, 2); near(c.floorMultBps(), 10000, 1e-12, 'no spread at the 10000 cap is the reference'); n += 3;
  // sellCreditTo floors on saleFloorBps of the cost
  const f = fresh({ creditSaleOn: true, saleFloorBps: 5000 }, 10);
  assert.equal(f.sellCreditTo({ pts: 1, cost: 0.004, t0: 0 }, 0.00199, 0), null); ok(f.sellCreditTo({ pts: 1, cost: 0.004, t0: 0 }, 0.002, 0) !== null, 'half the cost at saleFloorBps 5000'); n++;
  const hiFloor = fresh({ creditSaleOn: true, saleFloorBps: 12000, rateStart: 1e12 }, 10); near(hiFloor.creditFloor({ pts: 1, cost: 0.004, t0: 0 }, 0), 0.004 * 1.2, 1e-12, 'the credit floor is never under the Core floor'); n++;
  // the reserve: the floor with no queue, 1.5 times the queued payments above it; the bids read the pot less the reserve, the caller payments the whole pot
  const r = fresh({ reserveWei: 0.1, rateCap: 1e18 }, 1);
  near(r.reserve(), 0.1, 1e-12, 'an empty queue keeps reserveWei'); r.setQueue(80 * 3, 2);
  near(r.reserve(), 1.5 * (3 * (9e6 * r.s.callerMaxBaseFee * 1e-9 + r.s.callerFee) + 2 * (6e5 * r.s.callerMaxBaseFee * 1e-9 + r.s.callerFee)), 1e-12, 'three pages and two statements');
  near(r.clamp(), (1 - r.reserve()) * W, 1e-9, 'the clamp is the pot less the reserve');
  r.setQueue(0, 0); r.ethPot = 0.1; assert.equal(r.ethRate(0), 0); assert.equal(r.sellForEth(0, 433), 0); n += 4; // a pot at the reserve bids nothing
  // the return lock: refused before soldAt + returnLockSeconds; a lock of 0 is no lock
  const l = fresh({ creditSaleOn: true }, 10), sold = { pts: 1, cost: 0.004, t0: 0 }; l.sellCreditTo(sold, 0.005, 100);
  ok(l.returnLocked(sold, 100 + 21599) && !l.returnLocked(sold, 100 + 21600), 'the launch lock of six hours'); ok(!l.returnLocked({ pts: 1, cost: 1, t0: 0 }, 5), 'a credit never sold passes');
  l.setSettings({ returnLockSeconds: 0 }, 101); ok(!l.returnLocked(sold, 100) && !l.returnLocked(sold, 101), 'a lock of 0 is no lock'); n += 3;
  // eligibility: the launch curve rule (ageEligibilityOn false) and the age only rule (true), both at the age boundary;
  // at launch saleFloorBps is 10000 so the two agree. decision 155: the owner turns on the age only rule at the switch
  const a = fresh({}, 10), st = { cost: 1, t0: 0 }, span = a.c.decayHours * H;
  ok(!a.atFloor(st, span - 1) && a.atFloor(st, span), 'curve rule: eligible at decayHours of age'); a.setSettings({ markupBps: 10000 }, 0); ok(a.atFloor(st, 0), 'curve rule: a start at par is eligible at once'); n += 2;
  const ae = fresh({}, 10); ae.setSettings({ ageEligibilityOn: true }, 0); const ast = { cost: 1, t0: 0 }, aspan = ae.c.decayHours * H;
  ok(!ae.atFloor(ast, aspan - 1) && ae.atFloor(ast, aspan), 'age only: eligible at decayHours of age'); ae.setSettings({ markupBps: 10000 }, 0); ok(ae.atFloor(ast, 0), 'age only: a start at par is eligible at once'); n += 2;
}

// promise: packet C (decision 148): the protected price moves its reference at the bounded rate and quotes the worse side of
// spot and reference within the tolerance; value mode prices the eth bid off the shared instance times the buy value, a fill
// drops the shared instance, valueOf is the sale value with the floor rate and cost terms dropped, an unusable quote bids and
// sells nothing, and only the switch and the bid turning on reset the shared instance
{
  assert.equal(SETTINGS.valueModeOn, false); assert.equal(QUOTE.tolBps, 0); assert.equal(QUOTE.referenceMaxStale, 0); n += 3; // the launch config: off, owner inputs pending
  assert.equal(quoteViolation({ ...QUOTE, referenceStepBps: 10001 }), 'referenceStepBps'); assert.equal(quoteViolation({ ...QUOTE, tolBps: 10000 }), 'tolBps'); assert.equal(quoteViolation(QUOTE), null); n += 3;
  const BPS = 10000, U = 0.001 / 100; // eth per point at the unit price
  const Q = { referenceRateBpsPerHour: 100, referenceStepBps: 200, tolBps: 500, referenceMaxStale: 3600, referenceMinSeconds: 0, balancePoolSet: true, balanceBidCapBps: 11000, balanceBidMarginBps: 1000 };
  const mk = (over = {}) => { const c = fresh({ ...Q, ...over }, 10); c.setBalanceModule(0, U); c.balancePot = 10; return c; };
  // the reference: set to the spot with the pool key, then at most min(rate * elapsed, referenceStep) toward the spot per update
  const r = mk();
  near(r.refMult, 1, 1e-12, 'the reference starts at the spot'); r.movePool(2);
  r.refreshReference(1800); near(r.refMult, 1.005, 1e-12, 'half an hour at 100 bps an hour'); r.refreshReference(1800); near(r.refMult, 1.005, 1e-12, 'a repeat in the same second gains nothing');
  r.refreshReference(1800 + 10 * H); near(r.refMult, 1.005 * 1.02, 1e-12, 'one update moves at most referenceStepBps'); n += 3;
  // the protected value: the buy side the lower of spot and reference plus tol, the sale side the higher of spot and reference less tol
  near(r.valuePerPoint(false, 1800 + 10 * H).value, U * 1.0251 * 1.05, 1e-9, 'a spot pushed up buys at the reference plus tol');
  near(r.valuePerPoint(true, 1800 + 10 * H).value, U * 2, 1e-12, 'and sells at the spot');
  r.movePool(0.5); near(r.valuePerPoint(true, 1800 + 10 * H).value, U * 1.0251 * 0.95, 1e-9, 'a spot pushed down sells at the reference less tol');
  near(r.valuePerPoint(false, 1800 + 10 * H).value, U * 0.5, 1e-12, 'and buys at the spot');
  ok(!r.valuePerPoint(false, 1800 + 10 * H + 3601).ok, 'a reference older than referenceMaxStale is unusable');
  ok(!mk({ referenceMaxStale: 0 }).valuePerPoint(false, 0).ok, 'referenceMaxStale 0 is never usable'); ok(!mk({ minLiquidity: 1, poolLiquidity: 0 }).valuePerPoint(false, 0).ok, 'a thin pool is unusable');
  // the switch: valueModeOn opens the shared instance at the floor; the eth bid is the instance times 100 points of the buy value
  const v = mk({ rateCap: 1e18 });
  v.balRate = 10800; v.setSettings({ valueModeOn: true, balanceBidOn: true }, 60);
  near(v.balRate, 9000, 1e-12, 'the switch resets the shared instance to the floor');
  near(v.ethRate(60), 0.9 * U * 100 * W, 1e-9, 'the eth bid at the floor is 9000 bps of 100 points of value');
  near(v.ethRate(60 + 30 * 60), Math.min(9000 * Math.pow(1.01, 30), v._balCeil(60 + 30 * 60)) / BPS * U * 100 * W, 1e-6, 'the shared instance climbs in value mode');
  near(v.balAvailBps(), 11000, 1e-12, 'clamped to the cap, not to the funds'); n++;
  // a fill drops the shared instance and leaves the eth instance
  const ethState = v.priceRate(120), before = v.balPriceState(120), paid = v.sellForEth(120, 100);
  ok(paid > 0, 'value mode pays'); near(v.balRate, before * (1 - v.s.dropPerCreditPct / 100), 1e-9, 'the fill drops the shared instance');
  near(v.priceRate(120), ethState, 1e-12, 'the eth instance is left'); n++;
  // valueOf in value mode: the sale value, no floor rate term; the reference and the credit floor drop the cost
  near(v.valueOf(440, 120), 440 * U, 1e-12, 'valueOf is points at the sale value');
  near(v.reference({ cost: 5, rating: 440 }, 120), 440 * U * v.floorMultBps() / BPS, 1e-12, 'the reference drops the cost term');
  near(v.creditFloor({ pts: 440, cost: 0.001, t0: 0 }, 120), 440 * U * v.floorMultBps() / BPS, 1e-12, 'the credit floor drops the cost term above the Core floor');
  near(v.lowestPrice({ cost: 0, rating: 440, t0: 0 }, 120), 440 * U * v.floorMultBps() / BPS, 1e-12, 'the curve rests at the reference');
  // an unusable quote: no eth bid, no sale, the balance route still fills at a 1 wei basis
  const stale = 120 + 2 * H; ok(!v.valuePerPoint(false, stale).ok, 'stale');
  assert.equal(v.ethRate(stale), 0); assert.equal(v.sellForEth(stale, 100), 0); n += 2;
  const xb = v.xBuyCredit(100, stale); ok(xb && xb.cost === 1e-18, 'the balance route fills at a 1 wei basis while the quote fails');
  ok(v.buy(v.compose(0.001, 0, 440), stale) !== null && v.refTime === stale, 'a sale door observes first, so a stale reference is fresh again');
  v.moduleReports(0); assert.equal(v.buy(v.compose(0.001, 0, 440), stale), null); n++; // NoQuote: no unit read
  // a currency switch or a settings change leaves the shared instance; only the switch and the bid turning on reset it
  const k = mk({ rateCap: 1e18 }); k.setSettings({ valueModeOn: true, balanceBidOn: true }, 0); k.balRate = 10500;
  k.setSettings({ climbPerMin: 0.5 }, 0); near(k.balRate, 10500, 1e-12, 'a settings change leaves it');
  k.setSettings({ balanceBidOn: false }, 0); near(k.balRate, 10500, 1e-12, 'the balance door off leaves it');
  k.setSettings({ balanceBidOn: true }, 0); near(k.balRate, 9000, 1e-12, 'the balance door turning on resets it');
  k.balRate = 10500; k.setBalanceModule(0, U); near(k.balRate, 10500, 1e-12, 'a module change in value mode leaves it');
  // the eth rate is bounded by rateCap and by the room
  const capped = mk({ rateCap: 1e14 }); capped.setSettings({ valueModeOn: true }, 0); near(capped.ethRate(0), 1e14, 1e-12, 'rateCap bounds a hostile value'); n++;
  // a whole run switches on day 2 and keeps buying
  const run = simL({ days: 4, balanceDay: 1, balancePoolSet: true, ...Q, schedule: [{ day: 2, patch: { valueModeOn: true, balanceBidOn: true, balanceBidCapBps: 11000 } }] });
  const day3 = run.S.spent.slice(2 * 24, 4 * 24).reduce((a, b) => a + (b || 0), 0);
  ok(run.core.s.valueModeOn && day3 > 0, 'a run switched to value mode on day 2 keeps spending the pot');
  ok(run.core.refMult > 0 && run.core.valuePerPoint(false, 4 * 24 * H).ok, 'the keeper observes, so the quote stays usable');
}

// buyback slice and the caller payment (docs/DECISIONS.md 61): the caller is paid 270,000 gas at min(basefee, keeperMaxBaseFee) plus keeperFee out of the slice.
// promise: the swap budget is the slice less the largest payment (600,000 gas at the capped rate plus keeperFee), the unspent part of that reserve goes back to the pot
{
  const c = fresh(); c.ethToBuyback = 2.5; // 1 gwei base fee, keeperFee 0.0003, keeperMaxBaseFee 5 gwei (launch)
  const a = c.takeBuybackSlice(1000);
  near(a.slice, 0.5, 1e-12, 'slice is at most 0.5 eth');
  near(a.tip, 270000e-9 + 0.0003, 1e-12, 'payment is 270,000 gas at 1 gwei plus the keeper fee');
  near(a.budget, 0.5 - (600000e-9 + 0.0003), 1e-12, 'the swap budget is the slice less the reserve');
  near(c.ethToBuyback, 2.0 + (600000e-9 - 270000e-9), 1e-12, 'the unspent reserve is back in the buyback pot');
  assert.equal(c.takeBuybackSlice(1000 + 299), null); n++; // 25 blocks = 300 s
  ok(c.takeBuybackSlice(1000 + 300));
  near(c.ethToBuyback, 1.5 + 2 * (600000e-9 - 270000e-9), 1e-12, 'pool after two slices');
  // a base fee above keeperMaxBaseFee is paid at the cap
  const hi = fresh({ basefeeGwei: 50 }); hi.ethToBuyback = 2.5;
  near(hi.takeBuybackSlice(0).tip, 270000 * 5e-9 + 0.0003, 1e-12, 'paid at the 5 gwei cap');
  const lo = fresh({ basefeeGwei: 5 }); lo.ethToBuyback = 2.5;
  near(lo.takeBuybackSlice(0).tip, 270000 * 5e-9 + 0.0003, 1e-12, 'at the cap the actual base fee');
  // a slice under twice the largest payment is not called (SliceTooSmall), nothing moves. the reserve is 600,000 gas at 5 gwei plus 0.0003 = 0.0033
  const small = fresh({ basefeeGwei: 50, buybackSlice: 0.0067 }); small.ethToBuyback = 0.0065;
  assert.equal(small.takeBuybackSlice(0), null); near(small.ethToBuyback, 0.0065, 1e-15, 'the pot is untouched'); assert.equal(small.lastBuybackTime, -1e12); n += 2;
  small.ethToBuyback = 0.0067; ok(small.takeBuybackSlice(0), 'a slice of just over twice the payment is called');
  // a small pot pays a share of the fee: the swap budget over the largest budget the setting allows
  const part = fresh({ basefeeGwei: 10 }); part.ethToBuyback = 0.0265; // slice 0.0265, maxPay 0.0033 at the 5 gwei cap, largest budget 0.5 - 0.0033
  near(part.takeBuybackSlice(0).tip, 270000 * 5e-9 + 0.0003 * (0.0265 - 0.0033) / (0.5 - 0.0033), 1e-12, 'the keeper fee scales with the budget');
  // the buybackSlice lower bound is 0.01 eth: twice the largest launch payment (0.0066) is below it, so the fixed floor binds (decision 119)
  ok(firstViolation(Object.assign({}, SETTINGS, { buybackSlice: 0.01 })) === null, 'at the 0.01 eth floor is inside'); n++;
  assert.equal(firstViolation(Object.assign({}, SETTINGS, { buybackSlice: 0.0065 })), 'buybackSlice'); n++;
  const free = fresh({ keeperFee: 0, basefeeGwei: 1 }); free.ethToBuyback = 1;
  near(free.takeBuybackSlice(0).tip, 270000e-9, 1e-12, 'no keeper fee leaves the gas refund');
  assert.throws(() => free.setSettings({ keeperFee: -1 }, 0), /keeperFee/); assert.throws(() => free.setSettings({ keeperMaxBaseFee: -1 }, 0), /keeperMaxBaseFee/);
  assert.throws(() => free.setSettings({ keeperMaxBaseFee: Number(1n << 48n) / 1e9 }, 0), /keeperMaxBaseFee/); n += 3;
  ok(firstViolation(Object.assign({}, SETTINGS, { keeperFee: 0.005, keeperMaxBaseFee: 100 })) === null, 'the upper bounds are inside'); n++;
  ok(SETTINGS.keeperTipBps === undefined, 'keeperTipBps is gone from the model'); n++;
}
// promise: launch position: whole supply single sided, price 2.513e-8 eth per coin at the start tick
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
// skim schedule: anti sniper 90 points falling to the 10 point baseline over 30 minutes. the Core gets bountyBps 9000 of the baseline
// promise: plus the whole anti sniper extra (decision 120). once payeeOn the payee takes payeePpm of the income (0 at launch; this block sets 75,185 ppm to exercise the push)
{
  near(skimFraction(DEFAULTS, 0), 0.9, 1e-12, 'launch skim'); near(skimFraction(DEFAULTS, 900), (0.9 + 0.1) / 2, 1e-12, 'midway');
  near(skimFraction(DEFAULTS, 1800), 0.1, 1e-12, 'end of window'); near(skimFraction(DEFAULTS, 99999), 0.1, 1e-12, 'baseline');
  near(bountyFeeFraction(DEFAULTS, 0.1), 0.09, 1e-12, 'Core 9 points, bountyBps 9000 of the 10 point baseline'); near(bountyFeeFraction(DEFAULTS, 0.9), 0.09 + 0.8, 1e-12, 'extra to the Core');
  // Core._book: the payee takes payeePpm of each book once payeeOn. the first book at or after sniperSeconds with income sets payeeOn and takes 0
  // feeToRedeemBurnBps is 1,000 here (its phase-2 value) to exercise the reserve split with the payee; launch is 0
  const pc = new Core(Object.assign({}, DEFAULTS, { payeePpm: 75185, feeToRedeemBurnBps: 1000 }), 0);
  pc.addFees(100, 1799); near(pc.ethPot, 90, 1e-12, 'before the window the pot gets 90 of 100, the reserve 10'); near(pc.payeePaid, 0, 1e-12, 'the payee gets 0 before the window');
  pc.addFees(100, 1800); near(pc.ethPot, 180, 1e-12, 'the first book at the window end shares 0'); ok(pc.payeeOn && pc.payeePaid === 0, 'the payee share starts');
  pc.addFees(100, 1900); near(pc.payeePaid, 7.5185, 1e-12, 'the payee takes payeePpm after the window');
  near(pc.ethPot, 180 + 83.23335, 1e-9, 'the pot gets the income less the payee and the reserve share');
  near(pc.ethRedeemBurn, 20 + 9.24815, 1e-9, 'the reserve takes feeToRedeemBurnBps of the income after the payee');
  const pz = new Core(DEFAULTS, 0); pz.addFees(0, 5000); ok(!pz.payeeOn, 'a zero income book leaves payeeOn false');
  const p0 = new Core(DEFAULTS, 0); p0.addFees(100, 1800); p0.addFees(100, 1900); near(p0.payeePaid, 0, 1e-12, 'payeePpm 0 at launch pushes nothing to the payee');
  // Core.fund: whole, the payee and reserve shares are 0
  const pf = new Core(Object.assign({}, DEFAULTS, { payeePpm: 75185, feeToRedeemBurnBps: 1000 }), 0); pf.addFees(100, 1900); pf.fund(50, 1900);
  near(pf.ethPot, 90 + 50, 1e-12, 'fund adds to the pot whole'); near(pf.ethRedeemBurn, 10, 1e-12, 'fund books a reserve share of 0'); near(pf.payeePaid, 0, 1e-12, 'and a payee share of 0');
  let d0 = 0;
  for (let t = 0; t < 3600; t += 120) d0 += stepVolume(DEFAULTS, t, 120);
  near(d0, 1557 * 0.586, 1e-9, 'first hour volume');
  for (let h = 1; h < 24; h++) d0 += stepVolume(DEFAULTS, h * 3600, 3600);
  near(d0, 1557, 1e-9, 'day one volume');
}
// promise: whole runs: deterministic, every eth identity closes, nothing negative
{
  const a = simC({ days: 20, seed: 3 }), b = simC({ days: 20, seed: 3 }), c = simC({ days: 20, seed: 4 });
  assert.deepEqual(a.S.pot, b.S.pot); n++;
  assert.notDeepEqual(a.S.pot, c.S.pot); n++;
  for (const r of [a, simC({ days: 40, saleFloorBps: 6000, seed: 5 }), simC({ days: 40, feeToRedeemBurnBps: 2500, seed: 6 }), simC({ days: 40, basefeeGwei: 40, seed: 9 }), simC({ days: 40, buyerWaits: 'floor', feeToRedeemBurnBps: 10000, seed: 8 }), simC({ days: 40, balanceDay: 12, xpPerPoint: 3e-5 / 440, stmtPick: 'random' }), simC({ days: 40, balanceDay: 12, balanceDayMode: 1, feeToRedeemBurnBps: 1000, seed: 11 }), simC({ days: 40, balanceDay: 12, balancePoolSet: true, feeToRedeemBurnBps: 3000, seed: 12 })]) {
    ok(Math.abs(r.stats.potCheck) < 1e-6, 'pot accounting ' + r.stats.potCheck);
    ok(Math.abs(r.stats.buybackCheck) < 1e-9, 'buyback accounting ' + r.stats.buybackCheck);
    ok(Math.abs(r.stats.redeemCheck) < 1e-9, 'redeem burn reserve accounting ' + r.stats.redeemCheck);
    ok(Math.abs(r.stats.saleCheck) < 1e-9, 'sale accounting ' + r.stats.saleCheck);
    ok(Math.abs(r.stats.cutsCheck) < 1e-9, 'artist and operator cuts accounting ' + r.stats.cutsCheck);
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
  ok(wf.stats.saleAgeHours >= 12 - 1e-9, 'and only after the asking price has reached it (the floor at hour 12)');
  // a settings change mid run: controller settings on day 5, the floors and splits on day 10, all read at once
  const sw = simC({ days: 20, seed: 3, schedule: [{ day: 5, patch: { markupBps: 13000, decayHours: 24 } }, { day: 10, patch: { saleFloorBps: 6000, feeToRedeemBurnBps: 2500, saleToBuybackBps: 7500 } }] });
  assert.equal(sw.core.c.floorBps, undefined); assert.equal(sw.core.s.saleFloorBps, 6000); n += 2;
  assert.equal(sw.core.c.markupBps, 13000); assert.equal(sw.core.c.decayHours, 24); assert.equal(sw.core.s.saleToBuybackBps, 7500); assert.equal(sw.core.s.feeToRedeemBurnBps, 2500); assert.equal(sw.T.settingsChanges, 2); n += 4;
  ok(sw.core.feeToRedeemBurn > 0, 'the fee share starts at its change'); ok(Math.abs(sw.stats.potCheck) < 1e-6, 'accounting closes across settings changes');
  ok(Math.abs(sw.stats.buybackCheck) < 1e-9, 'buyback accounting closes across settings changes');
  const f0 = simC({ days: 20, seed: 3 }), f1 = simC({ days: 20, seed: 3, feeToRedeemBurnBps: 10000 });
  assert.equal(f0.core.feeToRedeemBurn, 0); ok(f1.core.feeToRedeemBurn > 0.9 * f1.S.cumFees[f1.H], 'at 10000 every fee goes to the reserve'); n++;
  ok(f1.T.sold >= 0 && f1.S.credits[f1.H] < f0.S.credits[f0.H], 'sending the fees to the reserve leaves less to buy credits');
  const p2 = simC({ days: 30, balanceDay: 10, xpPerPoint: 3e-5 / 440, seed: 3 });
  ok(p2.T.redeemed > 0 && p2.T.redeemedAge > 0, 'held statements are redeemed through the balanceModule');
  const s = summary(a); ok(s.credits > 0 && s.statements > 0 && (s.potGoneDay === null || s.potGoneDay > 1), 'summary reads the run: the pot is spent after day one, or lasts the 20 days');
}
// whole runs at the launch values (FLOW 85, 86): statements fall to their reference and wait there while no balance module is set, the redeem burn reserve is 0 at launch (the phase-2 wiring sets feeToRedeemBurnBps to 1,000),
// promise: the balance side in hold mode redeems at the floor and stops the bid, the balance side on adds the balance token bid, whose credits join the one pile (FLOW 92)
{
  const base = { days: 30, seed: 3, stepSec: 300 };
  const L = simulate(base);
  const closes = (r, tag) => { ok(Math.abs(r.stats.potCheck) < 1e-6 && Math.abs(r.stats.saleCheck) < 1e-9 && Math.abs(r.stats.buybackCheck) < 1e-9 && Math.abs(r.stats.redeemCheck) < 1e-9, 'accounting closes ' + tag); };
  closes(L, 'at launch');
  ok(L.core.s.redeemOn === true && L.core.s.balanceBidOn === false && L.core.moduleSet === false && L.T.redeemed === 0 && L.T.boughtX === 0 && L.core.balancePot === 0, 'redeemOn true but no module set, balanceBidOn false: no redemption, no balance token bid');
  ok(L.T.sold > 0 && L.T.soldPrice >= L.T.soldCost * (1 - 1e-9), 'every sale clears at or above cost (the launch hard floor)');
  // the curve reaches its floor, the reference, decayHours (4) hours after listing. at the launch climb of 100 (decision 151) the 30 day run leaves a handful waiting, not hundreds
  const endSec = L.H * 3600, hoursToCost = L.core.c.decayHours, old = L.unbid.filter((st) => endSec - st.t0 >= hoursToCost * H);
  ok(L.unbid.length >= 3 && old.length >= 3, 'statements wait'); ok(old.every((st) => Math.abs(L.core.askingPrice(st, endSec) - L.core.reference(st, endSec)) < 1e-12 * L.core.reference(st, endSec)), 'and every one past that age is asked at its reference');
  ok(L.unbid.every((st) => L.core.askingPrice(st, endSec) >= st.cost * (1 - 1e-12)), 'none is asked under its cost');
  near(L.core.feeToRedeemBurn, 0, 1e-12, 'the reserve share is 0 at launch'); near(L.core.ethRedeemBurn, L.core.feeToRedeemBurn, 1e-12, 'the reserve equals the fee share, redemptions and releases aside');
  ok(L.core.redeemBurnMoved === 0, 'no redemption, no move to the buyback');
  // the phase-2 value 1,000 sends 10 percent of the fees to the reserve and leaves fewer credits bought than the launch pot
  const res = simulate(Object.assign({ feeToRedeemBurnBps: 1000 }, base));
  near(res.core.feeToRedeemBurn, 0.1 * (res.T.fees + res.T.feesBuyback - res.core.payeePaid), 1e-9, 'the reserve takes 10 percent of the fees booked at the phase-2 value');
  ok(L.S.credits[L.H] > res.S.credits[res.H] * 0.99 - 1, 'the launch reserve share of 0 leaves the pot with the whole fee stream, at least as many credits');
  // hold: redemptions at the floor, the bid stopped
  const hold = simulate(Object.assign({ feeToRedeemBurnBps: 1000, balanceDay: 10, balanceDayMode: 1 }, base));
  closes(hold, 'in hold');
  ok(hold.T.redeemed > 0 && hold.T.boughtX === 0 && hold.core.balancePot > 0, 'hold mode redeems and keeps the balance token without a bid');
  ok(hold.core.redeemBurnMoved > 0 && hold.core.ethRedeemBurn < hold.core.feeToRedeemBurn, 'each redemption moves part of the reserve to the buyback');
  ok(hold.T.redeemedAge / hold.T.redeemed >= hold.core.c.decayHours * H - 1, 'a statement redeems no earlier than its curve reaches its floor (decayHours, 4 at launch)');
  ok(hold.T.redeemedValue > 0 && hold.core.balancePot === hold.T.xRecv, 'the balance token pot is what the redemptions returned');
  // on: the bid buys credits at the margin under their value into the one pile and the statements built from them sell or redeem like the rest. the bid needs no pool key (FLOW 96)
  const on = simulate(Object.assign({ feeToRedeemBurnBps: 1000, balanceDay: 10, balancePoolSet: true }, base));
  closes(on, 'with the bid');
  ok(on.T.boughtX > 0 && on.core.redeemBurnMoved > 0, 'the bid buys and redemptions release the reserve');
  ok(on.T.redeemed > 0 && on.core.balancePot > 0, 'statements redeem');
  ok(on.S.credits[on.H] > hold.S.credits[hold.H], 'the bid adds credits'); ok(on.T.composed > hold.T.composed, 'and they compose into statements through the one pile');
  const noKey = simulate(Object.assign({ feeToRedeemBurnBps: 1000, balanceDay: 10 }, base)); ok(noKey.T.boughtX > 0 && noKey.T.redeemed > 0, 'the bid buys without the pool key and redemptions run (FLOW 96)'); closes(noKey, 'without the pool key');
  // a later switch off stops the bid at once
  const off = simulate(Object.assign({ feeToRedeemBurnBps: 1000, balanceDay: 10, balancePoolSet: true, schedule: [{ day: 12, patch: { redeemOn: false, balanceBidOn: false } }] }, base));
  ok(off.T.boughtX > 0 && off.S.xBought[off.H] === off.S.xBought[12 * 24 + 1], 'both switches false on day 12 ends the bid and the redemptions'); ok(off.S.redeemed[off.H] === off.S.redeemed[12 * 24 + 1], 'no redemption after the switch off'); closes(off, 'after a switch off');
  // the pool key (value floor) raises the price a buyer pays and changes nothing else about eligibility
  const pool = simulate(Object.assign({ feeToRedeemBurnBps: 1000, balanceDay: 10, balanceDayMode: 1, balancePoolSet: true, xpPerPoint: 4e-4 }, base));
  closes(pool, 'with the value floor');
}
// whole runs with the credit sale window (FLOW 88): on at launch (decision 119). the books close, every credit sells at or above its cost, the proceeds split by the artist and operator cuts
// promise: then creditCostToPotBps, compose waits for the window, and a run with the sale off sells no credits. chosen composition (FLOW 89) with a composer that names the richest credits builds richer statements
{
  const base = { days: 30, seed: 3, stepSec: 300 };
  const off = simulate(Object.assign({ creditSaleOn: false }, base)), on = simulate(base); // the credit sale is on at launch by default
  ok(Math.abs(off.stats.creditCheck) < 1e-12 && off.T.creditSold === 0 && off.stats.potCheck < 1e-6, 'the sale off: no credit sells'); n++;
  assert.deepEqual(simulate(Object.assign({ creditSaleOn: false, creditCostToPotBps: 5000 }, base)).S.credits, off.S.credits); n++; // a setting of the off feature changes nothing
  ok(on.T.creditSold > 50, 'credits sell through the window'); ok(Math.abs(on.stats.creditCheck) < 1e-9, 'the sale proceeds split exactly');
  ok(Math.abs(on.stats.potCheck) < 1e-6 && Math.abs(on.stats.saleCheck) < 1e-9 && Math.abs(on.stats.buybackCheck) < 1e-9 && Math.abs(on.stats.redeemCheck) < 1e-9 && Math.abs(on.stats.cutsCheck) < 1e-9, 'accounting closes with the credit sale');
  ok(on.T.creditGross >= on.T.creditCost * 1.02 * (1 - 1e-9), 'every credit sells at or above 102 percent of its cost (creditSpreadBps 200 at the 10000 cap)'); near(on.T.creditToPot, on.T.creditCost * 0.8, 1e-9, 'creditCostToPotBps 8000: 80 percent of the cost to the pot');
  near(on.T.creditToBuyback, on.T.creditGross - on.T.creditToArtist - on.T.creditToOperator - on.T.creditToPot, 1e-9, 'the rest of the payment to the buyback pot'); n += 6;
  // the artist and operator cuts (decision 123): saleToArtistBps 250 and saleToOperatorBps 50 of every statement and credit sale, pushed out
  near(on.T.creditToArtist, 0.025 * on.T.creditGross, 1e-9, 'saleToArtistBps 250 of every credit sale'); near(on.T.creditToOperator, 0.005 * on.T.creditGross, 1e-9, 'saleToOperatorBps 50 of every credit sale');
  near(on.T.saleToArtist, 0.025 * on.T.saleGross, 1e-9, 'saleToArtistBps 250 of every statement sale'); near(on.T.saleToOperator, 0.005 * on.T.saleGross, 1e-9, 'saleToOperatorBps 50 of every statement sale');
  near(on.core.artistPaid, on.T.saleToArtist + on.T.creditToArtist, 1e-12, 'the artist is pushed every cut'); near(on.core.operatorPaid, on.T.saleToOperator + on.T.creditToOperator, 1e-12, 'the operator cut is pushed to the payee'); n += 6;
  const noCut = simulate(Object.assign({ saleToArtistBps: 0, saleToOperatorBps: 0 }, base)); near(noCut.T.saleToArtist + noCut.T.creditToArtist, 0, 1e-15, 'cuts 0 push nothing'); n++;
  assert.throws(() => on.core.setSettings({ saleToArtistBps: 10001 }, 1), /saleToOperatorBps/); assert.throws(() => on.core.setSettings({ saleToOperatorBps: 10001 }, 1), /saleToOperatorBps/); n += 2;
  const half = simulate(Object.assign({ creditCostToPotBps: 5000 }, base));
  near(half.T.creditToPot, 0.5 * half.T.creditCost, 1e-9, 'creditCostToPotBps 5000'); ok(Math.abs(half.stats.creditCheck) < 1e-9, 'the rest goes to the buyback pot'); n += 2;
  // compose waits for the window: with a 4 hour window no statement is composed from a credit younger than that
  const w = simulate(Object.assign({ creditSaleOn: true, creditWindow: 48 * H }, base)), seen = [];
  const watch = simulate(Object.assign({ creditSaleOn: true, creditWindow: 48 * H, onStep: (t, core, Pe, rr, T) => { if (T.composed > seen.length) seen.push(t); } }, base));
  ok(w.T.composed > 0 && w.T.composed <= off.T.composed, 'a longer window composes later, not more'); ok(watch.pile.every((c) => c.t0 <= watch.H * 3600), 'the pile holds credits of any age'); n += 2;
  ok(seen.length > 0 && seen[0] >= 48 * H, 'no statement before a credit has waited out a 48 hour window'); n++;
  const paused = simulate(Object.assign({ creditSaleOn: true, schedule: [{ day: 1, patch: { paused: true } }] }, base)); ok(paused.T.creditMiss > 0 && paused.T.creditSold < on.T.creditSold, 'sales are paused, credit sales too'); n++;
  const mid = simulate(Object.assign({ creditSaleOn: false, schedule: [{ day: 10, patch: { creditSaleOn: true } }] }, base)); ok(mid.T.creditSold > 0 && mid.S.creditSold[10 * 24] === 0, 'the owner turns the sale on mid run'); n++;
  // chosen composition: a composer that names the richest ready credits builds richer statements than compose() does from the oldest
  // the ready count stays near one page, so the choice ranks little: the richer-statement claim is checked on six seeds with a 72 hour window and 600 second steps
  // the run keeps the climb of 200 bps a minute and the credit floor of 1.1 (spread 1000 at the 10000 cap) it was written for: at the launch
  // climb 100 (decision 151) and spread 200 (decision 153) more credits sell and the ready count is one page, so the choice ranks nothing
  const win = { creditSaleOn: true, creditWindow: 72 * H, days: 30, seed: 4, stepSec: 600, stmtPerDay: 2, climbPerMin: 2, recoveryClimbPerMin: 2, creditSpreadBps: 1000 };
  const std = simulate(win), pick = simulate(Object.assign({ chosenComposeOn: true, composeChoice: 'richest' }, win));
  ok(pick.T.composedChosen > 0 && std.T.composedChosen === 0, 'composeChosen runs only when the owner opens it');
  // the per seed margin is under 0.1 percent (the ready count stays near one page), so the claim is checked on the mean over six seeds
  let richer = 0, stdAvg = 0;
  for (const seed of [4, 5, 6, 7, 8, 9]) { const w2 = Object.assign({}, win, { seed }), s2 = seed === 4 ? std : simulate(w2), p2 = seed === 4 ? pick : simulate(Object.assign({ chosenComposeOn: true, composeChoice: 'richest' }, w2)); richer += p2.T.stRating / p2.T.composed; stdAvg += s2.T.stRating / s2.T.composed; }
  ok(richer > stdAvg, 'and the statements it builds are richer, mean of six seeds');
  const gated = simulate(Object.assign({ composeChoice: 'richest' }, win)); assert.equal(gated.T.composedChosen, 0); assert.deepEqual(gated.S.composed, std.S.composed); n += 4; // the composer needs chosenComposeOn
  ok(Math.abs(pick.stats.potCheck) < 1e-6 && Math.abs(pick.stats.creditCheck) < 1e-9, 'the books close with chosen composition'); n++;
}
// sub-hour step: five minute and one minute steps give the same economy within 10 percent, and the books close. the hourly step is a
// promise: different run here: the stepped rule reads its drop floor and climb per minute, and an hour step distorts it
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
// promise: bid rule: the stepped rule (CoreLib.climb and drop)
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
  const rs = (share) => (share * 0.0089e18 * 100) / 433;
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
// promise: clamp, askFloor
{
  const R = 1e13, MIN = 60;
  const c1 = fresh({ rateStart: R, climbPerMin: 50, ceilPct: 1000, rateCap: 1e18 }, 0.1);
  near(c1.clamp(), 0.1 * W, 1e-12, 'clamp affords one credit: the pot');
  const f = simL({ days: 3, seed: 2, askFloor: 0.8 });
  const g = simL({ days: 3, seed: 2 }); ok(f.stats.costVsMarket >= g.stats.costVsMarket - 0.2, 'a floor on seller asks does not lower the price paid');
}
// promise: idle loosening of the stepped ceiling anchor, gap path, forced fill, bot drain, stall metric
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
  const rs = (share) => (share * 0.0089e18 * 100) / 433;
  const base = { days: 2, seed: 2, stepSec: 60, rateStart: rs(1) };
  const ff = simC(Object.assign({ forceFillHour: 6, forceFillFrac: 0.5 }, base));
  ok(Math.abs(ff.stats.potCheck) < 1e-6, 'accounting closes with a forced fill'); ok(ff.T.throttled === 0, 'a forced fill is not counted as a throttler credit');
  const st0 = simC(Object.assign({ pricePath: 'gap', gapPct: 300, gapHour: 6, idleLoosenPct: 0.01, days: 3 }, { seed: 2, stepSec: 60, rateStart: rs(1) }));
  const st1 = simC(Object.assign({ pricePath: 'gap', gapPct: 300, gapHour: 6, idleLoosenPct: 2, days: 3 }, { seed: 2, stepSec: 60, rateStart: rs(1) }));
  ok(st0.stats.stallHours > st1.stats.stallHours, 'idle loosening shortens the stall after a gap up'); ok(st0.stats.stallRuns.length >= 1 && st0.stats.stallHoursMax > 2, 'a stall run is recorded');
}
// promise: stepped: the clamp bounds the bid that is read and paid, and is never stored. the drop and the anchor use the price state rate
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
// promise: the unmodified defaults are the launch run: minute steps, the launch fee split, books close
{
  const r = simulate({ days: 6, seed: 3 });
  ok(r.params.stepSec === 60, 'the default run is the launch rule at minute steps');
  ok(Math.abs(r.stats.potCheck) < 1e-6 && Math.abs(r.stats.saleCheck) < 1e-6, 'accounting closes on the default run');
  ok(r.S.rate.every((rate) => rate <= r.params.rateCap), 'the configured rate cap bounds every recorded default bid');
  ok(summary(r, 6).credits > 0, 'the default run acquires credits under its spend cap');
}
// the swap door (Core.swapCredit, decision 116): swaps a pile credit for one of equal or higher score, the caller burning swapFeeCc coins.
// promise: the incoming credit inherits the node (cost, acquisition time); a lower score is refused; a pause refuses
{
  const c = fresh({}, 10); // swapFeeCc is the launch value, ten thousand coins
  near(c.s.swapFeeCc, 10000, 1e-12, 'the launch swap fee is ten thousand coins');
  const out = { pts: 300, cost: 0.5, t0: 7 * H };
  const burned = c.swapCredit(out, 500, 20 * H);
  near(burned, 10000, 1e-12, 'the caller burns swapFeeCc coins'); near(c.swapBurned, 10000, 1e-12, 'the coins burned are tracked');
  assert.equal(out.pts, 500); near(out.cost, 0.5, 1e-15, 'the cost basis is inherited'); assert.equal(out.t0, 7 * H); n += 2; // the node is inherited: only the score changes
  const eq = { pts: 400, cost: 0.2, t0: 0 }; ok(c.swapCredit(eq, 400, 0) !== null, 'equal score swaps'); assert.equal(eq.pts, 400); n += 2;
  const lowc = { pts: 400, cost: 0.2, t0: 0 }; assert.equal(c.swapCredit(lowc, 399, 0), null); assert.equal(lowc.pts, 400); n += 2; // ScoreTooLow, nothing changes
  const pz = fresh({}, 10); pz.setPaused(true, 0); assert.equal(pz.swapCredit({ pts: 100, cost: 0.1, t0: 0 }, 200, 0), null); near(pz.swapBurned, 0, 1e-15, 'nothing burns while paused'); n++;
  const zf = fresh({ swapFeeCc: 0 }, 10); near(zf.swapCredit({ pts: 100, cost: 0.1, t0: 0 }, 100, 0), 0, 1e-15, 'a zero fee burns nothing'); near(zf.swapBurned, 0, 1e-15, 'and tracks nothing');
  assert.throws(() => c.setSettings({ swapFeeCc: Number(1n << 96n) / W }, 1), /swapFeeCc/); assert.equal(firstViolation(Object.assign({}, SETTINGS, { swapFeeCc: 1e6 })), null); n += 2; // 0 to 1e24 wei coins (1e6 whole coins)
}
// promise: integer spend vectors accept exact equality, reject one wei over, and leave failed buckets untouched.
{
  const E = 10n ** 18n, b = new SpendBucket();
  assert.equal(b.charge(50n * E, 100n * E, 0, 60, 5000), true);
  const before = { ...b };
  assert.equal(b.charge(1n, 50n * E, 59, 60, 5000), false);
  assert.deepEqual({ ...b }, before);
  assert.equal(b.charge(E, 50n * E, 60, 60, 5000), true);
  assert.equal(b.pot, 50n * E); assert.equal(b.spent, E);
  const empty = new SpendBucket();
  assert.equal(empty.charge(1n, 99n, 0, 60, 100), true); assert.equal(empty.id, 0); assert.equal(empty.spent, 1n); // the first purchase of a bucket passes a zero-rounded budget
  const kept = { ...empty };
  assert.equal(empty.charge(1n, 99n, 1, 60, 100), false); assert.deepEqual({ ...empty }, kept); // the second purchase needs spent + cost <= budget
  const small = new SpendBucket(); // a budget of 5 wei under a 10 wei credit: one purchase per bucket
  assert.equal(small.charge(10n, 100n, 0, 60, 500), true); assert.equal(small.charge(1n, 100n, 1, 60, 500), false);
  assert.equal(small.charge(10n, 100n, 60, 60, 500), true); assert.equal(small.spent, 10n);
  n += 15;
}
// promise: bypass purchases count, a cap edit retains the original snapshot, and duration edits retain active spending.
{
  const E = 10n ** 18n, b = new SpendBucket();
  assert.equal(b.charge(75n * E, 100n * E, 1, 60, 10000), true);
  assert.equal(b.charge(30n * E, 50n * E, 2, 60, 10000), true);
  assert.equal(b.pot, 100n * E); assert.equal(b.spent, 105n * E);
  assert.equal(b.charge(1n, 1000n * E, 3, 60, 9999), false);
  b.rebase(31, 60, 10); assert.equal(b.id, 3);
  assert.equal(b.charge(1n, 1000n * E, 31, 10, 9999), false);
  assert.equal(b.charge(1n, 1000n * E, 40, 10, 100), true);
  const expired = new SpendBucket();
  expired.charge(50n * E, 100n * E, 0, 60, 5000);
  expired.rebase(70, 60, 100);
  assert.equal(expired.charge(E, 20n * E, 70, 100, 1000), true);
  assert.equal(expired.pot, 20n * E);
  n += 10;
}
// promise: rejected purchases and batches restore state; deposits and unrelated owner edits do not grant a new budget.
{
  const c = fresh({ spendCapBps: 100, rateStart: 5e15 }, 1);
  const first = c.sellForEth(1); ok(first > 0, 'first credit succeeds');
  const spent = c.spendBucket.spent, snapshot = c.spendBucket.pot;
  c.fund(10, 2); c.setSettings({ keeperFee: 0, rate: 5e15, spendCapBps: 50, bucketSeconds: 10 }, 3);
  assert.equal(c.spendBucket.spent, spent); assert.equal(c.spendBucket.pot, snapshot); n += 2;
  const before = { ...c, spendBucket: { ...c.spendBucket }, fillBuckets: structuredClone(c.fillBuckets) };
  assert.equal(c.sellForEth(4), 0);
  assert.deepEqual({ ...c, spendBucket: { ...c.spendBucket } }, before); n += 2;
  const b = fresh({ spendCapBps: 50, rateStart: 4e15 }, 1);
  const initial = { ...b, spendBucket: { ...b.spendBucket }, fillBuckets: structuredClone(b.fillBuckets) };
  assert.equal(b.sellForEthBatch([433, 433], 0), 0);
  assert.deepEqual({ ...b, spendBucket: { ...b.spendBucket } }, initial); n += 2;
  const listing = fresh({ spendCapBps: 1 }, 1);
  ok(listing.buyListing(0.001, 30) !== null, 'the first purchase of a bucket passes a budget under its cost');
  const state = { ...listing, spendBucket: { ...listing.spendBucket } };
  assert.equal(listing.buyListing(0.001, 30), null);
  assert.equal(listing.checkpointTime, state.checkpointTime); assert.equal(listing.spendBucket.spent, state.spendBucket.spent); n += 3;
}
// promise: balance conversion preserves both adjustable caps beyond the former 320-denominator saturation.
{
  const vector = balanceConversion(500n, 1n, 20000, 40000, 20000n, 8000);
  assert.deepEqual(vector, { clamp: 20000n, multiplier: 31250n });
  assert.equal(balanceConversion(10n ** 77n, 1n, 2 ** 32 - 1, 65535, 1n, 8000).multiplier, 65535n);
  n += 2;
  const c = fresh({ balanceBidOn: true, balanceBidCapBps: 20000, climbMultiplierCapBps: 40000, multiplierCap: null, spendCapBps: 1, ceilPct: 200 }, 1);
  c.setBalanceModule(0, 0.001); c.balancePot = 100;
  near(c.balAvailBps(), 20000, 1e-12, 'available clamp can exceed par');
  near(c.balanceRate(1000000), 20000, 1e-12, 'the balance bid climbs above par to the configured cap');
  ok(c.xBuy(433, 1000000) > 0, 'the ETH spend cap does not constrain balance purchases');
  assert.equal(c.spendBucket.id, null); n++;
}
// promise: the multiplier uses last fill, ordinary climb stays unscaled, and anchor movement zero preserves its clock.
{
  const c = fresh({ multiplierCap: null, climbMultiplierCapBps: 40000, rateStart: 1e16, idleLoosenPct: 6, climbPerMin: 1, recoveryClimbPerMin: 1 }, 100);
  c.rateAtCheckpoint = 2e16;
  near(c.bidMult(), 4, 1e-12, 'the pages divisor is the last fill rate');
  c.rateAtCheckpoint = 1e16;
  near(c.priceRate(60), 1e16 * 1.01, 1e-12, 'four pages do not scale the minute climb');
  c.setAnchor(20000, 0); c.setSettings({ anchorMoveBps: 0 }, 1);
  const anchorTime = c.anchorTime;
  ok(c.buy(c.compose(1, 2), 2), 'the qualifying statement sale succeeds');
  assert.equal(c.anchorTime, anchorTime); n++;
  const m = fresh({ anchorMoveBps: 2500 }, 10);
  m.buy(m.compose(1, 0), 0); assert.equal(m.anchorStored, 11250); n++;
  const z = fresh({ balanceBidOn: true, balanceBidMarginBps: 10000 }, 1);
  z.setBalanceModule(0, 0.001); z.balancePot = 100;
  assert.equal(z.balanceRate(100000), 0); n++;
}
// promise: both bucket alignments retain accounting and distinguish a non-crossing from market recovery.
{
  const { assumptions, rows } = runSpendCapStudy();
  assert.equal(rows.length, 12); n++;
  for (const row of rows) {
    assert.equal(row.stopped.credits + row.remainingCredits, assumptions.credits);
    near(row.stopped.spentEth + row.finalPotEth, assumptions.initialPotEth, 1e-12, 'bounded scenario funds reconcile');
    assert.ok(row.stopped.seconds % assumptions.blockSeconds === 0);
    assert.ok(row.stopped.seconds <= assumptions.sellingHorizonSeconds);
    if (row.crossing === null) assert.equal(row.recoverySecondsAfterStop, null);
    else {
      assert.ok(row.crossing.referenceBidEth < row.crossing.askEth);
      if (row.scenario === 'collapse') assert.ok(row.crossing.seconds >= assumptions.collapseSeconds);
    }
    n += 4;
  }
}
// promise: duration edits preserve active drop floors and discard expired floors on both bid instances.
{
  const make = () => {
    const c = fresh({ dropPerCreditPct: 50, dropToPct: 50, rateStart: 1e16, balanceBidOn: true, balanceBidMarginBps: 9000 }, 100);
    c.setBalanceModule(0, 0.001); c.balancePot = 100;
    c.setSettings({ rate: 1e16 }, 120);
    c.balRate = 10000; c.balLastFillRate = 10000; c.balPeakRate = 10000;
    c.balCheckpointTime = 120; c.balLastFillTime = 120; c.balPeakTime = 120;
    ok(c.sellForEth(120) > 0, 'the ETH fill opens bucket two');
    ok(c.xBuy(433, 120) > 0, 'the balance fill opens bucket two');
    return c;
  };
  const active = make();
  active.setSettings({ bucketSeconds: 100 }, 120);
  assert.equal(active.burstTime, 1); assert.equal(active.balBurstBucket, 1);
  near(active.burstBase, 1e16, 1e-12, 'active ETH base survives rebasing');
  near(active.balBurstBase, 10000, 1e-12, 'active balance base survives rebasing');
  ok(active.sellForEth(120) > 0, 'a second ETH fill succeeds');
  ok(active.xBuy(433, 120) > 0, 'a second balance fill succeeds');
  near(active.rateAtCheckpoint, 5e15, 1e-12, 'the ETH drop keeps its original half-price floor');
  near(active.balRate, 5000, 1e-12, 'the balance drop keeps its original half-price floor');
  n += 2;
  const expired = make();
  expired.setSettings({ bucketSeconds: 100 }, 200);
  assert.equal(expired.burstTime, 2); assert.equal(expired.balBurstBucket, 2);
  assert.equal(expired.burstBase, 0); assert.equal(expired.balBurstBase, 0); n += 4;
  const ethBefore = expired.priceRate(200), balanceBefore = expired.balPriceState(200);
  ok(expired.sellForEth(200) > 0, 'an ETH fill reopens the expired floor');
  ok(expired.xBuy(433, 200) > 0, 'a balance fill reopens the expired floor');
  near(expired.burstBase, ethBefore, 1e-12, 'the next ETH fill snapshots its current rate');
  near(expired.balBurstBase, balanceBefore, 1e-12, 'the next balance fill snapshots its current rate');
  near(expired.rateAtCheckpoint, ethBefore / 2, 1e-12, 'the expired ETH base cannot hold the old higher floor');
  near(expired.balRate, balanceBefore / 2, 1e-12, 'the expired balance base cannot hold the old higher floor');
}
// promise: a listing that consumes the whole pot succeeds with zero keeper payment even when its score raises the bid ceiling.
{
  const c = fresh({ rateStart: 1e16 }, 0.01);
  const result = c.buyListing(0.01, 0, 866);
  assert.deepEqual(result, { cost: 0.01, paid: 0 });
  assert.equal(c.ethPot, 0); assert.equal(c.spendBucket.spent, 10000000000000000n); n += 3;
}
// promise: requested integer steps apply from the first hour and preserve calibrated first-hour volume.
{
  const quiet = { days: 1 / 24, volScale: 0, offersPerHour: 0, strategyOn: false, stmtPerDay: 0, stmtFloorPerDay: 0, creditBuyersPerDay: 0 };
  for (const seconds of [1, 60, 75]) {
    const times = [];
    simulate({ ...quiet, stepSec: seconds, onStep: (t) => times.push(t) });
    assert.equal(times.length, 3600 / seconds);
    assert.equal(times[0], seconds); assert.equal(times.at(-1), 3600);
    assert.ok(times.every((t, index) => t === (index + 1) * seconds)); n += 4;
    let volume = 0;
    for (let t = 0; t < 3600; t += seconds) volume += stepVolume(DEFAULTS, t, seconds);
    near(volume, stepVolume(DEFAULTS, 0, 3600), 1e-12, 'first-hour volume is independent of execution granularity');
  }
  assert.throws(() => simulate({ ...quiet, stepSec: 1.5 }), /integer divisor/); n++;
  const latch = { ...DEFAULTS, sniperSeconds: 0 };
  near(skimFraction(latch, 900), skimFraction(DEFAULTS, 900), 1e-12, 'the payee latch does not change the hook skim');
  near(stepVolume(latch, 0, 120), stepVolume(DEFAULTS, 0, 120), 1e-12, 'the payee latch does not change calibrated fee volume');
}
// promise: bookEveryHours leaves the hook drip unbooked, so the bid climbs between books on the pending pot share
// (decision 147). a launch Core climbs the bid over the hour with no door and no book, and a book conserves the clamp.
// the default (bookEveryHours 0) still books every step, and a simulate with an hourly book keeps the ledger closed
{
  // with no drip and an empty booked pot the bid is pinned to the clamp of 0
  const empty = new Core(Object.assign({}, DEFAULTS), 0);
  ok(empty.ethRate(30 * 60) === 0, 'bookEveryHours: an empty booked pot with no drip reads a bid of 0');

  // the hook pushes fee income, left unbooked: the clamp counts its pot share, so the bid climbs between books
  const c = new Core(Object.assign({}, DEFAULTS), 0);
  c.accrue(1); // 1 eth of fee income, unbooked
  ok(c.ethPot === 0, 'bookEveryHours: nothing booked, the drip waits above the pots');
  const r0 = c.ethRate(0), r30 = c.ethRate(30 * 60), r60 = c.ethRate(60 * 60);
  ok(r30 > r0 && r60 > r30, 'the bid climbs within the hour before any book, on the unbooked drip');
  ok(c.ethPot === 0, 'still nothing booked while the bid climbed');
  // a book at the hour conserves the clamp (ethPot + pending pot share), so the read does not jump across it
  const before = c.ethRate(60 * 60);
  c.book(60 * 60);
  near(c.ethRate(60 * 60), before, 1e-12, 'the book conserves the clamp, the read does not jump across it');
  ok(c.ethPot > 0 && c.unbooked === 0, 'the book folded the drip into the pot');
  n += 5;

  // a whole simulate run at launch settings with an hourly book keeps every eth identity closed
  const hb = simulate({ days: 20, seed: 3, bookEveryHours: 1 });
  ok(Math.abs(hb.stats.potCheck) < 1e-6, 'hourly book: pot accounting ' + hb.stats.potCheck);
  ok(Math.abs(hb.stats.buybackCheck) < 1e-9 && Math.abs(hb.stats.redeemCheck) < 1e-9, 'hourly book: buyback and redeem accounting');
  ok(hb.S.pot.every((x) => x >= -1e-12), 'hourly book: the pot never goes negative');
  ok(hb.core.unbooked === 0, 'hourly book: the final flush left no unbooked drip');
  n += 4;
}
// the balance token constants mirror Jack's pinned contract, from the single source sim/upstream.js. test/UpstreamBalance.t.sol
// promise: and test_phase2DayWithProductionModule assert these against the real bytecode on a fork: a redeem of a statement of
// stored rating R pays R * 1e14 base units at 18 decimals. a known 100 point statement (RATE_SCORE = 1e6 score units) redeems
// 1e20 base units, matching the forge assertion balanceToken.quote(sid) == ratingOf(sid) * 1e14
{
  ok(UNIT_PER_POINT === 1e14, 'upstream unitPerPoint is 1e14');
  ok(DECIMALS === 18, 'upstream balance token is 18 decimals');
  const rating = 1_000_000; // 100 points in stored score units, the eth rate divisor RATE_SCORE
  ok(redeemQuote(rating) === rating * 1e14, 'redeemQuote is rating * unitPerPoint');
  ok(redeemQuote(rating) === 1e20, 'a 100 point statement redeems 1e20 base units (the forge number)');
  const c = new Core(Object.assign({}, DEFAULTS), 0);
  ok(c.redeemBaseUnits(rating) === rating * UNIT_PER_POINT, 'the balance model redemption reads UNIT_PER_POINT');
  ok(c.tokenOne() === 1e18, 'the balance model token unit reads DECIMALS');
  n += 6;
}
console.log(`ok, ${n} checks passed`);
