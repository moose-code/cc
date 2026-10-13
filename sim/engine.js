// credits engine economic simulator. plain es module, no dependencies, runs in node 22 and in a browser.
// core rules are ported from src/Core.sol on branch flow. units: eth for pots and prices, wei per credit for the rate,
// seconds for time, whole coins for coin amounts. exitModule and exitToken are the only names for phase 2.

export const W = 1e18;
export const BPS = 10000;

// the Core's Settings struct (src/interfaces/Interfaces.sol), same field names, launch values from script/config/mainnet.json.
// the stepped bid fields of the struct (dropPerCreditBps, dropFloorBps, climbPerMinBps, ceilBps, idleLoosenBps, recoveryClimbPerMinBps,
// recoveryGapBps, peakHalfLife) are the sim parameters of bidRule stepped below, in percent and hours.
// durations in seconds, buybackSlice in eth (the Core holds wei). every one can change mid run through `schedule`
export const SETTINGS = {
  saleFloorBps: 10000, // the hard floor: no sale of a statement below cost * saleFloorBps / 10000, whatever the controller asks. launch 100 percent of cost (FLOW 85)
  saleToBuybackBps: 5000, // share of sale proceeds to the coin buyback, rest to the pot
  buybackSlice: 0.5,
  buybackDelay: 25, // blocks, 12 s each
  keeperFee: 0.0005, // eth. the buyback caller is paid BUYBACK_GAS_USED * min(basefee, keeperMaxBaseFee) + keeperFee out of the slice (docs/DECISIONS.md 61), the buyListing caller BUYLISTING_GAS_USED * min(basefee, keeperMaxBaseFee) + keeperFee out of the pot (docs/DECISIONS.md 71)
  keeperMaxBaseFee: 10, // gwei, the cap on the base fee the refunds use
  rateCap: 26700000000000000, // wei per credit, 3 times rateStart: the eth rate never passes it (climb clamp, setRate)
  callerFee: 0, // eth. paid to the caller of compose, composeChosen and exitStatement from the pot, with the gas refund below. launch 0: the simulator does not model these payments
  callerMaxBaseFee: 0, // gwei, the cap on the base fee the refund of those three doors uses. 0 refunds no gas
  feeToBuybackBps: 0, // share of swap fee eth booked in receive() that goes to the buyback instead of the pot
  feeToRedeemBurnBps: 1000, // share of swap fee eth booked in receive() that fills the redeem burn reserve (FLOW 86)
  exitMode: 0, // phase 2 state: 0 off (no redemption, no exit token bid), 1 hold (redemptions, no bid), 2 on (redemptions and the bid, which also needs the controller's exit token pool key) (FLOW 86, 92)
  exitSlippageBps: 200, // a redemption must return at least rating * unit * (10000 - exitSlippageBps) / 10000 (FLOW 84)
  exitBidMarginBps: 2000, // the exit token bid pays score * unit * (10000 - exitBidMarginBps) / 10000 per credit (FLOW 84)
  redeemBurnBps: 2000, // share of the redeem burn reserve moved to the coin buyback on each redemption (FLOW 86)
  // the earlier built bid rule (bidRule 'built') and the dropToLast rule read these. they are not Core settings and are not in the config
  climbBaseBps: 100, // per hour
  climbDoubleEvery: 24 * 3600,
  climbMaxBps: 800, // per hour
  dropBps: 2000,
};
export const SETTING_KEYS = Object.keys(SETTINGS);
// the controller's own settings (src/ControllerV1.sol), owner settable at once. the asking price of a statement with price reference r (below), in bps of r, starts at
// start = min(anchorBps * markupBps / 10000, startCapBps) and falls per second in two stages: fastDecayBpsPerHour from start to kneeBps, then
// slowDecayBpsPerHour to floorBps, where it stays. a start at or below kneeBps falls at the slow rate from the first second (askBps).
// the anchor (ControllerV1.anchorBps, starts at 10000) is the running level of sale prices in bps of the reference. a sale above the anchor now sets it to the
// mean of the anchor now and the sale price, a sale at or below it leaves it, and so does a sale of a statement that costs less than anchorMinCost (eth here, wei in the
// contract). the part of the anchor above 10000 halves every anchorHalfLife, continuously.
// a buyer pays the asking price and gets the statement at once through Core.sellTo.
// the price reference of a statement is max(cost, floorRate * rating / refScore) (ControllerV1.referenceOf), where the floor rate is the larger of the climbed price state and the decayed peak and refScore is in CREDIT below
export const CONTROLLER = {
  markupBps: 15000,
  startCapBps: 100000,
  fastDecayBpsPerHour: 100,
  kneeBps: 10000,
  slowDecayBpsPerHour: 25,
  floorBps: 10000, // launch: the price falls to the reference and stays there (FLOW 85)
  anchorHalfLife: 7 * 86400,
  anchorMinCost: 0.1,
};
export const CONTROLLER_KEYS = Object.keys(CONTROLLER);
// the credit settings (script/config/mainnet.json credit block, the Credit struct). creditCostToPotBps, chosenComposeOn and minCcToChoose are Core settings
// (Core.setCreditCostToPotBps, setChosenComposeOn, setMinCcToChoose); creditSaleOn, creditWindow, creditFloorBps, creditStartBps and refScore are controller
// settings (FLOW 88 to 90, 93, 94). while creditSaleOn is true every pile credit is for sale from its acquisition time: creditPrice falls linearly from
// start = floor * creditStartBps / 10000 to floor over creditWindow and rests there, with floor = max(cost, baseline, backstop) * creditFloorBps / 10000. the
// baseline is score * min(stored, live unitPerPoint) at the exit token pool price and only lifts the floor, 0 while no module or pool key is set; the backstop is the floor rate (the larger of the climbed price state and the decayed peak)
// times max(1, score / refScore), so a credit scored above refScore floors proportionally higher. Core.sellCreditTo takes at least the credit's cost, books creditCostToPotBps of the cost to the pot and the rest to the buyback pot.
// compose waits for a credit's window while the sale is on (ControllerV1.pastWindow). refScore is the per-credit score of the statement price reference, in
// ten-thousandths of a point (the model's scores are in points). minCcToChoose is a coin balance the model does not track: every composer passes it
export const CREDIT = {
  creditCostToPotBps: 10000,
  chosenComposeOn: false,
  minCcToChoose: 0,
  creditSaleOn: false,
  creditWindow: 14400, // seconds (4 hours)
  creditFloorBps: 11000,
  creditStartBps: 30000,
  refScore: 4330000,
};
export const CREDIT_KEYS = Object.keys(CREDIT);
// the config names of the credit block (script/config/mainnet.json credit.*)
export const CREDIT_CONFIG_KEY = { creditCostToPotBps: 'costToPotBps', chosenComposeOn: 'chosenComposeOn', minCcToChoose: 'minCcToChoose', creditSaleOn: 'saleOn', creditWindow: 'window', creditFloorBps: 'floorBps', creditStartBps: 'startBps', refScore: 'refScore' };
// src/lib/CreditBounds.sol: the name of the first credit field out of bounds, or null
export function creditViolation(c) {
  if (!(c.creditCostToPotBps >= 0 && c.creditCostToPotBps <= 10000)) return 'creditCostToPotBps';
  if (!(c.creditWindow >= 60 && c.creditWindow <= 30 * 86400)) return 'creditWindow';
  if (!(c.creditFloorBps >= 10000 && c.creditFloorBps <= 40000)) return 'creditFloorBps';
  if (!(c.creditStartBps >= 10000 && c.creditStartBps <= 200000)) return 'creditStartBps';
  if (!(c.refScore >= 1 && c.refScore <= 8000000)) return 'refScore';
  return null;
}
// the asking price in bps of the reference after `age` seconds from a start price of `start` bps (ControllerV1._ask without its integer rounding):
// start less fastDecayBpsPerHour an hour while above kneeBps, then slowDecayBpsPerHour an hour, never below floorBps
export function askBps(c, start, age) {
  const hours = age / 3600, span = Math.max(0, start - c.kneeBps);
  const p = c.fastDecayBpsPerHour * hours <= span
    ? start - c.fastDecayBpsPerHour * hours
    : Math.min(start, c.kneeBps) - c.slowDecayBpsPerHour * (hours - span / c.fastDecayBpsPerHour);
  return Math.max(p, c.floorBps);
}
// ControllerV1 bounds: the name of the first controller field out of bounds, or null
export function controllerViolation(c) {
  if (c.markupBps < 10000 || c.markupBps > 40000) return 'markupBps';
  if (c.startCapBps < c.markupBps || c.startCapBps > 200000) return 'startCapBps';
  if (c.floorBps < 1000 || c.floorBps > 10000) return 'floorBps';
  if (c.kneeBps < c.floorBps || c.kneeBps > c.startCapBps) return 'kneeBps';
  if (c.fastDecayBpsPerHour < 1 || c.fastDecayBpsPerHour > 10000) return 'fastDecayBpsPerHour';
  if (c.slowDecayBpsPerHour < 1 || c.slowDecayBpsPerHour > 10000) return 'slowDecayBpsPerHour';
  if (c.anchorHalfLife < 86400 || c.anchorHalfLife > 90 * 86400) return 'anchorHalfLife';
  if (c.anchorMinCost < 0 || c.anchorMinCost > 10) return 'anchorMinCost';
  return null;
}

// src/lib/SettingsBounds.sol: the name of the first field out of bounds, or null. the built rule fields come first (sim only)
export function firstViolation(s) {
  if (s.climbBaseBps > 1000) return 'climbBaseBps';
  if (s.climbDoubleEvery < 3600 || s.climbDoubleEvery > 30 * 86400) return 'climbDoubleEvery';
  if (s.climbMaxBps < s.climbBaseBps || s.climbMaxBps > 2000) return 'climbMaxBps';
  if (s.dropBps < 500 || s.dropBps > 5000) return 'dropBps';
  if (s.saleFloorBps < 1000 || s.saleFloorBps > 40000) return 'saleFloorBps';
  if (s.saleToBuybackBps > 10000) return 'saleToBuybackBps';
  if (s.buybackSlice < 0.01 || s.buybackSlice > 1) return 'buybackSlice';
  if (s.buybackDelay < 1 || s.buybackDelay > 7200) return 'buybackDelay';
  if (s.keeperFee > 0.005) return 'keeperFee';
  if (s.keeperMaxBaseFee < 1 || s.keeperMaxBaseFee > 100) return 'keeperMaxBaseFee';
  if (s.buybackSlice < 2 * (CORE_PARAMS.BUYBACK_GAS * s.keeperMaxBaseFee * 1e-9 + s.keeperFee)) return 'buybackSlice'; // BUYBACK_GAS (Interfaces.sol)
  if (s.rateCap < RATE_MIN || s.rateCap > RATE_MAX) return 'rateCap';
  if (s.feeToBuybackBps > 10000) return 'feeToBuybackBps';
  if (s.feeToRedeemBurnBps > 10000) return 'feeToRedeemBurnBps';
  if (s.feeToBuybackBps + s.feeToRedeemBurnBps > 10000) return 'feeToRedeemBurnBps';
  if (s.callerFee > 0.005) return 'callerFee';
  if (s.callerMaxBaseFee > 100) return 'callerMaxBaseFee';
  if (s.exitMode !== 0 && s.exitMode !== 1 && s.exitMode !== 2) return 'exitMode';
  if (s.exitSlippageBps > 1000) return 'exitSlippageBps';
  if (s.exitBidMarginBps > 9000) return 'exitBidMarginBps';
  if (s.exitSlippageBps > s.exitBidMarginBps) return 'exitSlippageBps'; // the exit cycle (bid then redeem) cannot lose more than its margin
  if (s.redeemBurnBps > 10000) return 'redeemBurnBps';
  return null;
}
// the eth rate bounds of setRate, rateStart and rateCap, wei per credit (Interfaces.sol)
export const RATE_MIN = 1e13, RATE_MAX = 1e18;

// constants of the Core and of the pool that are not settings
export const CORE_PARAMS = {
  SUPPLY: 1e9,
  PAGE: 80,
  BUYBACK_GAS: 600000, // Core.sol: the gas that sizes the swap budget reserve of a buyback (reserve = BUYBACK_GAS * capped base fee + keeperFee)
  BUYBACK_GAS_USED: 270000, // counted gas of one buyback (measured 270,237 in docs/INTEGRATION.md): what the caller is paid at the capped base fee
  BUYLISTING_GAS: 1500000, // Interfaces.sol: the most gas of a buyListing the caller payment counts
  BUYLISTING_GAS_USED: 470000, // counted gas of one buyListing through the CreditStrategy (466,714 in test/CoreUnit.t.sol): gas used 418,000 plus the 250,000 overhead less the work after the count
};

// launch config (script/config/mainnet.json) and simulator inputs
export const SIM_DEFAULTS = {
  seed: 7,
  days: 90,
  stepSec: 60, // time step after the first hour, seconds. a divisor of 3600. 60 matches the minute bucket of the contract's drop floor and climb; hourly steps distort the stepped rule (bid up to 3x market). rates quoted per hour or per day, the hourly cap and arrival counts scale with the step
  rateStart: 8900000000000000, // launch opening rate (script/config/mainnet.json rateStart): 100 percent of the market price of one credit, 0.0089e18
  // bid rule. 'stepped' is the launch rule (src/lib/CoreLib.sol climb and drop) and the default. 'built' is the earlier rule, kept for the
  // comparison in docs/notes/BID-STUDY.md: climbs per hour (doubling per idle day), drops dropBps times the share of the pot spent.
  // 'dropToLast': after a fill the bid is dropToPct of the rate that fill paid, then climbs climbPerMin percent per minute, no ceiling.
  // 'stepped': a fill drops the bid dropPerCreditPct, not below dropToPct of the bid at the first fill of that timestamp; climbs climbPerMin
  // percent per minute, never above ceilPct of the rate of the last fill (of rateStart before any fill). the funded clamp and rateCap apply to all rules
  bidRule: 'stepped',
  dropToPct: 50,
  climbPerMin: 0.5,
  recoveryClimbPerMin: 2, // stepped: percent per minute while the price state is below the recovery level (recoveryGapPct under the remembered peak) (launch recoveryClimbPerMinBps 200); at or above the level the climb is climbPerMin
  recoveryGapPct: 10, // stepped: the recovery climb applies only below peak * (1 - recoveryGapPct / 100) (launch recoveryGapBps 1000); 0 makes every fill start the recovery climb
  peakHalfLifeHours: 6, // stepped: the remembered peak (the ceiling anchor, with the last fill rate) halves in this many hours (launch peakHalfLife 21600 seconds)
  dropPerCreditPct: 0.5,
  ceilPct: 110,
  // seller model toggle: one seller with an unlimited supply sells one credit per step whenever the bid has reached throttleFrac of the market price
  throttler: false,
  throttleFrac: 0.95,
  idleLoosenPct: 2, // stepped: percent added to the ceiling anchor every idleLoosenMin minutes while no fill happens (launch 2, linear), 0 = none
  idleLoosenMin: 10,
  ceilDecayHours: 0, // stepped: half life of the ceiling headroom since the last fill, 0 = none
  askFloor: 0, // lowest seller ask as a multiple of the market price (0: none, asks are lognormal around 1)
  onStep: null, // optional callback (t, core, marketPrice, rate) after each step, for traces
  gapPct: 30, // pricePath 'gap': size of the jump, percent
  gapHour: 6,
  forceFillHour: null, // one forced fill at forceFillFrac of the market price at this hour: the bid is set to that level first (test hook)
  forceFillFrac: 0.5,
  holdPot: 0, // test hook: eth. the pot is topped up to this level after every step (accounting checks do not hold)
  gateAt: 20, // counterfactual only: hours with at least this many unsold statements held are counted in gateClosedHours
  whipsawStartDay: 2, // pricePath 'whipsaw': day the fall starts
  schedule: [], // [{ day, patch }]: owner changes settings on that day. patch may hold any setting and `rate` (setRate, wei per credit), `moduleUnit` (the exit module reports a new eth value per point), `refreshUnitPerPoint: true`, `releaseRedeemBurn: eth`
  baselineSkimBps: 690, // bps of volume: 6.9 points (script/config/mainnet.json launch.baselineSkimBps)
  bountyBps: 9638, // of the baseline skim, to the fee router. the other 362 of 10000 is the protocol leg, not the engine's
  sniperStartBps: 9000,
  sniperEndBps: 690, // falls to the baseline
  sniperSeconds: 1800,
  // the fee router (docs/DECISIONS.md 10.6, 10.7): once the split has started a flush pays the
  // payee its parts per million of the gross inflow. everything before the split start goes to the engine. no lp fee, no lp income
  routerPayeePpm: 112778, // the one launch payee, 0.75 points of volume at the baseline (of the gross router inflow)
  routerSplitStartSec: 1800, // the mined launch time plus the 30 minute window, no margin
  startTick: -175000,
  positionUpper: 887200,
  // coin market
  volPreset: 'comparable', // comparable | sustained17 | sustained50 | deadWeek1 | custom
  volScale: 1,
  volDay0: 1557,
  volTail: 17, // custom: eth a day after day one
  volHalfLifeDays: 3, // custom: decay of day one volume to the tail
  h1Share: 0.586, // share of day one volume in the first hour
  sniperVolShare: 0.4, // share of first hour volume inside the 30 minute anti sniper window
  buyShare0: 0.526,
  buyShareLate: null, // null: 0.46 for the comparable and week one presets, 0.5 for sustained presets, 0.49 custom
  // credit market
  pricePath: 'flat', // flat | decline | recovery | falling | rising | whipsaw
  priceP0: 0.0089,
  priceTauDays: 20,
  priceEndMult: null, // decline floor and recovery target as a multiple of p0, default 0.4 and 2.2
  askSigma: 0.27,
  impactElast: 0.12,
  impactHalfLifeHours: 48,
  marketDailyEth: 33,
  impactCap: 3,
  offersPerHour: 150,
  bookChurn: 0.05, // share of resting offers that leave each hour
  supplyElast: 1.5,
  holders: 96800,
  listedShare: 0, // share of market offers that are visible listings the keeper takes at the ask through the listing door
  strategyOn: true,
  // statement buyers
  stmtPerDay: 8,
  stmtDecayDays: 21,
  stmtFloorPerDay: 2,
  wtpMult: 1,
  stmtPick: 'cheapest', // a buyer takes the statement with the lowest asking price that fits its willingness to pay; 'random' picks any one that fits
  buyerWaits: 'no', // 'no': a buyer takes what it can afford now. 'floor': every buyer waits until the asking price has reached its lowest level (pessimistic case)
  // phase 2 (exitModule and exitToken). the exit token side is rebuilt per FLOW 84 to 87 and 92: exitMode (a Core setting), redemption when the curve price
  // reaches its floor, a rating per statement, a per point exit token bid that needs the pool key, one pile for every credit. exit token amounts are held as eth value
  phase2Day: null, // day the exit module is set. the same step sets exitMode to phase2ExitMode (the owner switches the state on)
  phase2ExitMode: 2, // exitMode set at phase2Day: 1 hold or 2 on
  xpPerPoint: 0.0108 / 440, // eth value of the exit token a redemption returns per score point (unitPerPoint at the exit token price). a 440 point credit redeems 0.0108 eth. the unit the Core stores when the module is set
  exitPayFrac: 1, // share of rating * xpPerPoint the exit module returns. the Core requires at least 1 - exitSlippageBps / 10000, else the exit reverts
  exitPoolSet: false, // ControllerV1.setExitPoolKey done (native eth as currency0, the exit token as currency1, pool initialized): a statement's asking price is at least rating * xpPerPoint (its redemption value) and the credit sale baseline can lift a credit's floor, unset at launch. the exit token bid works without it (FLOW 96)
  exitPoolMult: 1, // the exit token pool price against the price the stored unit assumes. values the redemption floor and the credit baseline (both only lift). 1 at the unit; below 1 is a pool price pushed down (FLOW 93)
  // credit sale and composition (FLOW 88 to 90). the buyers of pile credits and the composer exist only in the model
  creditBuyersPerDay: 40, // arrivals a day of buyers of pile credits while creditSaleOn is true
  creditWtpMult: 1, // a credit buyer pays up to this multiple of the market price of a credit times a lognormal draw (askSigma)
  composeChoice: 'oldest', // 'oldest': compose() takes the 80 oldest credits. 'richest': with chosenComposeOn a composer names the 80 highest scoring credits past their window (composeChosen), else compose() applies
  exitMinRatio: 0, // a keeper redeems only when rating * xpPerPoint is at least this times the asking price
  keeperBuyback: true,
  basefeeGwei: 1, // the block base fee of the buyback calls, gwei (the refunds use min(basefee, keeperMaxBaseFee))
};

export const DEFAULTS = Object.assign({}, CORE_PARAMS, SETTINGS, CONTROLLER, CREDIT, SIM_DEFAULTS);


// quantiles of statement willingness to pay as a multiple of the parts' market cost (data: p10 .48, p25 .71, p50 .84, p75 1.07, 21 percent at 1.2 or more, max 1.32)
export const WTP_Q = [[0, 0.25], [0.1, 0.48], [0.25, 0.71], [0.5, 0.84], [0.75, 1.07], [0.79, 1.2], [0.9, 1.23], [1, 1.32]];
// credit score deciles of the CreditStrategy inventory and its listing price counts (eth, count)
export const STRAT_SCORE_Q = [[0, 80], [0.1, 130], [0.2, 181], [0.3, 238], [0.4, 296], [0.5, 355], [0.6, 416], [0.7, 480], [0.8, 556], [0.9, 640], [1, 785]];
export const STRAT_LISTINGS = [[0.036, 8726], [0.03, 2790], [0.042, 699], [0.048, 599], [0.018, 135], [0.06, 89], [0.012, 48], [0.024, 30], [0.072, 14], [0.054, 2]];
// comparable coin daily volume fit: 122.6 * exp(-0.286 d) for d >= 1, floor 0.5 eth a day
export const COMPARABLE = { a: 122.6, k: 0.286, floor: 0.5 };

export function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
export function normal(rng) {
  let u = rng();
  if (u < 1e-12) u = 1e-12;
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * rng());
}
export function poisson(rng, lam) {
  if (lam <= 0) return 0;
  if (lam > 60) return Math.max(0, Math.round(lam + Math.sqrt(lam) * normal(rng)));
  const L = Math.exp(-lam);
  let k = 0, p = 1;
  do { k++; p *= rng(); } while (p > L);
  return k - 1;
}
export function interp(table, u) {
  for (let i = 1; i < table.length; i++) {
    if (u <= table[i][0]) {
      const [x0, y0] = table[i - 1], [x1, y1] = table[i];
      return y0 + ((y1 - y0) * (u - x0)) / (x1 - x0);
    }
  }
  return table[table.length - 1][1];
}

// ---------------------------------------------------------------- core port
// the Core's state and rules. pots are in eth, the rate in wei per whole point, time in seconds.
// `this.s` is the Settings struct and is read live by every rule, so `setSettings` takes effect at once.
export class Core {
  constructor(p, t0 = 0) {
    this.p = p;
    this.s = {};
    for (const k of SETTING_KEYS) this.s[k] = p[k];
    this.c = {}; // the controller's settings
    for (const k of CONTROLLER_KEYS) this.c[k] = p[k];
    this.cr = {}; // the credit settings (Core and controller)
    for (const k of CREDIT_KEYS) this.cr[k] = p[k];
    this.creditCostToPot = 0; // cumulative cost share of credit sales booked to the pot
    this.creditToBuyback = 0; // cumulative credit sale eth booked to the buyback pot
    this.anchorStored = 10000; // the controller's storedAnchorBps: the anchor at anchorTime, bps of the reference
    this.anchorTime = t0;
    this.pauses = []; // the controller's pause windows {start, end} in seconds, end null while open
    this.feeToBuyback = 0; // cumulative swap fee eth sent to the buyback pot by feeToBuybackBps
    this.feeToRedeemBurn = 0; // cumulative swap fee eth sent to the redeem burn reserve by feeToRedeemBurnBps
    this.redeemBurnMoved = 0; // cumulative eth moved from the reserve to the buyback pot by redemptions
    this.ethPot = 0; this.ethToBuyback = 0; this.ethRedeemBurn = 0; this.xPot = 0; // xPot holds the eth value of the exit token
    this.rateAtCheckpoint = p.rateStart; this.checkpointTime = t0; this.lastFillTime = t0; this.funded = false;
    this.xpPerPoint = 0; this.xpLive = 0; this.moduleSet = false; // the exit module is set by setExitModule
    this.lastBuybackTime = -1e12;
    this.clampTime = 0;
    this.lastPaidRate = p.rateStart; this.burstTime = -1; this.burstBase = 0; // bidRule stepped
    this.peakRate = p.rateStart; this.peakTime = t0; // bidRule stepped: the remembered peak
  }
  // the remembered peak now: peakRate halved over the time since peakTime (stepped rule)
  peakAt(now) {
    return this.peakRate * Math.pow(0.5, (now - this.peakTime) / (this.p.peakHalfLifeHours * 3600));
  }
  // the climb stops where the pot no longer affords one credit at the rate, or at rateCap, whichever is lower
  clamp() {
    return Math.min(this.ethPot * W, this.s.rateCap);
  }
  // stepped rule: the ceiling in rate terms, ceilPct of the anchor, the anchor loosened while idle. the anchor is
  // max(last rate paid, peak now)
  stepCeil(now) {
    const p = this.p;
    // ceilDecayHours > 0: the headroom above the anchor halves every ceilDecayHours since the last fill
    const decay = p.ceilDecayHours > 0 ? Math.pow(0.5, (now - this.lastFillTime) / (p.ceilDecayHours * 3600)) : 1;
    // idleLoosenPct: the anchor grows linearly, by that percent of the anchor for every full idleLoosenMin minutes since the last fill (CoreLib.climb)
    const loosen = p.idleLoosenPct > 0 ? 1 + (p.idleLoosenPct / 100) * Math.floor((now - this.lastFillTime) / (p.idleLoosenMin * 60)) : 1;
    const anchor = Math.max(this.lastPaidRate, this.peakAt(now));
    return anchor * loosen * (1 + (p.ceilPct / 100 - 1) * decay);
  }
  // stepped rule, price state: the stored rate climbed per minute toward min(ceiling, rateCap, clamp). Below the
  // recovery level (recoveryGapPct under the remembered peak) the climb is recoveryClimbPerMin, at or above it
  // climbPerMin; the crossing is solved so the trajectory is continuous and monotone in time (CoreLib._recover). A
  // stored rate above the ceiling or rateCap reads as that bound; a stored rate above the clamp holds its value
  priceRate(now) {
    const r = this.rateAtCheckpoint, cap = Math.min(this.s.rateCap, this.stepCeil(now));
    if (r >= cap) return cap;
    const target = Math.min(cap, this.clamp());
    if (r >= target || now <= this.checkpointTime) return r;
    const fast = this.p.recoveryClimbPerMin / 100, slow = this.p.climbPerMin / 100;
    const lnFast = Math.log(1 + fast), lnSlow = Math.log(1 + slow);
    const elapsed = now - this.checkpointTime;
    const peakT = this.peakRate * Math.pow(0.5, (this.checkpointTime - this.peakTime) / (this.p.peakHalfLifeHours * 3600));
    const levelT = peakT * (1 - this.p.recoveryGapPct / 100);
    const climb = (base, lnRate, sec) => Math.min(base * Math.exp(lnRate * sec / 60), target);
    if (levelT <= r) return climb(r, lnSlow, elapsed);
    const denom = lnFast / 60 + Math.LN2 / (this.p.peakHalfLifeHours * 3600);
    const crossSec = Math.log(levelT / r) / denom;
    if (elapsed <= crossSec) return climb(r, lnFast, elapsed);
    const priceCross = climb(r, lnFast, crossSec);
    if (priceCross >= target) return target;
    return climb(priceCross, lnSlow, elapsed - crossSec);
  }
  // the bid read by a seller. stepped: the price state bid, lowered to the clamp (the pot). the clamp bounds
  // what is paid and is never stored: checkpoint, the drop and the anchor all use the price state rate
  ethRate(now) {
    const s = this.s;
    if (this.p.bidRule === 'stepped') return Math.min(this.priceRate(now), this.clamp()); // funded or not; an empty pot reads 0
    let r = this.rateAtCheckpoint;
    if (!this.funded) return r;
    let cap = this.clamp();
    const rule = this.p.bidRule;
    if (rule !== 'built') {
      if (rule === 'stepped') cap = Math.min(cap, this.stepCeil(now));
      if (cap <= r) return r;
      return Math.min(r * Math.pow(1 + this.p.climbPerMin / 100, (now - this.checkpointTime) / 60), cap);
    }
    if (cap <= r || s.climbBaseBps === 0) return r;
    const last = this.lastFillTime;
    let t = this.checkpointTime;
    while (t < now && r < cap) {
      const k = t > last ? Math.floor((t - last) / s.climbDoubleEvery) : 0;
      const bps = Math.min(s.climbBaseBps * Math.pow(2, Math.min(k, 16)), s.climbMaxBps);
      const end = k >= 11 ? now : Math.min(now, last + (k + 1) * s.climbDoubleEvery);
      r *= Math.pow(1 + bps / BPS, (end - t) / 3600);
      t = end;
    }
    return Math.min(r, cap);
  }
  // Core.ethPrice(): the price state before the pot clamp (wei per credit). the clamp is the read only lowering that ethRate applies. the cost floor of a credit
  // bought with the exit token and the eth bid term of the credit sale floor read it, so an empty pot does not zero them (FLOW 93)
  ethPrice(now) { return this.p.bidRule === 'stepped' ? this.priceRate(now) : this.ethRate(now); }
  // Core.floorRate(): the floor rate now (wei per credit): the larger of ethPrice, the price state climbed before the
  // pot clamp, and the remembered peak of the eth bid decayed to now. selling credits lowers only the rate and the peak
  // decays between fills, so the maximum follows the climb and holds against a sale within the block. the statement
  // reference, the credit backstop and the cost of a credit bought with the exit token read it
  floorRate(now) { return this.p.bidRule === 'stepped' ? Math.max(this.priceRate(now), this.peakAt(now)) : this.ethRate(now); }
  checkpoint(now) { this.rateAtCheckpoint = this.p.bidRule === 'stepped' ? this.priceRate(now) : this.ethRate(now); this.checkpointTime = now; }
  syncFunded() {
    this.funded = this.ethPot * W >= this.rateAtCheckpoint;
  }
  // owner: setSettings. validates, checkpoints both rates first, then applies at once. patch.rate is setRate.
  // the patch may also hold `paused` (ControllerV1.setPaused: true opens a pause window, false closes it), controller settings (markupBps, startCapBps, fastDecayBpsPerHour, kneeBps, slowDecayBpsPerHour, floorBps, anchorHalfLife, anchorMinCost), the credit settings (CREDIT) and anchorBps (setAnchorBps): the controller reads them live.
  // a new anchorHalfLife stores the anchor now first, and a start cap below the anchor now lowers the anchor to the cap
  setSettings(patch, now) {
    const rate = patch.rate;
    if (patch.paused !== undefined && typeof patch.paused !== 'boolean') throw new Error('BadSetting paused');
    const next = Object.assign({}, this.s), nextC = Object.assign({}, this.c), nextCr = Object.assign({}, this.cr);
    for (const k of SETTING_KEYS) if (patch[k] !== undefined) next[k] = patch[k];
    for (const k of CONTROLLER_KEYS) if (patch[k] !== undefined) nextC[k] = patch[k];
    for (const k of CREDIT_KEYS) if (patch[k] !== undefined) nextCr[k] = typeof CREDIT[k] === 'boolean' ? !!patch[k] : patch[k];
    const bad = firstViolation(next) || controllerViolation(nextC) || creditViolation(nextCr) || (patch.anchorBps !== undefined && !(patch.anchorBps >= 10000 && patch.anchorBps <= nextC.startCapBps) ? 'anchorBps' : null);
    if (bad) throw new Error('BadSetting ' + bad);
    if (rate !== undefined && !(rate >= RATE_MIN && rate <= RATE_MAX && rate <= next.rateCap)) throw new Error('BadRate');
    this.checkpoint(now);
    const anchorNow = this.anchorAt(now);
    this.s = next; this.c = nextC; this.cr = nextCr;
    if (patch.anchorHalfLife !== undefined) this.setAnchor(anchorNow, now);
    if (this.c.startCapBps < anchorNow) this.setAnchor(this.c.startCapBps, now);
    if (patch.anchorBps !== undefined) this.setAnchor(patch.anchorBps, now);
    if (patch.paused !== undefined) this.setPaused(patch.paused, now);
    this.rateAtCheckpoint = Math.min(this.rateAtCheckpoint, next.rateCap); // a lower cap pulls the rate down now
    if (rate !== undefined) {
      this.rateAtCheckpoint = rate; this.checkpointTime = now;
      // setRate restates the last fill rate and the remembered peak (CoreLib / Core.setRate)
      if (this.p.bidRule === 'stepped') { this.lastPaidRate = rate; this.peakRate = rate; this.peakTime = now; }
    }
    this.syncFunded();
  }
  // _spend: checkpoint, drop on fill. false means the Core would revert
  spend(x, now) {
    this.checkpoint(now);
    const pot = this.ethPot;
    if (!(x > 0) || x > pot + 1e-18) return false;
    const paid = this.rateAtCheckpoint, rule = this.p.bidRule;
    let r = paid;
    if (rule === 'dropToLast') r = (paid * this.p.dropToPct) / 100;
    else if (rule === 'stepped') {
      // CoreLib.drop: the minute floor is dropFloorBps of the price at the first fill of the minute bucket (now / 60), and restarts at the price when the price is already under the floor (setRate, lowered caps)
      const bucket = Math.floor(now / 60);
      if (bucket !== this.burstTime || paid < (this.burstBase * this.p.dropToPct) / 100) { this.burstTime = bucket; this.burstBase = paid; }
      r = Math.max(paid * (1 - this.p.dropPerCreditPct / 100), (this.burstBase * this.p.dropToPct) / 100);
    } else r -= (r * this.s.dropBps * Math.min(x, pot)) / (BPS * pot);
    if (rule !== 'built') this.lastPaidRate = paid;
    if (rule === 'stepped') { this.peakRate = Math.max(paid, this.peakAt(now)); this.peakTime = now; }
    this.rateAtCheckpoint = r;
    this.lastFillTime = now;
    this.ethPot = pot - x;
    this.syncFunded();
    return true;
  }
  // receive(): swap fee eth from the fee router. feeToBuybackBps of it goes to the buyback pot, feeToRedeemBurnBps to the redeem burn reserve, the rest to the pot (checkpoint first, resync after)
  addFees(amount, now) {
    const toBuyback = (amount * this.s.feeToBuybackBps) / BPS, toRedeemBurn = (amount * this.s.feeToRedeemBurnBps) / BPS;
    this.feeToBuyback += toBuyback; this.ethToBuyback += toBuyback;
    this.feeToRedeemBurn += toRedeemBurn; this.ethRedeemBurn += toRedeemBurn;
    this.checkpoint(now);
    this.ethPot += amount - toBuyback - toRedeemBurn;
    this.syncFunded();
    return { toBuyback, toRedeemBurn, toPot: amount - toBuyback - toRedeemBurn };
  }
  // door one: sell into the bid at the rate. every credit is paid the same. returns the price paid or 0
  sellForEth(now) {
    const price = this.ethRate(now) / W;
    return this.spend(price, now) ? price : 0;
  }
  // the largest payment of a buyListing at the base fee now: counted gas (at most BUYLISTING_GAS) at min(basefee, keeperMaxBaseFee) plus keeperFee
  listingPayMax() {
    const s = this.s, p = this.p;
    return Math.min(p.BUYLISTING_GAS_USED, p.BUYLISTING_GAS) * Math.min(p.basefeeGwei, s.keeperMaxBaseFee) * 1e-9 + s.keeperFee;
  }
  // door two: buy a listing at its ask. the caller is paid the largest payment, at most the bid less the ask, and the payment is booked as spend with the cost.
  // returns {cost, paid} or null
  buyListing(ask, now) {
    this.checkpoint(now);
    const ceil = this.ethRate(now) / W;
    if (ask > this.ethPot || ask > ceil) return null;
    const paid = Math.min(this.listingPayMax(), ceil - ask);
    if (!this.spend(ask + paid, now)) return null;
    return { cost: ask, paid };
  }
  // compose 80 credits (compose() and composeChosen() share this path). repays nothing: cost is the sum of their costs. returns the statement, held by the
  // Core from t0 = composedAt (asked at age zero, so at the start price). rating is the sum of the credits' scores, stored at compose (FLOW 84)
  compose(costSum, now, rating = 0) {
    return { cost: costSum, t0: now, rating };
  }
  // ControllerV1.referenceOf: the price reference of a statement, max(cost, floorRate * rating / refScore), where the
  // floor rate is the larger of the climbed price state and the decayed peak. ratings and scores are in points here,
  // refScore in ten-thousandths of a point, so refScore/1e4 is the reference score in points and floorRate/W is the
  // per-credit rate in eth. a record without a rating references its cost
  reference(st, now) {
    const refPts = this.cr.refScore / 1e4, rating = st.rating || 0;
    const rateTerm = (this.floorRate(now) / W) * (rating / refPts);
    return Math.max(st.cost, rateTerm);
  }
  // ControllerV1._setAnchorStored: the anchor at `now`
  setAnchor(bps, now) { this.anchorStored = bps; this.anchorTime = now; }
  // ControllerV1.anchorBps(): 10000 plus the part of the stored anchor above 10000, halved every anchorHalfLife since anchorTime, rounded down like the contract
  anchorAt(now) {
    const excess = this.anchorStored - 10000, t = Math.max(0, now - this.anchorTime);
    return 10000 + Math.floor(excess * Math.pow(0.5, t / this.c.anchorHalfLife) + 1e-9);
  }
  // ControllerV1.startBps(): min(anchorBps * markupBps / 10000, startCapBps), rounded down like the contract
  startBps(now) {
    const c = this.c;
    return Math.min(Math.floor((this.anchorAt(now) * c.markupBps) / BPS), c.startCapBps);
  }
  // ControllerV1.setPaused: a pause opens a window at `now`, a resume closes it. a call that repeats the state opens no window
  setPaused(v, now) {
    const open = this.pauses.length > 0 && this.pauses[this.pauses.length - 1].end === null;
    if (v === open) return;
    if (v) this.pauses.push({ start: now, end: null });
    else this.pauses[this.pauses.length - 1].end = now;
  }
  isPausedAt(now) { return this.pauses.some((w) => now >= w.start && (w.end === null || now < w.end)); }
  // the seconds of [from, to] inside the pause windows (an open window counts to `to`)
  pausedBetween(from, to) {
    let total = 0;
    for (const w of this.pauses) {
      const s = Math.max(w.start, from), e = Math.min(w.end === null ? to : w.end, to);
      if (e > s) total += e - s;
    }
    return total;
  }
  // ControllerV1._ask(ref, age): askBps at the age of the statement from the current anchor and settings, in wei of `ref`, the statement's price reference.
  // the age is the time since the compose outside the pause windows. the price is relative to the reference, the larger of the cost and the rating priced at the eth
  // bid rate, not to the market price of the statement's parts
  statementPrice(ref, listedAt, now) {
    return (ref * askBps(this.c, this.startBps(now), Math.max(0, now - listedAt - this.pausedBetween(listedAt, now)))) / BPS;
  }
  // the Core's hard floor: no sale below cost * saleFloorBps / 10000
  floorPrice(st) { return (st.cost * this.s.saleFloorBps) / BPS; }
  // ControllerV1._quote: the curve price, never below the hard floor. the anchor reads this price
  curvePrice(st, now) { return Math.max(this.statementPrice(this.reference(st, now), st.t0, now), this.floorPrice(st)); }
  // the unit the exit token bid, the redemption value and the credit baseline use: the lower of the stored and the live unitPerPoint
  unit() { return Math.min(this.xpPerPoint, this.xpLive); }
  // ControllerV1._value: the redemption value of the statement in eth, rating * min(stored, live unitPerPoint) at the exit token pool price. 0 while the pool key is unset or no module is set
  valueFloor(st) { return this.p.exitPoolSet && this.moduleSet ? (st.rating || 0) * this.unit() * this.p.exitPoolMult : 0; }
  // ControllerV1.priceOf: the curve price, never below the redemption value once the pool key is set
  askingPrice(st, now) { return Math.max(this.curvePrice(st, now), this.valueFloor(st)); }
  // the lowest asking price the statement will ever have under the current settings (the curve floor, floorBps of the reference, or the hard floor, saleFloorBps of cost, the higher, or the redemption value)
  lowestPrice(st, now) { return Math.max((this.reference(st, now) * this.c.floorBps) / BPS, this.floorPrice(st), this.valueFloor(st)); }
  // sale proceeds into the pots: saleToBuybackBps to the buyback, the rest to the pot (checkpoint first, resync after)
  bookSale(amount, now) {
    const toBuyback = (amount * this.s.saleToBuybackBps) / BPS;
    this.ethToBuyback += toBuyback;
    this.checkpoint(now);
    this.ethPot += amount - toBuyback;
    this.syncFunded();
    return { toBuyback, toPot: amount - toBuyback };
  }
  // Core.sellTo (called by the controller): a held statement is paid for at once. the payment is at least the hard
  // floor and is booked right away. returns the booking or null when the Core would revert
  sellTo(st, value, now) {
    if (st.sold || st.exited) return null;
    if (value < this.floorPrice(st) * (1 - 1e-12)) return null;
    st.sold = true; st.soldAt = now;
    return this.bookSale(value, now);
  }
  // ControllerV1.buy: pays the asking price now through sellTo. the curve price (not the redemption value floor) in bps of the reference, rounded up, above the anchor now
  // moves the anchor to the mean of the two, not above startCapBps. a sale at or below the anchor leaves it, and so does a statement that costs less than anchorMinCost
  // (or has a zero reference).
  // returns the booking, or null when the Core would revert
  buy(st, now) {
    if (this.isPausedAt(now)) return null;
    const curve = this.curvePrice(st, now), price = Math.max(curve, this.valueFloor(st));
    const res = this.sellTo(st, price, now);
    if (!res) return null;
    const ref = this.reference(st, now), saleBps = ref > 0 ? Math.ceil((curve * BPS) / ref - 1e-9) : 0;
    const anchor = this.anchorAt(now);
    if (ref > 0 && st.cost >= this.c.anchorMinCost && saleBps > anchor) this.setAnchor(Math.min(Math.floor((anchor + saleBps) / 2), this.c.startCapBps), now);
    return Object.assign({ price, saleBps }, res);
  }

  // ---- the credit sale window (FLOW 88, 92, 93). a pile credit is {pts, cost, t0}: its score in points, its cost basis in eth and its acquisition time
  // ControllerV1.pastWindow: a credit acquired at `acquiredAt` may compose now. always while the sale is off, else once creditWindow has passed
  pastWindow(acquiredAt, now) { return !this.cr.creditSaleOn || acquiredAt + this.cr.creditWindow <= now; }
  // ControllerV1._baseline: the exit token value of the credit, score * min(stored, live unitPerPoint) at the exit token pool price. 0 until the pool key and the module are set
  creditBaseline(cr) { return this.p.exitPoolSet && this.moduleSet ? cr.pts * this.unit() * this.p.exitPoolMult : 0; }
  // the score-scaled eth backstop of a credit: the floor rate times max(1, score / refScore), where the floor rate is
  // the larger of the climbed price state and the decayed peak. refScore is in ten-thousandths of a point, so
  // refScore/1e4 is the reference score in points; a credit scored at or below it backstops at the unscaled floor rate
  creditBackstop(pts, now) { return (this.floorRate(now) / W) * Math.max(1, pts / (this.cr.refScore / 1e4)); }
  // the credit sale floor: the highest of the credit's cost, its baseline and its score-scaled eth backstop, times creditFloorBps
  creditFloor(cr, now) { return (Math.max(cr.cost, this.creditBaseline(cr), this.creditBackstop(cr.pts, now)) * this.cr.creditFloorBps) / BPS; }
  // ControllerV1.creditPrice: falls linearly from floor * creditStartBps to the floor over creditWindow from the acquisition time and rests at the floor
  creditPrice(cr, now) {
    const floor = this.creditFloor(cr, now), start = (floor * this.cr.creditStartBps) / BPS, age = Math.max(0, now - cr.t0);
    return age >= this.cr.creditWindow ? floor : start - ((start - floor) * age) / this.cr.creditWindow;
  }
  // Core.sellCreditTo: the payment is at least the credit's cost. creditCostToPotBps of the cost goes to the pot, the rest of the payment to the buyback pot.
  // returns the booking or null when the Core would revert
  sellCreditTo(cr, value, now) {
    if (cr.sold || value < cr.cost * (1 - 1e-12)) return null;
    cr.sold = true;
    const toPot = (cr.cost * this.cr.creditCostToPotBps) / BPS, toBuyback = value - toPot;
    this.ethToBuyback += toBuyback; this.creditToBuyback += toBuyback; this.creditCostToPot += toPot;
    this.checkpoint(now);
    this.ethPot += toPot;
    this.syncFunded();
    return { toPot, toBuyback };
  }
  // ControllerV1.buyCredit: pays creditPrice now through sellCreditTo. null while the sale is off or sales are paused, or when the Core would revert
  buyCredit(cr, now) {
    if (!this.cr.creditSaleOn || this.isPausedAt(now)) return null;
    const price = this.creditPrice(cr, now), res = this.sellCreditTo(cr, price, now);
    return res ? Object.assign({ price }, res) : null;
  }

  // ---- phase 2. the exit module returns exit token worth rating * xpPerPoint (eth value) for a statement. pots here hold the eth value of the exit token
  // xpPerPoint is the unit the Core stores, xpLive the unit the module reports now (the module's unitPerPoint())
  setExitModule(now, xpPerPoint) {
    this.moduleSet = true; this.xpPerPoint = xpPerPoint; this.xpLive = xpPerPoint;
  }
  // the module reports a new unit; the Core stored unit is unchanged until refreshUnitPerPoint
  moduleReports(xpLive) { this.xpLive = xpLive; }
  // Core.refreshUnitPerPoint (owner): stores the module's live unit. reverts BadModule (null) without a module or at a zero unit. allowed after lockExitModule
  refreshUnitPerPoint() {
    if (!this.moduleSet || !(this.xpLive > 0)) return null;
    this.xpPerPoint = this.xpLive;
    return this.xpPerPoint;
  }
  // Core.releaseRedeemBurn (owner): moves min(amount, reserve) from the redeem burn reserve to the buyback pot. returns the amount moved, null when 0 (ZeroAmount)
  releaseRedeemBurn(amount) {
    const move = Math.min(amount, this.ethRedeemBurn);
    if (!(move > 0)) return null;
    this.ethRedeemBurn -= move; this.ethToBuyback += move; this.redeemBurnMoved += move;
    return move;
  }
  // Core.sellForExitToken runs while exitMode is 2 and a module is set. it records the score-scaled floor rate backstop
  // and reads no pool, so it needs no pool key
  exitBidActive() { return this.moduleSet && this.s.exitMode === 2; }
  // the exit token bid for a credit of `pts` points: score * unit * (10000 - exitBidMarginBps) / 10000, in eth value, where unit is the lower of the stored
  // and the live unitPerPoint. the same price for any credit of that score
  xBidPrice(pts) { return (pts * this.unit() * (BPS - this.s.exitBidMarginBps)) / BPS; }
  // sellForExitToken for one credit: pays xBidPrice from xPot. returns the price, or 0 when the Core would revert (mode not 2, price 0, price above the pot)
  xBuy(pts) {
    const price = this.exitBidActive() ? this.xBidPrice(pts) : 0;
    if (!(price > 0) || price > this.xPot + 1e-18) return 0;
    this.xPot -= price;
    return price;
  }
  // sellForExitToken for one credit at `now`: the credit enters the pile at an eth cost of the score-scaled floor rate
  // backstop, at least 1 wei, read from no pool. returns {paid, cost}, or null when the bid would revert
  xBuyCredit(pts, now) {
    const paid = this.xBuy(pts);
    if (!(paid > 0)) return null;
    return { paid, cost: Math.max(this.creditBackstop(pts, now), 1e-18) };
  }
  // ControllerV1.atFloor: the curve price (without the hard floor and the redemption value floor) has reached its floor, floorBps of the reference
  atFloor(st, now) {
    const ref = this.reference(st, now);
    return this.statementPrice(ref, st.t0, now) <= ((ref * this.c.floorBps) / BPS) * (1 + 1e-9);
  }
  // Core.exitStatement preconditions: a module is set, exitMode is 1 or 2, and the statement's curve price has reached its floor
  exitReady(st, now) {
    return this.moduleSet && this.s.exitMode >= 1 && !st.sold && !st.exited && this.atFloor(st, now);
  }
  // Core.exitStatement: the module returns rating * xpLive * exitPayFrac; the Core requires at least rating * xpPerPoint (stored) * (10000 - exitSlippageBps) / 10000 and keeps all of it in xPot.
  // a redemption moves redeemBurnBps of the redeem burn reserve to the buyback pot. returns {received, toBurn}, or null when the Core would revert
  exitStatement(st, now) {
    const s = this.s, value = st.rating * this.xpPerPoint;
    if (!this.exitReady(st, now)) return null;
    const received = st.rating * this.xpLive * this.p.exitPayFrac;
    if (received < (value * (BPS - s.exitSlippageBps)) / BPS * (1 - 1e-12)) return null; // Underpaid
    st.exited = true;
    this.xPot += received;
    const toBurn = (this.ethRedeemBurn * s.redeemBurnBps) / BPS;
    this.ethRedeemBurn -= toBurn; this.ethToBuyback += toBurn; this.redeemBurnMoved += toBurn;
    return { received, toBurn };
  }
  // buyback(): one slice at most per buybackDelay blocks. rate = min(basefee, keeperMaxBaseFee). the swap budget is the slice less the largest payment
  // (BUYBACK_GAS * rate + keeperFee), and a slice under twice that payment reverts (no call). the caller is paid BUYBACK_GAS_USED * rate plus keeperFee
  // times the swap budget over the largest budget the buybackSlice setting allows (the model fills the swap, so spent = budget), out of the slice.
  // the unspent part of the reserve goes back to the buyback pot. `tip` is that payment
  takeBuybackSlice(now) {
    const s = this.s, p = this.p;
    const pool = this.ethToBuyback;
    if (pool <= 1e-15 || now < this.lastBuybackTime + s.buybackDelay * 12) return null;
    const slice = Math.min(pool, s.buybackSlice);
    const rate = Math.min(p.basefeeGwei, s.keeperMaxBaseFee) * 1e-9;
    const reserve = p.BUYBACK_GAS * rate + s.keeperFee;
    if (slice < 2 * reserve) return null;
    const tip = p.BUYBACK_GAS_USED * rate + s.keeperFee * Math.min(1, (slice - reserve) / (s.buybackSlice - reserve));
    this.ethToBuyback = pool - slice + (reserve - tip);
    this.lastBuybackTime = now;
    return { slice, tip, budget: slice - reserve };
  }
}


// ---------------------------------------------------------------- the launch position
// one concentrated liquidity position, whole supply single sided in coin from the start tick up to the max tick.
// price is eth per coin, token0 is the coin. real v4 math: x = L (1/sqrtP - 1/sqrtPb), y = L (sqrtP - sqrtPa)
export class Pool {
  constructor(p) {
    this.sqrtPa = Math.pow(1.0001, p.startTick / 2);
    this.sqrtPb = Math.pow(1.0001, p.positionUpper / 2);
    this.L = p.SUPPLY / (1 / this.sqrtPa - 1 / this.sqrtPb);
    this.sqrtP = this.sqrtPa;
  }
  get price() { return this.sqrtP * this.sqrtP; }
  coinInPool() { return this.L * (1 / this.sqrtP - 1 / this.sqrtPb); }
  ethInPool() { return this.L * (this.sqrtP - this.sqrtPa); }
  // buyers add eth to the pool, coin leaves. returns coin out
  buy(ethIn) {
    if (ethIn <= 0) return 0;
    const s1 = this.sqrtP + ethIn / this.L;
    const out = this.L * (1 / this.sqrtP - 1 / s1);
    this.sqrtP = s1;
    return out;
  }
  // sellers remove up to ethOut from the pool, coin enters. returns {eth, coin} actually moved
  sell(ethOut) {
    const maxOut = this.ethInPool();
    const eth = Math.min(ethOut, maxOut);
    if (eth <= 0) return { eth: 0, coin: 0 };
    const s1 = this.sqrtP - eth / this.L;
    const coin = this.L * (1 / s1 - 1 / this.sqrtP);
    this.sqrtP = s1;
    return { eth, coin };
  }
  // eth into the pool needed to take coinOut coin out, without moving state
  ethForCoin(coinOut) {
    const inv = 1 / this.sqrtP - coinOut / this.L;
    if (inv <= 1 / this.sqrtPb) return Infinity;
    return this.L * (1 / inv - this.sqrtP);
  }
}

// ---------------------------------------------------------------- market models
const comparableDay = (d) => Math.max(COMPARABLE.a * Math.exp(-COMPARABLE.k * d), COMPARABLE.floor);

// swap volume in eth for utc day d of the coin (before volScale)
export function dayVolume(p, d) {
  if (d === 0) return p.volDay0;
  switch (p.volPreset) {
    case 'sustained17': return 17;
    case 'sustained50': return 50;
    case 'deadWeek1': return d < 7 ? comparableDay(d) : 0.2;
    case 'custom': return p.volTail + (80.6 - p.volTail) * Math.pow(0.5, (d - 1) / p.volHalfLifeDays);
    default: return comparableDay(d);
  }
}
// flat median market price of a credit, eth, along the configured path (before the engine's own lift)
export function pathPrice(p, tSec) {
  const d = tSec / 86400;
  const e = Math.exp(-d / p.priceTauDays);
  // log linear legs: 'falling' halves over the first day, 'rising' doubles over 7 days, 'whipsaw' falls 60 percent in 12 hours from
  // whipsawStartDay and recovers over the next 2 days
  if (p.pricePath === 'gap') return tSec >= p.gapHour * 3600 ? p.priceP0 * (1 + p.gapPct / 100) : p.priceP0; // one jump of gapPct percent at gapHour
  if (p.pricePath === 'falling') return p.priceP0 * Math.pow(0.5, Math.min(d, 1));
  if (p.pricePath === 'rising') return p.priceP0 * Math.pow(2, Math.min(d / 7, 1));
  if (p.pricePath === 'whipsaw') {
    const h = (tSec - p.whipsawStartDay * 86400) / 3600;
    if (h <= 0) return p.priceP0;
    if (h <= 12) return p.priceP0 * Math.pow(0.4, h / 12);
    return p.priceP0 * Math.pow(0.4, 1 - Math.min((h - 12) / 48, 1));
  }
  if (p.pricePath === 'decline') {
    const end = p.priceEndMult == null ? 0.4 : p.priceEndMult;
    return p.priceP0 * (end + (1 - end) * e);
  }
  if (p.pricePath === 'recovery') {
    const end = p.priceEndMult == null ? 2.2 : p.priceEndMult;
    return p.priceP0 * (1 + (end - 1) * (1 - e));
  }
  return p.priceP0;
}
// anti sniper skim as a fraction of notional at time t seconds after launch
export function skimFraction(p, t) {
  const base = p.baselineSkimBps / 1e4;
  if (t >= p.sniperSeconds) return base;
  const f = (p.sniperStartBps - ((p.sniperStartBps - p.sniperEndBps) * t) / p.sniperSeconds) / 1e4;
  return Math.max(base, f);
}
// share of a swap's notional the fee router receives: 90 percent of the baseline skim plus all of the anti sniper extra
export function routerFeeFraction(p, f) {
  const base = p.baselineSkimBps / 1e4;
  return base * (p.bountyBps / BPS) + Math.max(0, f - base);
}
// share of a swap's notional that lands in the engine's pot at t seconds after launch: the router's inflow,
// and after the split start less the payee's parts per million of the gross inflow.
// 5.90 points at the baseline once the split is on
export function engineFeeFraction(p, f, t) {
  const inflow = routerFeeFraction(p, f);
  return inflow * (1 - (t >= p.routerSplitStartSec ? p.routerPayeePpm / 1e6 : 0));
}
// volume in a step [t, t+dt). the first hour runs in 120 s sub steps, 15 of them inside the anti sniper window
export function stepVolume(p, t, dt) {
  const d = Math.floor(t / 86400);
  const dv = dayVolume(p, d) * p.volScale;
  if (d > 0) return (dv * dt) / 86400;
  const h = Math.floor(t / 3600);
  const h1 = dv * p.h1Share;
  if (h === 0) {
    const k = Math.floor(t / 120);
    const nS = Math.round(p.sniperSeconds / 120);
    if (k < nS) {
      let wsum = 0;
      for (let i = 0; i < nS; i++) wsum += 1 - skimFraction(p, i * 120 + 60);
      return (h1 * p.sniperVolShare * (1 - skimFraction(p, k * 120 + 60))) / wsum;
    }
    return (h1 * (1 - p.sniperVolShare)) / (30 - nS);
  }
  let wsum = 0;
  for (let i = 1; i < 24; i++) wsum += Math.exp(-(i - 1) / 5);
  return (((dv * (1 - p.h1Share)) * Math.exp(-(h - 1) / 5)) / wsum) * (dt / 3600);
}
export function stmtArrivalsPerDay(p, tSec) {
  return Math.max(p.stmtFloorPerDay, p.stmtPerDay * Math.pow(0.5, tSec / (p.stmtDecayDays * 86400)));
}
function mergeDesc(a, b) {
  const out = new Array(a.length + b.length);
  let i = 0, j = 0, k = 0;
  while (i < a.length && j < b.length) out[k++] = a[i].key >= b[j].key ? a[i++] : b[j++];
  while (i < a.length) out[k++] = a[i++];
  while (j < b.length) out[k++] = b[j++];
  return out;
}

// ---------------------------------------------------------------- the simulation
export function simulate(userParams = {}) {
  const p = Object.assign({}, DEFAULTS, userParams);
  const rng = mulberry32(p.seed);
  const core = new Core(p, 0);
  const rngThr = mulberry32((p.seed + 99991) >>> 0); // the throttler draws from its own stream, the honest sellers' draws are the same with it on or off
  const pool = new Pool(p);
  const H = Math.round(p.days * 24);
  const bLate = p.buyShareLate != null ? p.buyShareLate : (p.volPreset === 'sustained17' || p.volPreset === 'sustained50') ? 0.5 : p.volPreset === 'custom' ? 0.49 : 0.46;
  const phase2At = p.phase2Day == null ? Infinity : p.phase2Day * 86400;
  const sched = (p.schedule || []).map((e) => ({ at: e.day * 86400, patch: e.patch, done: false })).sort((a, b) => a.at - b.at);

  // state
  let book = []; // resting market offers, ordered by descending key (wei per point needed to clear, in units of the market price), smallest last
  let strat = []; // CreditStrategy listings, ordered by descending need (wei per point to clear)
  let holdPool = p.holders;
  const pile = []; // the one credit pile, oldest first: {pts, cost, t0}. credits bought with eth and with the exit token enter it alike (FLOW 92)
  let unbid = []; // statements held by the Core for sale or redemption
  let lnM = 0, nextSid = 1;
  const T = { // totals
    fees: 0, feesBuyback: 0, saleGross: 0, saleToPot: 0, saleToBuyback: 0, spent: 0, listingPaid: 0,
    bought: 0, boughtX: 0, pts: 0, cost: 0, mkt: 0, ask: 0, sumM: 0, composed: 0, composedChosen: 0, sold: 0, exited: 0,
    creditSold: 0, creditGross: 0, creditCost: 0, creditToPot: 0, creditToBuyback: 0, creditMiss: 0, creditAge: 0,
    soldPrice: 0, soldCost: 0, soldPts: 0, soldFloor: 0, soldAge: 0, soldAtFloor: 0, buybackSpent: 0, buybackTips: 0, burned: 0,
    listBought: 0, stratBought: 0, xRecv: 0, xSpent: 0, firstFill: -1,
    clampSteps: 0, potBindSteps: 0, vol: 0, stCost: 0, stRating: 0, stmtArrivals: 0, stmtMiss: 0,
    throttled: 0, maxPaidRatio: 0,
    first80cost: 0, first80mkt: 0, first80pts: 0, first80n: 0, first80t: -1, exitedValue: 0, exitedCost: 0, exitedAge: 0, settingsChanges: 0,
  };
  const histPts = new Array(10).fill(0), histCost = new Array(10).fill(0);
  const S = {}; // series, one entry per hour
  const names = ['pot', 'toBuyback', 'cumFees', 'rate', 'mktPerPoint', 'bidRatio', 'bought', 'credits', 'creditsDay', 'avgScoreCum', 'avgScoreDay',
    'costPerCredit', 'mktPerCredit', 'composed', 'sold', 'waiting', 'locked', 'exited', 'buybackSpent', 'burnEth', 'burned', 'burnedPct',
    'coinPrice', 'xPot', 'redeemBurn', 'book', 'saleToPot', 'saleToBuyback', 'feeToBuyback', 'feeToRedeemBurn', 'redeemBurnMoved', 'avgSalePct', 'avgSaleAgeH', 'saleGross', 'cumPts', 'cumCost', 'cumMkt', 'xBought',
    'volume', 'poolEth', 'spent', 'pile', 'creditSold', 'creditToBuyback'];
  for (const n of names) S[n] = new Array(H + 1);

  // initial resting book at steady state, and the CreditStrategy inventory. a key is the ask as a multiple of the market price of a credit
  const newOffer = () => {
    const pts = 80 + 720 * rng();
    const m = Math.max(Math.exp(p.askSigma * normal(rng)), p.askFloor);
    const prem = pts >= 790 ? 2.0 : pts >= 740 ? 1.12 : 1.0;
    return { pts, m, prem, key: m * prem, listed: rng() < p.listedShare };
  };
  const nBook0 = Math.round(p.offersPerHour / Math.max(p.bookChurn, 1e-3));
  for (let i = 0; i < nBook0; i++) book.push(newOffer());
  book.sort((a, b) => b.key - a.key);
  if (p.strategyOn) {
    for (const [price, count] of STRAT_LISTINGS) {
      for (let i = 0; i < count; i++) {
        const pts = interp(STRAT_SCORE_Q, rng());
        strat.push({ pts, price, need: price * W });
      }
    }
    strat.sort((a, b) => b.need - a.need);
  }
  const peff = (t) => pathPrice(p, t) * Math.exp(lnM);
  let stepW = 1, peffNow = 0; // weight of the current step in hours, market price in the step
  let idle = 0, idleMax = 0, forceDone = false;
  let stallRun = 0, stallTotal = 0, stallMax = 0, gapRun = 0, gapMax = 0, gateClosed = 0, rateCapSec = 0;
  const stallRuns = [];
  let runCause = {}; const stallCause = {};
  let prevRate = p.rateStart, signChanges = 0, lastDir = 0, rateMaxRatio = 0, rateAbsMove = 0, rateMoves = 0;

  // ---- the engine buys: market offers through the bid or a listing, CreditStrategy listings, exitToken bid in phase 2.
  // nothing here looks at unsold statements: the engine never stops buying because statements are unsold.
  // a seller whose credit does not fit the pot waits, and another credit that fits sells instead
  // xPerPoint is the exit token bid per score point, eth value (0 while the bid is off): a credit of `pts` points is bid pts * xPerPoint, so the best price offered is at 800 points
  function pickFrom(arr, isStrat, r, xPerPoint, Pw, Pe, afford, xAfford) {
    const lim = Math.max(0, arr.length - 400);
    const top = Math.max(r, xPerPoint * 800 * W);
    for (let i = arr.length - 1; i >= lim; i--) {
      const it = arr[i];
      const need = isStrat ? it.need : it.key * Pw;
      if (need > top) return null;
      const listing = isStrat || it.listed;
      const ask = isStrat ? it.price : it.m * it.prem * Pe;
      const xPrice = isStrat ? 0 : it.pts * xPerPoint;
      const ethOk = need <= r, xOk = xPrice > 0 && ask * W <= xPrice * W;
      const ethFits = ethOk && (listing ? Math.min(ask + core.listingPayMax(), r / W) <= afford : r / W <= afford);
      const xFits = xOk && xPrice <= xAfford;
      if (ethFits || xFits) return { i, need, ethFits, xFits, isStrat, it, ask, listing };
    }
    return null;
  }
  // a sale that clears the bid but is blocked: the pot cannot pay the cheapest ask
  function noteBind() {
    T.potBindSteps += stepW;
  }
  function engineBuys(now, Pe) {
    let spentEth = 0, thrDone = !p.throttler;
    let forceNow = p.forceFillHour != null && !forceDone && now >= p.forceFillHour * 3600;
    if (forceNow) forceDone = true;
    const Pw = Pe * W;
    for (let guard = 0; guard < 200000; guard++) {
      const r = core.ethRate(now);
      const p2 = core.exitBidActive();
      const xPerPoint = p2 ? core.xBidPrice(1) : 0;
      const afford = core.ethPot;
      const xAfford = p2 ? core.xPot : 0;
      if (afford <= 1e-15 && xAfford <= 0) { noteBind(); break; }
      const a = pickFrom(book, false, r, xPerPoint, Pw, Pe, afford, xAfford);
      const b = strat.length ? pickFrom(strat, true, r, 0, Pw, Pe, afford, 0) : null;
      let c = a && b ? (b.need < a.need ? b : a) : a || b;
      // the throttler sells first, one credit a step, at the bid, once the bid has reached throttleFrac of the market price
      if (!thrDone) {
        thrDone = true;
        const tp = 80 + 720 * rngThr();
        if (r / W >= p.throttleFrac * Pe && r / W <= afford) {
          c = { i: -1, need: r, ethFits: true, xFits: false, isStrat: false, it: { pts: tp, m: p.throttleFrac, prem: 1, listed: false }, ask: p.throttleFrac * Pe, listing: false, thr: true };
        }
      }
      let inj = null;
      if (forceNow) {
        forceNow = false;
        core.checkpoint(now); core.rateAtCheckpoint = p.forceFillFrac * Pe * W; core.syncFunded();
        inj = { forced: true };
      }
      if (inj) c = Object.assign(inj, { i: -1, need: r, ethFits: true, xFits: false, isStrat: false, it: { pts: 440, m: 1, prem: 1, listed: false }, ask: Pe, listing: false, thr: true });
      if (!c) { noteBind(); break; }
      const it = c.it, useS = c.isStrat;
      let door = c.ethFits && c.xFits ? (r / W >= it.pts * xPerPoint ? 'eth' : 'x') : c.ethFits ? 'eth' : 'x';
      let cost = 0, paid = 0, viaListing = false, ok = false, xCost = 0;
      if (door === 'x') {
        // the exit token bid pays score * unitPerPoint less the margin for the credit. the credit enters the pile at an eth cost (FLOW 92, 93)
        const xr = core.xBuyCredit(it.pts, now);
        cost = xr ? xr.paid : 0; xCost = xr ? xr.cost : 0;
        ok = cost > 0;
        if (!ok && c.ethFits) door = 'eth';
      }
      if (door === 'eth') {
        if (c.listing) {
          const res = core.buyListing(c.ask, now);
          if (res) { cost = res.cost; paid = res.paid; ok = true; viaListing = true; }
        } else {
          cost = core.sellForEth(now);
          ok = cost > 0;
        }
      }
      if (!ok) break;
      if (!c.thr) { if (useS) strat.splice(c.i, 1); else book.splice(c.i, 1); holdPool -= 1; } else if (c.thr && !c.forced) T.throttled++;
      if (door === 'x') {
        T.boughtX++; T.xSpent += cost; pile.push({ pts: it.pts, cost: xCost, t0: now });
      } else {
        T.bought++; T.pts += it.pts; T.cost += cost + paid; T.mkt += Pe; T.ask += c.ask; T.spent += cost + paid; T.listingPaid += paid;
        spentEth += cost + paid;
        if (viaListing) T.listBought++;
        if (useS) T.stratBought++;
        else T.sumM += it.m;
        const bin = Math.min(9, Math.floor((it.pts - 80) / 72));
        histPts[bin]++; histCost[bin] += cost + paid;
        T.maxPaidRatio = Math.max(T.maxPaidRatio, (cost + paid) / Pe);
        pile.push({ pts: it.pts, cost: cost + paid, t0: now });
        if (T.firstFill < 0) T.firstFill = now / 3600;
        if (T.first80n < 80) {
          T.first80n++; T.first80cost += cost + paid; T.first80mkt += Pe; T.first80pts += it.pts;
          if (T.first80n === 80) T.first80t = now / 3600;
        }
      }
    }
    return spentEth;
  }

  // ---- compose when the pile holds 80 credits past their window (all of them while the credit sale is off). compose() takes the 80 oldest; with
  // chosenComposeOn and composeChoice 'richest' the composer names the 80 highest scoring ready credits (composeChosen). the statement is listed at age zero, at the start price
  function composeAll(now) {
    for (;;) {
      let ready = 0;
      while (ready < pile.length && core.pastWindow(pile[ready].t0, now)) ready++; // the pile is oldest first, so the ready credits are a prefix
      if (ready < p.PAGE) break;
      let page;
      if (core.cr.chosenComposeOn && p.composeChoice === 'richest') {
        const order = pile.slice(0, ready).map((c, i) => [c, i]).sort((a, b) => b[0].pts - a[0].pts || a[1] - b[1]).slice(0, p.PAGE);
        const take = new Set(order.map((o) => o[1]));
        page = order.map((o) => o[0]);
        for (let i = ready - 1; i >= 0; i--) if (take.has(i)) pile.splice(i, 1);
        T.composedChosen++;
      } else page = pile.splice(0, p.PAGE);
      let cost = 0, rating = 0;
      for (const c of page) { cost += c.cost; rating += c.pts; }
      const st = core.compose(cost, now, rating);
      st.id = nextSid++;
      T.composed++; T.stCost += st.cost; T.stRating += rating;
      unbid.push(st);
    }
  }

  // ---- buyers of pile credits (ControllerV1.buyCredit), while the credit sale is on. a buyer arrives with a willingness to pay of creditWtpMult times the market price of a
  // credit times a lognormal draw, takes the pile credit with the lowest price now if that fits, and pays it through sellCreditTo. credits acquired in the step meet buyers
  // from the next step on. no random draw is made while the sale is off
  function creditBuyers(t0, t1, Pe) {
    if (!core.cr.creditSaleOn || !pile.length) return;
    const n = poisson(rng, (p.creditBuyersPerDay * (t1 - t0)) / 86400);
    if (!n) return;
    const times = [];
    for (let i = 0; i < n; i++) times.push(t0 + rng() * (t1 - t0));
    times.sort((a, b) => a - b);
    for (const ta of times) {
      const wtp = Pe * p.creditWtpMult * Math.exp(p.askSigma * normal(rng));
      if (core.isPausedAt(ta)) { T.creditMiss++; continue; }
      let best = -1, bestPrice = Infinity;
      for (let i = 0; i < pile.length; i++) {
        if (pile[i].t0 > ta) break;
        const price = core.creditPrice(pile[i], ta);
        if (price < bestPrice) { bestPrice = price; best = i; }
      }
      if (best < 0 || bestPrice > wtp * (1 + 1e-12)) { T.creditMiss++; continue; }
      const cr = pile[best], res = core.buyCredit(cr, ta);
      if (!res) { T.creditMiss++; continue; }
      pile.splice(best, 1);
      T.creditSold++; T.creditGross += res.price; T.creditCost += cr.cost; T.creditToPot += res.toPot; T.creditToBuyback += res.toBuyback;
      T.creditAge += ta - cr.t0;
    }
  }

  // a statement sold at `price` to a buyer who came at `at`: totals for the sale price over cost, the age at the sale and the share at the lowest price
  function noteSale(st, price, at) {
    T.sold++; T.soldPrice += price; T.soldCost += st.cost; T.soldPts += st.rating; T.soldFloor += core.floorPrice(st);
    T.soldAge += at - st.t0;
    if (price <= core.lowestPrice(st, at) * (1 + 1e-9)) T.soldAtFloor++;
  }
  // ---- statement buyers. a buyer arrives with a willingness to pay that is a multiple of the MARKET cost of 80 credits (80 times the flat market
  // price Pe), while the asking price is a share of what the ENGINE PAID for the statement's parts (the statement cost). the buyer takes
  // the statement with the lowest asking price at or under its willingness to pay (stmtPick random: any one that fits) and does not wait for a
  // lower price (buyerWaits 'floor' is the pessimistic case: it only buys a statement whose asking price has reached its lowest level).
  // it pays the asking price and gets the statement at once through sellTo
  function statementBuyers(t0, t1, Pe) {
    const n = poisson(rng, (stmtArrivalsPerDay(p, t1) * (t1 - t0)) / 86400);
    if (!n) return;
    const times = [];
    for (let i = 0; i < n; i++) times.push(t0 + rng() * (t1 - t0));
    times.sort((a, b) => a - b);
    const waits = p.buyerWaits === 'floor';
    for (const ta of times) {
      T.stmtArrivals++;
      if (core.isPausedAt(ta)) { T.stmtMiss++; continue; } // ControllerV1.buy reverts Paused
      const wtp = interp(WTP_Q, rng()) * p.wtpMult * p.PAGE * Pe;
      const opts = [];
      for (const st of unbid) {
        const mb = core.askingPrice(st, ta);
        if (mb > wtp * (1 + 1e-12)) continue;
        if (waits && mb > core.lowestPrice(st, ta) * (1 + 1e-9)) continue;
        opts.push({ st, mb });
      }
      if (!opts.length) { T.stmtMiss++; continue; }
      let pick = opts[0];
      if (p.stmtPick === 'random') pick = opts[Math.floor(rng() * opts.length)];
      else for (const o of opts) if (o.mb < pick.mb) pick = o;
      const res = core.buy(pick.st, ta);
      if (!res) { T.stmtMiss++; continue; }
      unbid.splice(unbid.indexOf(pick.st), 1);
      T.saleGross += pick.mb; T.saleToPot += res.toPot; T.saleToBuyback += res.toBuyback;
      noteSale(pick.st, pick.mb, ta);
    }
  }

  // ---- phase 2: a keeper redeems held statements through the exit module (Core.exitStatement) once the curve price has reached its floor (needs exitMode 1 or 2).
  // the exit token returned goes to xPot, a redemption moves redeemBurnBps of the reserve to the buyback
  function exits(now) {
    if (!core.moduleSet || core.s.exitMode < 1) return;
    if (unbid.length) {
      const keep = [];
      for (const st of unbid) {
        if (core.exitReady(st, now) && st.rating * core.xpPerPoint >= p.exitMinRatio * core.askingPrice(st, now)) {
          const res = core.exitStatement(st, now);
          if (!res) { keep.push(st); continue; }
          T.exited++; T.xRecv += res.received; T.exitedValue += res.received; T.exitedCost += st.cost; T.exitedAge += now - st.t0;
        } else keep.push(st);
      }
      unbid = keep;
    }
  }

  // ---- eth buyback keeper: one slice per buybackDelay blocks, coin bought in the pool and burned
  function buybacks(stepStart, now) {
    if (!p.keeperBuyback) return;
    const delay = core.s.buybackDelay * 12;
    let tb = Math.max(stepStart, core.lastBuybackTime + delay), feeBack = 0;
    while (tb <= now && core.ethToBuyback > 1e-15) {
      const info = core.takeBuybackSlice(tb);
      if (!info) break;
      const f = skimFraction(p, tb);
      const notional = info.budget / (1 + f);
      T.burned += pool.buy(notional);
      T.buybackSpent += info.budget; T.buybackTips += info.tip;
      feeBack += notional * engineFeeFraction(p, f, tb);
      tb += delay;
    }
    if (feeBack > 0) { core.addFees(feeBack, now); T.feesBuyback += feeBack; }
  }

  // ---- series snapshot at the end of hour index h
  function record(h, t) {
    const Pe = peff(t), r = core.ethRate(t);
    let locked = 0;
    for (const s of unbid) locked += s.cost;
    S.pot[h] = core.ethPot; S.toBuyback[h] = core.ethToBuyback;
    S.cumFees[h] = T.fees + T.feesBuyback;
    S.rate[h] = r; S.mktPerPoint[h] = (Pe * W) / 440;
    S.bidRatio[h] = r / (Pe * W);
    S.bought[h] = T.bought; S.cumPts[h] = T.pts; S.cumCost[h] = T.cost; S.cumMkt[h] = T.mkt;
    S.credits[h] = T.bought + T.boughtX;
    S.creditsDay[h] = S.credits[h] - S.credits[Math.max(0, h - 24)];
    S.avgScoreCum[h] = T.bought ? T.pts / T.bought : 0;
    const h24 = Math.max(0, h - 24);
    const dB = T.bought - S.bought[h24], dP = T.pts - S.cumPts[h24];
    S.avgScoreDay[h] = dB > 0 ? dP / dB : (h > 0 ? S.avgScoreDay[h - 1] : 0);
    S.costPerCredit[h] = T.bought ? T.cost / T.bought : 0; S.mktPerCredit[h] = Pe;
    S.composed[h] = T.composed; S.sold[h] = T.sold; S.waiting[h] = unbid.length;
    S.locked[h] = locked;
    S.exited[h] = T.exited; S.buybackSpent[h] = T.buybackSpent; S.burnEth[h] = T.buybackSpent + T.buybackTips;
    S.burned[h] = T.burned; S.burnedPct[h] = (T.burned / p.SUPPLY) * 100;
    S.coinPrice[h] = pool.price; S.xPot[h] = core.xPot; S.redeemBurn[h] = core.ethRedeemBurn;
    S.book[h] = book.length;
    S.saleToPot[h] = T.saleToPot; S.saleToBuyback[h] = T.saleToBuyback; S.feeToBuyback[h] = core.feeToBuyback; S.feeToRedeemBurn[h] = core.feeToRedeemBurn; S.redeemBurnMoved[h] = core.redeemBurnMoved; S.saleGross[h] = T.saleGross;
    S.avgSalePct[h] = T.soldCost ? (T.soldPrice / T.soldCost) * 100 : NaN; S.avgSaleAgeH[h] = T.sold ? T.soldAge / T.sold / 3600 : NaN; S.xBought[h] = T.boughtX;
    S.volume[h] = T.vol; S.poolEth[h] = pool.ethInPool();
    S.spent[h] = T.spent; S.pile[h] = pile.length; S.creditSold[h] = T.creditSold; S.creditToBuyback[h] = T.creditToBuyback;
  }

  // ---- the owner changes settings on a day (schedule), at the start of the step that reaches it
  function applySchedule(t0) {
    for (const e of sched) {
      if (e.done || e.at > t0) continue;
      e.done = true; T.settingsChanges++;
      // owner calls that are not settings: the module reports a unit, refreshUnitPerPoint, releaseRedeemBurn (a revert changes nothing)
      const { moduleUnit, refreshUnitPerPoint, releaseRedeemBurn, ...rest } = e.patch;
      if (Object.keys(rest).length) core.setSettings(rest, t0);
      if (moduleUnit !== undefined) core.moduleReports(moduleUnit);
      if (refreshUnitPerPoint) core.refreshUnitPerPoint();
      if (releaseRedeemBurn !== undefined) core.releaseRedeemBurn(releaseRedeemBurn);
    }
  }

  // ---- the main loop. hour 0 runs in 120 s sub steps for the anti sniper window, then steps of stepSec (an hour by default)
  const steps = [];
  for (let k = 0; k < 30; k++) steps.push([k * 120, (k + 1) * 120]);
  if (!(p.stepSec >= 1) || 3600 % p.stepSec !== 0) throw new Error('stepSec must divide 3600');
  for (let t = 3600; t < H * 3600; t += p.stepSec) steps.push([t, t + p.stepSec]);
  record(0, 0);
  for (const [t0, t1] of steps) {
    const dt = t1 - t0, mid = (t0 + t1) / 2;
    stepW = dt / 3600;
    applySchedule(t0);
    // coin market: volume, fees to the pot, price impact on the single position
    const V = stepVolume(p, t0, dt), f = skimFraction(p, mid), b = t0 < 86400 ? p.buyShare0 : bLate;
    const net = b * V - (1 - b) * V; // notional is the pool's own delta, the skim comes on top
    if (net > 0) pool.buy(net); else if (net < 0) pool.sell(-net);
    const fee = V * engineFeeFraction(p, f, mid);
    core.addFees(fee, mid);
    T.fees += fee; T.vol += V;
    if (!core.moduleSet && t1 >= phase2At) { core.setExitModule(t1, p.xpPerPoint); if (p.phase2ExitMode != null) core.setSettings({ exitMode: p.phase2ExitMode }, t1); }
    // credit market: the engine's own buying lifts the flat price, the lift decays
    lnM *= Math.pow(0.5, dt / (p.impactHalfLifeHours * 3600));
    const Pe = peff(t1), r0 = core.ethRate(t1);
    const xPay = core.exitBidActive() && core.xPot > 0 ? core.xBidPrice(440) * W : 0; // the exit token bid for an average credit
    const boost = Math.pow(Math.max(1, Math.max(r0, xPay) / (Pe * W)), p.supplyElast);
    const nOff = Math.min(poisson(rng, (p.offersPerHour * dt * boost) / 3600), 1500, Math.floor(Math.max(holdPool, 0) * 0.05));
    if (p.bookChurn > 0) {
      const keepP = Math.pow(1 - p.bookChurn, dt / 3600);
      book = book.filter(() => rng() < keepP);
    }
    if (nOff > 0) {
      const add = [];
      for (let i = 0; i < nOff; i++) add.push(newOffer());
      add.sort((x, y) => y.key - x.key);
      book = mergeDesc(book, add);
      if (book.length > 6000) book = book.slice(book.length - 6000); // keep the cheapest to clear
    }
    // the engine acts. there is no inventory gate: unsold statements never close the bid
    peffNow = Pe;
    const filledBefore = T.bought + T.boughtX;
    const spentEth = engineBuys(t1, Pe);
    if (p.holdPot > 0 && core.ethPot < p.holdPot) core.addFees(p.holdPot - core.ethPot, t1);
    // stall: the pot affords the cheapest ask, no purchase for a stretch; a run longer than 2 hours counts. gap: the same run, any length
    {
      let cheapest = Infinity;
      for (const arr of [book, strat]) for (let i = arr.length - 1, k = 0; i >= 0 && k < 400; i--, k++) { const it = arr[i], a = arr === strat ? it.price : it.m * it.prem * Pe; if (a < cheapest) cheapest = a; }
      if (T.bought + T.boughtX === filledBefore && cheapest < Infinity && core.ethPot >= cheapest) {
        stallRun += dt; gapRun += dt;
        // cause of this step: why the bid cannot buy the cheapest ask. low_*: the bid sits under the ask and the named limit is the lowest of the climb limits
        const rr2 = core.ethRate(t1), bidPrice = rr2 / W;
        let cause;
        if (bidPrice >= cheapest * (1 - 1e-9)) cause = bidPrice > core.ethPot ? 'room' : 'other';
        else {
          // the lowest of the climb limits names the cause: the pot (the clamp), the rateCap or the stepped ceiling
          const lim = { clamp: core.ethPot, rateCap: core.s.rateCap / W, ceiling: p.bidRule === 'stepped' ? core.stepCeil(t1) / W : Infinity };
          cause = 'low_climbing';
          let lo = cheapest * (1 - 1e-9);
          for (const k of Object.keys(lim)) if (lim[k] < lo) { lo = lim[k]; cause = 'low_' + k; }
        }
        runCause[cause] = (runCause[cause] || 0) + dt;
      }
      else {
        if (stallRun > 7200) { for (const k of Object.keys(runCause)) stallCause[k] = (stallCause[k] || 0) + runCause[k]; stallTotal += stallRun; stallMax = Math.max(stallMax, stallRun); if (stallRuns.length < 300) stallRuns.push([t1 - stallRun - dt, stallRun]); }
        stallRun = 0; runCause = {}; gapMax = Math.max(gapMax, gapRun); gapRun = 0;
      }
      if (unbid.length >= p.gateAt) gateClosed += dt;
      if (core.ethRate(t1) >= core.s.rateCap * (1 - 1e-9)) rateCapSec += dt;
    }
    // idle: time since the last purchase that the pot held at least one bid
    if (T.bought + T.boughtX > filledBefore) idle = 0;
    else if (core.ethPot >= core.ethRate(t1) / W) { idle += dt; idleMax = Math.max(idleMax, idle); } else idle = 0;
    if (core.funded && core.clamp() < Infinity && core.ethRate(t1) >= core.clamp() * (1 - 1e-9)) T.clampSteps++;
    lnM = Math.min(lnM + (p.impactElast * spentEth) / p.marketDailyEth, Math.log(p.impactCap));
    // statements already listed meet buyers during the step, then the engine composes and lists new ones
    statementBuyers(t0, t1, peff(t1));
    creditBuyers(t0, t1, peff(t1));
    composeAll(t1);
    exits(t1);
    buybacks(t0, t1);
    // rate path statistics
    const rr = core.ethRate(t1);
    if (T.firstFill >= 0 && dt === 3600) {
      const lc = Math.log(rr / prevRate);
      rateAbsMove += Math.abs(lc); rateMoves++;
      const dir = Math.abs(lc) < 0.002 ? 0 : lc > 0 ? 1 : -1;
      if (dir !== 0) { if (lastDir !== 0 && dir !== lastDir) signChanges++; lastDir = dir; }
    }
    prevRate = rr;
    rateMaxRatio = Math.max(rateMaxRatio, rr / (peff(t1) * W));
    if (p.onStep) p.onStep(t1, core, Pe, rr, T);
    if (t1 % 3600 === 0) record(t1 / 3600, t1);
  }

  if (stallRun > 7200) { for (const k of Object.keys(runCause)) stallCause[k] = (stallCause[k] || 0) + runCause[k]; stallTotal += stallRun; stallMax = Math.max(stallMax, stallRun); stallRuns.push([H * 3600 - stallRun, stallRun]); }
  gapMax = Math.max(gapMax, gapRun);
  // ---- results
  const at = (d) => {
    const i = Math.min(H, Math.round(d * 24));
    const o = { day: d };
    for (const n of names) o[n] = S[n][i];
    return o;
  };
  const avgPtsBought = T.bought ? T.pts / T.bought : 0;
  const stats = {
    firstFillHour: T.firstFill,
    first80: T.first80n === 80 ? { hours: T.first80t, cost: T.first80cost, market: T.first80mkt, ratio: T.first80cost / T.first80mkt, avgScore: T.first80pts / 80 } : null,
    avgScoreBought: avgPtsBought,
    costVsMarket: T.mkt ? T.cost / T.mkt : 0, // eth paid per credit over the flat market price at the time
    costPerPointVsMarket: T.bought ? (T.cost / T.pts) / (T.mkt / T.bought / 440) : 0,
    costVsAsk: T.ask ? T.cost / T.ask : 0,
    potBlockedSteps: T.potBindSteps, clampSteps: T.clampSteps,
    rateMaxBidRatio: rateMaxRatio, rateSignChanges: signChanges, rateMeanAbsMove: rateMoves ? rateAbsMove / rateMoves : 0,
    saleOverCost: T.soldCost ? T.soldPrice / T.soldCost : 0, saleOverFloor: T.soldFloor ? T.soldPrice / T.soldFloor : 0,
    saleAgeHours: T.sold ? T.soldAge / T.sold / 3600 : 0, saleAtFloorShare: T.sold ? T.soldAtFloor / T.sold : 0,
    stmtArrivals: T.stmtArrivals, stmtMiss: T.stmtMiss,
    potCheck: T.fees + T.feesBuyback - core.feeToBuyback - core.feeToRedeemBurn + T.saleToPot + T.creditToPot - T.spent - core.ethPot,
    buybackCheck: T.saleToBuyback + T.creditToBuyback + core.feeToBuyback + core.redeemBurnMoved - core.ethToBuyback - T.buybackSpent - T.buybackTips,
    creditCheck: T.creditGross - T.creditToPot - T.creditToBuyback,
    creditSaleOverCost: T.creditCost ? T.creditGross / T.creditCost : 0, creditSaleAgeHours: T.creditSold ? T.creditAge / T.creditSold / 3600 : 0,
    redeemCheck: core.feeToRedeemBurn - core.redeemBurnMoved - core.ethRedeemBurn,
    saleCheck: T.saleGross - T.saleToPot - T.saleToBuyback,
    stallHours: stallTotal / 3600, stallHoursMax: stallMax / 3600, gapHoursMax: gapMax / 3600, stallRuns, stallCauseHours: Object.fromEntries(Object.entries(stallCause).map(([k, v]) => [k, v / 3600])), gateClosedHours: gateClosed / 3600, rateCapHours: rateCapSec / 3600,
    idleHoursMax: idleMax / 3600, maxPaidRatio: T.maxPaidRatio, throttled: T.throttled,
    finalRate: core.ethRate(H * 3600), finalPot: core.ethPot, finalAnchorBps: core.anchorAt(H * 3600),
  };
  return { params: p, H, S, T, stats, at, histPts, histCost, core, pool, unbid, pile };
}

// the owner's metrics for one run: credits acquired, statements created, sold, eth to buy and burn the coin, statements waiting
// for phase 2, the day the launch pot is spent, and the steady state per day after that (the last 30 days of the run, or the
// days since the pot ran out when that is shorter, at least 10)
export function summary(res, day) {
  const S = res.S, T = res.T, H = res.H;
  const h = Math.min(H, Math.round((day == null ? res.H / 24 : day) * 24));
  let peak = 0, peakH = 0;
  for (let i = 0; i <= Math.min(h, 72); i++) if (S.pot[i] > peak) { peak = S.pot[i]; peakH = i; }
  let gone = null;
  for (let i = peakH + 1; i <= H; i++) if (S.pot[i] < 0.05 * peak) { gone = i / 24; break; }
  const a = res.at(h / 24);
  const out = {
    day: h / 24, credits: a.credits, statements: a.composed, sold: a.sold, burnEth: a.burnEth, burnPct: a.burnedPct, waiting: a.waiting,
    exited: a.exited, potGoneDay: gone, pot: a.pot, locked: a.locked, recycled: a.saleGross, avgSalePct: a.avgSalePct, feeToBurn: a.feeToBuyback, saleToBurn: a.saleToBuyback, firstBuyDay: res.stats.firstFillHour < 0 ? null : res.stats.firstFillHour / 24,
  };
  if (gone != null && H / 24 - Math.max(gone, H / 24 - 30) >= 10) {
    const fh = Math.round(Math.max(gone, H / 24 - 30) * 24), span = (H - fh) / 24;
    out.steadyFromDay = fh / 24;
    out.steadyCredits = (S.credits[H] - S.credits[fh]) / span;
    out.steadyStatements = (S.composed[H] - S.composed[fh]) / span;
    out.steadySold = (S.sold[H] - S.sold[fh]) / span;
    out.steadyBurnEth = (S.burnEth[H] - S.burnEth[fh]) / span;
  } else { out.steadyCredits = null; out.steadyStatements = null; out.steadySold = null; out.steadyBurnEth = null; }
  return out;
}
