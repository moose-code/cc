// ================================================================= page: controls and state
const REAL_VOL = [1557.1, 80.6, 41.9, 46.2, 57.1, 12.8, 27.8, 57.6, 11.8, 40.8, 5.3, 1.9, 2.6, 0.4];
const REAL_P = [0.03, 0.0303, 0.0262, 0.025, 0.026, 0.0247, 0.0275, 0.0284, 0.0269, 0.0123, 0.0095, 0.0082, 0.0085, 0.0118];
const $ = (id) => document.getElementById(id);
const el = (tag, cls, html) => { const e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; };
const fmtAx = (v) => (v == null || !isFinite(v) ? 'n/a' : Math.abs(v) >= 1000 ? Math.round(v).toLocaleString('en-US') : String(+v.toPrecision(3)));
const fmtN = (x, d = 3) => (x == null || !isFinite(x) ? 'n/a' : Number.isInteger(x) ? x.toLocaleString('en-US') : Math.abs(x) >= 1000 ? Math.round(x).toLocaleString('en-US') : Math.abs(x) >= 100 ? x.toFixed(0) : Math.abs(x) >= 10 ? x.toFixed(1) : Math.abs(x) >= 1 ? x.toFixed(2) : x === 0 ? '0' : x.toPrecision(d));
const fmtSci = (x) => (x == null || !isFinite(x) ? 'n/a' : x === 0 ? '0' : x.toExponential(2).replace('e+', 'e'));

// the one mid run change: the setting, its unit and a sensible value to switch to
const CHG = {
  saleFloorBps: { label: 'saleFloorBps (the one floor of a statement sale)', unit: 'bps of the price reference where the curve stops, and of cost in the Core. 0 to 65535, at most markupBps. launch 10000', to: 7500 },
  markupBps: { label: 'markupBps (start price over the anchor)', unit: 'bps, 10000 to 65535', to: 12000 },
  saleToBuybackBps: { label: 'saleToBuybackBps (sale proceeds to burn $CC)', unit: 'bps, 0 to 10000', to: 2500 },
  feeToRedeemBurnBps: { label: 'feeToRedeemBurnBps (fee share to the redeem burn reserve)', unit: 'bps, 0 to 10000. the rest of the fee eth goes to the pot', to: 2500 },
  redeemBurnBps: { label: 'redeemBurnBps (reserve share released by a redemption)', unit: 'bps, 0 to 10000', to: 5000 },
  redeemOn: { label: 'redeemOn (needs the balance side switched on to have an effect)', unit: '0 off, 1 on', to: 0 },
  balanceBidOn: { label: 'balanceBidOn (needs the balance side switched on to have an effect)', unit: '0 off, 1 on', to: 0 },
  balanceBidMarginBps: { label: 'balanceBidMarginBps (margin under the redeemable value)', unit: 'bps, 0 to 10000, independent of redeemSlippageBps', to: 4000 },
  moduleUnit: { label: 'balance module reports a new unitPerPoint (the Core and the controller read it at every use)', unit: 'eth per score point', to: 1e-5 },
  releaseRedeemBurn: { label: 'owner calls releaseRedeemBurn (reserve to the buyback pot)', unit: 'eth, capped at the reserve', to: 1 },
  rateCap: { label: 'rateCap (most the eth rate can be)', unit: 'wei per credit, 1 to uint64 max', to: 2.2e16 },
  creditSaleOn: { label: 'creditSaleOn (the credit sale window)', unit: '0 off, 1 on. on at launch', to: 1 },
  creditFloorBps: { label: 'creditFloorBps (credit sale floor over the larger of cost and valueOf(score))', unit: 'bps, 10000 to 65535. launch 11000', to: 13000 },
  creditStartBps: { label: 'creditStartBps (credit sale start price over the floor)', unit: 'bps, 10000 to uint32 max. launch 30000', to: 20000 },
  refScore: { label: 'refScore (per-credit score of the statement price reference)', unit: 'ten-thousandths of a point, 1 to 4294967295. launch 4330000, 433 points', to: 3500000 },
};
for (const [k, unit, to] of [
  ['spendCapBps', 'bps, 1 to 10000; 10000 bypasses enforcement', 10000],
  ['bucketSeconds', 'seconds, 1 to 4294967295; used budget and active drop floors survive edits', 120],
  ['balanceBidCapBps', 'bps of par, 10000 to 4294967295', 20000],
  ['idleStepSeconds', 'seconds, 1 to 4294967295; climb remains per 60 seconds', 300],
  ['sniperSeconds', 'seconds after launch before the payee latch may activate, 0 to 4294967295', 0],
  ['climbMultiplierCapBps', 'bps, 10000 to 65535; scales idle loosening only', 60000],
  ['anchorMoveBps', 'bps of the qualifying sale gap, 0 to 10000; 0 preserves the anchor clock', 0],
]) CHG[k] = { label: k, unit, to };
// every control: key in the state object, how to show it. launch values are the Core's (script/config/mainnet.json)
const BASE_STATE = { ...DEFAULTS,
  buyShareLate: 'auto', openPct: DEFAULTS.rateStart / (DEFAULTS.priceP0 * W) * 100,
  anchorHalfLifeDays: DEFAULTS.anchorHalfLife / 86400, creditWindowHours: DEFAULTS.creditWindow / 3600,
  pauseOn: false, pauseDay: 20, pauseDays: 7,
  chgOn: false, chgDay: 30, chgKey: 'saleToBuybackBps', chgValue: 7500,
  balanceOn: false, balanceDay: 14, balanceDayMode: 2,
};
const GROUPS = [
  { title: 'market', open: true, ctl: [
    { k: 'volPreset', t: 'select', label: '$CC volume preset', opts: [['comparable', 'comparable decay'], ['sustained17', 'sustained 17 eth a day'], ['sustained50', 'sustained 50 eth a day'], ['deadWeek1', 'dead after week one'], ['custom', 'custom']] },
    { k: 'volScale', t: 'range', label: 'volume scale', min: 0.05, max: 5, log: true, fmt: (v) => v.toFixed(2) + 'x', hint: 'multiplies every day, launch day included' },
    { k: 'volTail', t: 'range', label: 'custom: eth a day', min: 0.2, max: 200, log: true, fmt: (v) => fmtN(v), only: 'custom' },
    { k: 'volHalfLifeDays', t: 'range', label: 'custom: half life of day two volume, days', min: 0.5, max: 20, step: 0.5, fmt: (v) => v + 'd', only: 'custom' },
    { k: 'buyShareLate', t: 'select', label: 'net flow after day one', opts: [['auto', 'preset default'], [0.42, 'heavy selling, 0.42 buys'], [0.46, 'selling, 0.46'], [0.5, 'balanced, 0.50'], [0.54, 'buying, 0.54']] },
    { k: 'pricePath', t: 'select', label: 'credit price path', opts: [['flat', 'flat at today'], ['decline', 'continued decline'], ['recovery', 'recovery']] },
    { k: 'priceP0', t: 'range', label: 'flat credit price today, eth', min: 0.003, max: 0.04, log: true, fmt: (v) => v.toFixed(4), hint: 'median 0.0089 at the snapshot, was 0.03' },
    { k: 'impactElast', t: 'range', label: 'engine price impact on credits', min: 0, max: 0.5, step: 0.02, fmt: (v) => v.toFixed(2), hint: '0 means the engine never moves the market' },
    { k: 'wtpMult', t: 'range', label: 'statement buyer willingness to pay', min: 0.5, max: 1.6, step: 0.05, fmt: (v) => v.toFixed(2) + 'x', hint: '1.00x is the observed median 0.84 of parts cost' },
    { k: 'stmtPerDay', t: 'range', label: 'statement buyers a day at launch', min: 1, max: 40, step: 1, fmt: (v) => v.toFixed(0), hint: 'observed 4 to 13 a day, decays to 2' },
    { k: 'buyerWaits', t: 'select', label: 'do buyers wait for a lower price', opts: [['no', 'no, a buyer buys what it can afford now'], ['floor', 'yes, every buyer waits for the lowest price (pessimistic)']] },
  ] },
  { title: 'launch settings', open: true, ctl: [
    { k: 'openPct', t: 'range', label: 'opening limit, percent of market', min: 20, max: 125, step: 5, fmt: (v) => v + '%', hint: 'rateStart, wei per credit =', hintFn: (s) => fmtSci(rateOf(s)) },
  ] },
  { title: 'selling statements', open: true, ctl: [
    { k: 'markupBps', t: 'range', label: 'start price over the anchor (markupBps)', min: 10000, max: 40000, step: 500, fmt: (v) => v / 100 + '%', hint: 'asking price when a statement is listed, as a share of the anchor, the running level of sale prices in percent of the price reference (100% at launch, each sale moves it halfway to the price paid, never below 100%)' },
    { k: 'startCapBps', t: 'range', label: 'cap on the start price (startCapBps)', min: 15000, max: 200000, step: 5000, fmt: (v) => v / 100 + '%', hint: 'the start price never passes this share of the price reference, whatever the anchor' },
    { k: 'decayHours', t: 'range', label: 'hours for the asking price to fall to the floor (decayHours)', min: 1, max: 720, step: 1, fmt: (v) => Math.round(v) + 'h', hint: 'asking price walk:', hintFn: (s) => walkText(s) },
    { k: 'saleFloorBps', t: 'range', label: 'floor of the asking price, set in the Core (saleFloorBps)', min: 1000, max: 12000, step: 500, fmt: (v) => v / 100 + '%', hint: 'the price falls to here, in percent of the price reference, and stops. the Core takes no sale under this share of cost either. launch 10000: unsold statements sit at their reference, and redeem once redeemOn allows' },
    { k: 'saleToBuybackBps', t: 'range', label: 'saleToBuybackBps, sale proceeds to burn $CC', min: 0, max: 10000, step: 500, fmt: (v) => v, hint: 'share of sale proceeds that buys and burns $CC, the rest goes to the pot' },
    { k: 'feeToRedeemBurnBps', t: 'range', label: 'feeToRedeemBurnBps, fee share to the redeem burn reserve', min: 0, max: 10000, step: 500, fmt: (v) => v, hint: 'share of $CC swap fee eth held back for redemptions. each redemption of a held statement moves redeemBurnBps of the reserve to buy and burn $CC. launch 1000. the rest goes to the pot' },
    { k: 'anchorHalfLifeDays', t: 'range', label: 'anchorHalfLife, days', min: 1, max: 90, step: 1, fmt: (v) => v + 'd', hint: 'the part of the anchor above 100% of the reference halves in this time. launch 7' },
    { k: 'anchorMinCost', t: 'range', label: 'anchorMinCost, eth', min: 0, max: 10, step: 0.1, fmt: (v) => v.toFixed(1), hint: 'a sale of a statement that cost less leaves the anchor where it is. launch 0.1' },
  ] },
  { title: 'pause statement sales (setPaused)', open: false, ctl: [
    { k: 'pauseOn', t: 'check', label: 'the owner pauses statement sales' },
    { k: 'pauseDay', t: 'range', label: 'from day', min: 1, max: 89, step: 1, fmt: (v) => 'day ' + v },
    { k: 'pauseDays', t: 'range', label: 'for how many days', min: 1, max: 60, step: 1, fmt: (v) => v + 'd', hint: 'a buy reverts while paused, the price clock stops, composing, the bid, redemptions and buybacks run on' },
  ] },
  { title: 'statement price reference and chosen composition', open: false, ctl: [
    { k: 'refScore', t: 'range', label: 'refScore, per-credit score of the reference', min: 1000000, max: 8000000, step: 100000, fmt: (v) => fmtN(v / 1e4) + ' points', hint: 'a statement references its cost, scaled by its rating over 80 times this score when richer. the curve, its floor and the anchor are fractions of the reference. launch 433 points (4,330,000, ten-thousandths of a point)' },
    { k: 'chosenComposeOn', t: 'check', label: 'chosen composition open (chosenComposeOn)', hint: 'a caller names the 80 credits and the format of a statement (composeChosen). off at launch' },
    { k: 'composeChoice', t: 'select', label: 'what the composer names while it is open', opts: [['oldest', 'the 80 oldest, as compose() does'], ['richest', 'the 80 highest scoring credits past their window']] },
  ] },
  { title: 'credit sale window (creditSaleOn)', open: false, ctl: [
    { k: 'creditSaleOn', t: 'check', label: 'pile credits are for sale from their acquisition time', hint: 'on at launch. compose waits for a credit to pass its window while this is on' },
    { k: 'creditWindowHours', t: 'range', label: 'creditWindow, hours', min: 0.1, max: 720, log: true, fmt: (v) => fmtN(v) + 'h', hint: 'the price falls over this time and rests at the floor. launch 4' },
    { k: 'creditFloorBps', t: 'range', label: 'creditFloorBps', min: 10000, max: 40000, step: 500, fmt: (v) => v, hint: 'the floor is the highest of the credit cost, its balance token baseline and the eth bid, times this. launch 11000' },
    { k: 'creditStartBps', t: 'range', label: 'creditStartBps', min: 10000, max: 200000, step: 5000, fmt: (v) => v, hint: 'the start price is the floor times this. launch 30000' },
    { k: 'creditCostToPotBps', t: 'range', label: 'creditCostToPotBps', min: 0, max: 10000, step: 500, fmt: (v) => v, hint: 'share of a sold credit cost that returns to the pot, the rest of the payment buys and burns $CC. launch 8000' },
    { k: 'creditBuyersPerDay', t: 'range', label: 'credit buyers a day', min: 1, max: 400, log: true, fmt: (v) => fmtN(v), hint: 'a model input: buyers of pile credits, each takes the lowest priced credit that fits its willingness to pay' },
    { k: 'creditWtpMult', t: 'range', label: 'credit buyer willingness to pay', min: 0.5, max: 2, step: 0.05, fmt: (v) => v.toFixed(2) + 'x', hint: 'times the market price of a credit, with the spread of the sellers asks' },
  ] },
  { title: 'engine settings', open: false, ctl: [
    { k: 'dropPerCreditPct', t: 'range', label: 'dropPerCreditBps', min: 0.1, max: 5, log: true, fmt: (v) => Math.round(v * 100), hint: 'bps the bid falls after each credit bought. launch 50' },
    { k: 'dropToPct', t: 'range', label: 'dropFloorBps', min: 50, max: 99, step: 1, fmt: (v) => v * 100, hint: 'within one minute the bid stays at or above this share of the rate at the first fill. launch 5000' },
    { k: 'climbPerMin', t: 'range', label: 'climbPerMinBps', min: 0.1, max: 3, log: true, fmt: (v) => Math.round(v * 100), hint: 'bps the bid climbs each minute. launch 50' },
    { k: 'ceilPct', t: 'range', label: 'ceilBps', min: 101, max: 300, step: 1, fmt: (v) => v * 100, hint: 'the bid never climbs above this share of the ceiling anchor, the higher of the last fill rate and the remembered peak. launch 11000' },
    { k: 'recoveryClimbPerMin', t: 'range', label: 'recoveryClimbPerMinBps', min: 0.5, max: 10, log: true, fmt: (v) => Math.round(v * 100), hint: 'bps the bid climbs each minute while it is more than recoveryGapBps under the remembered peak. launch 200' },
    { k: 'recoveryGapPct', t: 'range', label: 'recoveryGapBps', min: 0, max: 50, step: 1, fmt: (v) => v * 100, hint: 'the recovery climb applies only below the peak less this share. launch 1000' },
    { k: 'peakHalfLifeHours', t: 'range', label: 'peakHalfLife, hours', min: 0.5, max: 168, log: true, fmt: (v) => fmtN(v) + 'h', hint: 'the remembered peak halves in this time. launch 6' },
    { k: 'idleLoosenPct', t: 'range', label: 'idleLoosenBps', min: 0, max: 20, step: 0.5, fmt: (v) => Math.round(v * 100), hint: 'bps added to the ceiling anchor every 10 idle minutes. launch 200' },
    { k: 'rateCap', t: 'range', label: 'rateCap, wei per credit', min: 1.3e16, max: 1e18, log: true, fmt: fmtSci, hint: 'the eth rate never passes it. launch 2.67e16, 3 times rateStart. the page keeps it at or above rateStart' },
    { k: 'basefeeGwei', t: 'range', label: 'base fee of the buyback calls, gwei', min: 0.1, max: 200, log: true, fmt: (v) => fmtN(v) + ' gwei', hint: 'the buyback caller is paid 270,000 gas at min(base fee, keeperMaxBaseFee) plus keeperFee out of each slice, the buyListing caller 470,000 gas at the same rate plus keeperFee out of the pot, at most the gap to the bid' },
    { k: 'keeperFee', t: 'range', label: 'keeperFee, eth', min: 0, max: 0.005, step: 0.00025, fmt: (v) => v.toFixed(5), hint: 'paid to the buyback caller on top of the gas. launch 0.0005, at most 0.005' },
    { k: 'keeperMaxBaseFee', t: 'range', label: 'keeperMaxBaseFee, gwei', min: 1, max: 100, step: 1, fmt: (v) => v + ' gwei', hint: 'the base fee the gas refund stops at. launch 10' },
  ] },
  { title: 'change a setting on day N', open: true, ctl: [
    { k: 'chgOn', t: 'check', label: 'the owner changes one setting' },
    { k: 'chgDay', t: 'range', label: 'on day', min: 1, max: 89, step: 1, fmt: (v) => 'day ' + v },
    { k: 'chgKey', t: 'select', label: 'setting', opts: Object.keys(CHG).map((k) => [k, CHG[k].label]) },
    { k: 'chgValue', t: 'number', label: 'new value', hint: 'unit:', hintFn: (s) => CHG[s.chgKey].unit },
  ] },
  { title: 'the balance side: balanceModule and balanceToken', open: false, ctl: [
    { k: 'balanceOn', t: 'check', label: 'the balance side switched on' },
    { k: 'balanceDay', t: 'range', label: 'on day', min: 1, max: 89, step: 1, fmt: (v) => 'day ' + v, hint: 'the owner sets the balance module and the two switches that day. redeemOn is true and balanceBidOn is false at launch; the module is unset' },
    { k: 'balanceDayMode', t: 'select', label: 'switches that day', opts: [[1, 'redeemOn only: redemptions at the floor, no balance token bid'], [2, 'redeemOn and balanceBidOn: redemptions and the balance token bid']] },
    { k: 'xpPerPoint', t: 'range', label: 'balance token value per score point, eth', min: 2e-6, max: 3e-4, log: true, fmt: fmtSci, hint: 'unitPerPoint at the balance token price. a statement of 80 credits at 440 points redeems 35,200 times this', hintFn: (s) => (s.xpPerPoint * 35200).toFixed(2) + ' eth' },
    { k: 'balancePoolSet', t: 'check', label: 'balance token pool key set in the controller', hint: 'the pool term of valueOf joins the statement reference and the credit floor: rating times the unit at the pool price. the pool is native eth / balance token and initialized. unset at launch' },
    { k: 'balancePoolMult', t: 'range', label: 'balance token pool price against the unit', min: 0.1, max: 3, log: true, fmt: (v) => v.toFixed(2) + 'x', hint: 'values the pool term of valueOf. below 1 is a pool price pushed down' },
    { k: 'balanceBidMarginBps', t: 'range', label: 'balanceBidMarginBps', min: 0, max: 9000, step: 500, fmt: (v) => v, hint: 'the bid pays the redeemable value of a credit less this share, at the unit the module reports now. redeemSlippageBps follows it down when it is under 200. launch 2000' },
    { k: 'redeemBurnBps', t: 'range', label: 'redeemBurnBps', min: 0, max: 10000, step: 500, fmt: (v) => v, hint: 'share of the redeem burn reserve moved to buy and burn $CC by each redemption of a statement. launch 2000' },
  ] },
  { title: 'run', open: false, ctl: [
    { k: 'days', t: 'select', label: 'horizon', opts: [[30, '30 days'], [60, '60 days'], [90, '90 days'], [180, '180 days']] },
    { k: 'seed', t: 'number', label: 'seed' },
  ] },
];
GROUPS.splice(2, 0, { title: 'purchase budget and timing', open: true, ctl: [
  { k: 'spendCapBps', t: 'number', label: 'spendCapBps', hint: '1 to 10000. Launch 100: 1% of the bucket opening pot. 10000 bypasses enforcement. A cap can stall purchases and does not ensure convergence to market.' },
  { k: 'bucketSeconds', t: 'number', label: 'bucketSeconds', hint: '1 to 4294967295 seconds. Launch 60. Fixed boundaries can admit a budget on either side; active spend and drop floors survive owner edits.' },
  { k: 'balanceBidCapBps', t: 'number', label: 'balanceBidCapBps', hint: '10000 to 4294967295 bps of par. Launch 10000. Balance purchases are outside the ETH spend cap.' },
  { k: 'idleStepSeconds', t: 'number', label: 'idleStepSeconds', hint: '1 to 4294967295 seconds. Launch 600. Ordinary and recovery climb units stay at 60 seconds.' },
  { k: 'sniperSeconds', t: 'number', label: 'sniperSeconds', hint: '0 to 4294967295 seconds after token launch before the payee latch may activate. Launch 1800.' },
  { k: 'climbMultiplierCapBps', t: 'number', label: 'climbMultiplierCapBps', hint: '10000 to 65535 bps. Launch 40000. Last-fill pages scale ceiling loosening only.' },
  { k: 'anchorMoveBps', t: 'number', label: 'anchorMoveBps', hint: '0 to 10000 bps of the gap toward a qualifying statement sale. Launch 5000. Zero preserves the anchor clock.' },
  { k: 'stepSec', t: 'number', label: 'simulation step, seconds', hint: 'Must divide 3600. Default 60. Use 12 for modeled blocks throughout. Steps longer than a bucket skip spending opportunities. Smaller steps take longer.' },
] });
// Numeric inputs retain the supported range instead of clipping it to a narrow slider preset.
const WIDE_UNITS = {
  openPct: 'Opening bid as a percent of the modeled market price. Launch is derived from the configured rateStart.',
  markupBps: '10000 to 65535 bps, at least saleFloorBps and at most startCapBps.',
  startCapBps: 'markupBps to 4294967295 bps.', decayHours: '1 to 65535 hours.',
  saleFloorBps: '0 to 65535 bps, at most markupBps.',
  anchorHalfLifeDays: '1 second to 4294967295 seconds, entered in days.', anchorMinCost: '0 to uint128 max wei, entered in ETH. Number precision applies.',
  refScore: '1 to 4294967295 stored score units. 10000 units equal one point.',
  creditWindowHours: '1 to 4294967295 seconds, entered in hours.', creditFloorBps: '10000 to 65535 bps.', creditStartBps: '10000 to 4294967295 bps.',
  dropPerCreditPct: '0.01 to 100 percent, equivalent to 1 to 10000 bps.', dropToPct: '0 to 100 percent. The floor applies to each bucket opening bid.',
  climbPerMin: '0.01 to 655.35 percent per minute.', ceilPct: '100 to 655.35 percent of the ceiling anchor.',
  recoveryClimbPerMin: 'climbPerMin to 655.35 percent per minute.', recoveryGapPct: '0 to 100 percent below the remembered peak.',
  peakHalfLifeHours: '1 to 4294967295 seconds, entered in hours.', idleLoosenPct: '0.01 to 655.35 percent per idleStepSeconds.',
  rateCap: '1 to uint64 max wei per credit, at least rateStart. Number precision applies.',
  keeperFee: '0 to uint64 max wei, entered in ETH. The buyback reserve must still fit its slice.',
  keeperMaxBaseFee: '0 to uint48 max wei, entered in gwei. The buyback reserve must still fit its slice.',
  balanceBidMarginBps: '0 to 10000 bps below par. A zero opening floor stays zero until a reset gives it a positive floor.',
};
for (const group of GROUPS) for (const control of group.ctl) if (WIDE_UNITS[control.k]) {
  control.t = 'number'; control.hint = WIDE_UNITS[control.k]; delete control.hintFn;
  if (['dropPerCreditPct','dropToPct','climbPerMin','ceilPct','recoveryClimbPerMin','recoveryGapPct','idleLoosenPct'].includes(control.k)) control.label = control.k + ', percent';
}
// the asking price walk in plain words: where it starts at the launch anchor, where it stops and when it gets there
function walkText(s) {
  const floor = s.saleFloorBps, top = Math.max(Math.min(s.markupBps, s.startCapBps), floor);
  const head = (top / 100) + '% of the reference at listing (anchor 100%), ';
  return head + 'falling in a straight line to ' + (floor / 100) + '% at hour ' + Math.round(s.decayHours) + ', then resting there';
}
const rateOf = (s) => (s.openPct / 100) * (s.priceP0 * 1e18);
let state = Object.assign({}, BASE_STATE);
const widgets = {};
const toSlider = (c, v) => (c.log ? (Math.log(v / c.min) / Math.log(c.max / c.min)) * 1000 : v);
const fromSlider = (c, s) => {
  if (c.log) { const v = c.min * Math.pow(c.max / c.min, s / 1000); return +v.toPrecision(3); }
  return +s;
};
function buildControls() {
  const root = $('ctlRoot');
  for (const g of GROUPS) {
    const d = el('details', 'grp'); d.open = g.open;
    d.appendChild(el('summary', null, g.title));
    const rows = el('div', 'rows');
    for (const c of g.ctl) {
      const w = el('div', 'ctl'); w.id = 'row-' + c.k;
      const lab = el('label', null, c.label); lab.htmlFor = 'c-' + c.k; w.appendChild(lab);
      let inp;
      if (c.t === 'range') {
        inp = el('input'); inp.type = 'range';
        inp.min = c.log ? 0 : c.min; inp.max = c.log ? 1000 : c.max; inp.step = c.log ? 1 : c.step;
        const val = el('span', 'val'); val.id = 'v-' + c.k; w.appendChild(val); c.valEl = val;
      } else if (c.t === 'select') {
        inp = el('select');
        for (const [v, t] of c.opts) { const o = el('option', null, t); o.value = String(v); inp.appendChild(o); }
      } else if (c.t === 'check') {
        inp = el('input'); inp.type = 'checkbox'; inp.style.justifySelf = 'end';
      } else { inp = el('input'); inp.type = 'number'; inp.step = 'any'; }
      inp.id = 'c-' + c.k; w.appendChild(inp); c.inp = inp;
      if (c.hint) { const h = el('div', 'hint', c.hint); c.hintEl = h; w.appendChild(h); }
      const onChange = () => {
        if (c.t === 'range') state[c.k] = fromSlider(c, inp.value);
        else if (c.t === 'check') state[c.k] = inp.checked;
        else if (c.t === 'number') state[c.k] = c.k === 'seed' ? (+inp.value || 0) : (inp.value === '' ? 0 : +inp.value);
        else { const o = c.opts.find((x) => String(x[0]) === inp.value); state[c.k] = o ? o[0] : inp.value; }
        if (c.k === 'chgKey') { const ch = CHG[state.chgKey]; state.chgValue = ch.to; }
        syncControls(); schedule();
      };
      inp.addEventListener('input', onChange);
      if (c.t === 'select' || c.t === 'check') inp.addEventListener('change', onChange);
      rows.appendChild(w); widgets[c.k] = c;
    }
    d.appendChild(rows); root.appendChild(d);
  }
}
// push state into the widgets and show or hide the conditional ones
function syncControls() {
  for (const k of Object.keys(widgets)) {
    const c = widgets[k], v = state[k];
    if (c.t === 'range') { c.inp.value = toSlider(c, v); c.valEl.textContent = c.fmt(v); }
    else if (c.t === 'check') c.inp.checked = !!v;
    else if (document.activeElement !== c.inp) c.inp.value = String(v);
    if (c.only) $('row-' + k).style.display = state.volPreset === c.only ? '' : 'none';
    if (k === 'balanceDay' || k === 'balanceDayMode' || k === 'xpPerPoint' || k === 'balancePoolSet' || k === 'balancePoolMult' || k === 'balanceBidMarginBps') $('row-' + k).style.opacity = state.balanceOn ? 1 : 0.5;
    if (k === 'creditWindowHours' || k === 'creditFloorBps' || k === 'creditStartBps' || k === 'creditCostToPotBps' || k === 'creditBuyersPerDay' || k === 'creditWtpMult') $('row-' + k).style.opacity = state.creditSaleOn ? 1 : 0.5;
    if (k === 'composeChoice') $('row-' + k).style.opacity = state.chosenComposeOn ? 1 : 0.5;
    if (k === 'pauseDay' || k === 'pauseDays') $('row-' + k).style.opacity = state.pauseOn ? 1 : 0.5;
    if (k === 'chgDay' || k === 'chgKey' || k === 'chgValue') $('row-' + k).style.opacity = state.chgOn ? 1 : 0.5;
    if (c.hintFn) c.hintEl.innerHTML = c.hint + ' <b>' + c.hintFn(state) + '</b>';
  }
}
// the page state as the engine's parameters. settings carry the Core's names
function toParams(s) {
  const p = {
    ...DEFAULTS,
    volPreset: s.volPreset, volScale: s.volScale, volTail: s.volTail, volHalfLifeDays: s.volHalfLifeDays, buyShareLate: s.buyShareLate === 'auto' ? null : +s.buyShareLate,
    pricePath: s.pricePath, priceP0: s.priceP0, wtpMult: s.wtpMult, stmtPerDay: s.stmtPerDay, impactElast: s.impactElast, rateStart: rateOf(s),
    markupBps: s.markupBps, startCapBps: s.startCapBps, decayHours: Math.round(s.decayHours), saleFloorBps: s.saleFloorBps,
    basefeeGwei: s.basefeeGwei, keeperFee: s.keeperFee, keeperMaxBaseFee: s.keeperMaxBaseFee,
    buyerWaits: s.buyerWaits, feeToRedeemBurnBps: s.feeToRedeemBurnBps, saleToBuybackBps: s.saleToBuybackBps,
    anchorHalfLife: Math.round(s.anchorHalfLifeDays * 86400), anchorMinCost: s.anchorMinCost,
    dropPerCreditPct: s.dropPerCreditPct, dropToPct: s.dropToPct, climbPerMin: s.climbPerMin, ceilPct: s.ceilPct, idleLoosenPct: s.idleLoosenPct,
    recoveryClimbPerMin: s.recoveryClimbPerMin, recoveryGapPct: s.recoveryGapPct, peakHalfLifeHours: s.peakHalfLifeHours, // the Core needs the recovery climb at least the climb
    stepSec: s.stepSec,
    rateCap: s.rateCap, // the Core refuses a deploy with rateStart above rateCap
    creditSaleOn: !!s.creditSaleOn, creditWindow: Math.round(s.creditWindowHours * 3600), creditFloorBps: s.creditFloorBps, creditStartBps: s.creditStartBps, creditCostToPotBps: s.creditCostToPotBps, creditBuyersPerDay: s.creditBuyersPerDay, creditWtpMult: s.creditWtpMult,
    refScore: Math.round(s.refScore), chosenComposeOn: !!s.chosenComposeOn, composeChoice: s.composeChoice, balancePoolMult: s.balancePoolMult,
    balanceDay: s.balanceOn ? s.balanceDay : null, balanceDayMode: +s.balanceDayMode, xpPerPoint: s.xpPerPoint, balancePoolSet: !!s.balancePoolSet, balanceBidMarginBps: s.balanceBidMarginBps, redeemSlippageBps: s.redeemSlippageBps, redeemBurnBps: s.redeemBurnBps,
    spendCapBps: s.spendCapBps, bucketSeconds: s.bucketSeconds, balanceBidCapBps: s.balanceBidCapBps,
    idleStepSeconds: s.idleStepSeconds, sniperSeconds: s.sniperSeconds, climbMultiplierCapBps: s.climbMultiplierCapBps,
    anchorMoveBps: s.anchorMoveBps,
    days: +s.days, seed: s.seed,
  };
  const bad = firstViolation(p) || controllerViolation(p) || creditViolation(p) || (p.saleFloorBps > p.markupBps ? 'saleFloorBps' : null);
  if (bad) throw new Error('BadSetting ' + bad);
  if (!Number.isInteger(p.rateStart) || p.rateStart < 1 || p.rateStart > p.rateCap) throw new Error('BadRate');
  if (p.balanceDay != null && p.balanceDay >= p.days) p.balanceDay = null;
  p.schedule = [];
  if (s.chgOn && s.chgDay < p.days) {
    const ch = CHG[s.chgKey], patch = {};
    patch[s.chgKey] = s.chgValue;
    for (const k of ch.also || []) patch[k] = s.chgValue;
    p.schedule.push({ day: s.chgDay, patch });
  }
  if (s.pauseOn && s.pauseDay < p.days) {
    p.schedule.push({ day: s.pauseDay, patch: { paused: true } });
    if (s.pauseDay + s.pauseDays < p.days) p.schedule.push({ day: s.pauseDay + s.pauseDays, patch: { paused: false } });
  }
  return p;
}
