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
  saleFloorBps: { label: 'saleFloorBps (the one floor of a statement sale)', unit: 'bps of the price reference where the curve stops, and of cost in the Core. 1000 to 40000. launch 10000', to: 7500 },
  markupBps: { label: 'markupBps (start price over the anchor)', unit: 'bps, 10000 to 40000', to: 12000 },
  saleToBuybackBps: { label: 'saleToBuybackBps (sale proceeds to burn $CC)', unit: 'bps, 0 to 10000', to: 2500 },
  feeToRedeemBurnBps: { label: 'feeToRedeemBurnBps (fee share to the redeem burn reserve)', unit: 'bps, 0 to 10000. the rest of the fee eth goes to the pot', to: 2500 },
  redeemBurnBps: { label: 'redeemBurnBps (reserve share released by a redemption)', unit: 'bps, 0 to 10000', to: 5000 },
  redeemOn: { label: 'redeemOn (needs the balance side switched on to have an effect)', unit: '0 off, 1 on', to: 0 },
  balanceBidOn: { label: 'balanceBidOn (needs the balance side switched on to have an effect)', unit: '0 off, 1 on', to: 0 },
  royaltyBps: { label: 'royaltyBps (royalty on top of every sale price)', unit: 'bps, 0 to 1000. launch 250', to: 500 },
  balanceBidMarginBps: { label: 'balanceBidMarginBps (margin under the redeemable value)', unit: 'bps, 200 to 9000 (at least redeemSlippageBps, 200 at launch)', to: 4000 },
  moduleUnit: { label: 'balance module reports a new unitPerPoint (the Core and the controller read it at every use)', unit: 'eth per score point', to: 1e-5 },
  releaseRedeemBurn: { label: 'owner calls releaseRedeemBurn (reserve to the buyback pot)', unit: 'eth, capped at the reserve', to: 1 },
  rateCap: { label: 'rateCap (most the eth rate can be)', unit: 'wei per credit, 1e13 to 1e18', to: 2.2e16 },
  creditSaleOn: { label: 'creditSaleOn (the credit sale window)', unit: '0 off, 1 on. off at launch', to: 1 },
  creditFloorBps: { label: 'creditFloorBps (credit sale floor over the larger of cost and valueOf(score))', unit: 'bps, 10000 to 40000. launch 11000', to: 13000 },
  creditStartBps: { label: 'creditStartBps (credit sale start price over the floor)', unit: 'bps, 10000 to 200000. launch 30000', to: 20000 },
  refScore: { label: 'refScore (per-credit score of the statement price reference)', unit: 'ten-thousandths of a point, 1 to 8000000. launch 4330000, 433 points', to: 3500000 },
};
// every control: key in the state object, how to show it. launch values are the Core's (script/config/mainnet.json)
const BASE_STATE = { volPreset: 'comparable', volScale: 1, volTail: 17, volHalfLifeDays: 3, buyShareLate: 'auto', pricePath: 'flat', priceP0: 0.0089, wtpMult: 1, stmtPerDay: 8, buyerWaits: 'no', impactElast: 0.12,
  openPct: 100, markupBps: 15000, startCapBps: 100000, fastBpsH: 100, kneeBps: 10000, slowBpsH: 25, saleFloorBps: 10000, saleToBuybackBps: 5000, feeToRedeemBurnBps: 1000, royaltyBps: 250, anchorHalfLifeDays: 7, anchorMinCost: 0.1, dropPerCreditPct: 0.5, dropToPct: 50, climbPerMin: 0.5, ceilPct: 110, idleLoosenPct: 2, recoveryClimbPerMin: 2, recoveryGapPct: 10, peakHalfLifeHours: 6, rateCap: 26700000000000000,
  basefeeGwei: 1, keeperFee: 0.0005, keeperMaxBaseFee: 10,
  pauseOn: false, pauseDay: 20, pauseDays: 7,
  creditSaleOn: false, creditWindowHours: 4, creditFloorBps: 11000, creditStartBps: 30000, creditCostToPotBps: 10000, creditBuyersPerDay: 40, creditWtpMult: 1, refScore: 4330000, chosenComposeOn: false, composeChoice: 'oldest', balancePoolMult: 1,
  chgOn: false, chgDay: 30, chgKey: 'saleToBuybackBps', chgValue: 7500,
  balanceOn: false, balanceDay: 14, balanceDayMode: 2, xpPerPoint: 0.0108 / 440, balancePoolSet: false, balanceBidMarginBps: 2000, redeemBurnBps: 2000, days: 90, seed: 7 };
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
    { k: 'fastBpsH', t: 'range', label: 'fast fall, bps of the reference an hour (fastDecayBpsPerHour)', min: 10, max: 2000, log: true, fmt: (v) => Math.round(v), hint: 'asking price walk:', hintFn: (s) => walkText(s) },
    { k: 'kneeBps', t: 'range', label: 'knee, where the fast fall ends (kneeBps)', min: 2000, max: 100000, step: 500, fmt: (v) => v / 100 + '%', hint: 'a start at or below the knee falls at the slow rate from the first second' },
    { k: 'slowBpsH', t: 'range', label: 'slow fall, bps of the reference an hour (slowDecayBpsPerHour)', min: 5, max: 1000, log: true, fmt: (v) => Math.round(v), hint: 'the rate below the knee, down to the floor' },
    { k: 'saleFloorBps', t: 'range', label: 'floor of the asking price, set in the Core (saleFloorBps)', min: 1000, max: 12000, step: 500, fmt: (v) => v / 100 + '%', hint: 'the price falls to here, in percent of the price reference, and stops. the Core takes no sale under this share of cost either. launch 10000: unsold statements sit at their reference, and redeem once redeemOn allows' },
    { k: 'saleToBuybackBps', t: 'range', label: 'saleToBuybackBps, sale proceeds to burn $CC', min: 0, max: 10000, step: 500, fmt: (v) => v, hint: 'share of sale proceeds that buys and burns $CC, the rest goes to the pot' },
    { k: 'feeToRedeemBurnBps', t: 'range', label: 'feeToRedeemBurnBps, fee share to the redeem burn reserve', min: 0, max: 10000, step: 500, fmt: (v) => v, hint: 'share of $CC swap fee eth held back for redemptions. each redemption of a held statement moves redeemBurnBps of the reserve to buy and burn $CC. launch 1000. the rest goes to the pot' },
    { k: 'royaltyBps', t: 'range', label: 'royaltyBps, royalty on top of every sale', min: 0, max: 1000, step: 50, fmt: (v) => v, hint: 'the buyer pays the price and this share of it on top. the engine books the price only, the royalty is owed to the recipient. launch 250' },
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
    { k: 'creditSaleOn', t: 'check', label: 'pile credits are for sale from their acquisition time', hint: 'off at launch. compose waits for a credit to pass its window while this is on' },
    { k: 'creditWindowHours', t: 'range', label: 'creditWindow, hours', min: 0.1, max: 720, log: true, fmt: (v) => fmtN(v) + 'h', hint: 'the price falls over this time and rests at the floor. launch 4' },
    { k: 'creditFloorBps', t: 'range', label: 'creditFloorBps', min: 10000, max: 40000, step: 500, fmt: (v) => v, hint: 'the floor is the highest of the credit cost, its balance token baseline and the eth bid, times this. launch 11000' },
    { k: 'creditStartBps', t: 'range', label: 'creditStartBps', min: 10000, max: 200000, step: 5000, fmt: (v) => v, hint: 'the start price is the floor times this. launch 30000' },
    { k: 'creditCostToPotBps', t: 'range', label: 'creditCostToPotBps', min: 0, max: 10000, step: 500, fmt: (v) => v, hint: 'share of a sold credit cost that returns to the pot, the rest of the payment buys and burns $CC. launch 10000' },
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
    { k: 'balanceDay', t: 'range', label: 'on day', min: 1, max: 89, step: 1, fmt: (v) => 'day ' + v, hint: 'the owner sets the balance module and the two switches that day. both are false at launch: unsold statements sit at their reference and nothing redeems' },
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
// the asking price walk in plain words: where it starts at the launch anchor, where it stops and when it gets there
function walkText(s) {
  const fast = Math.round(s.fastBpsH), slow = Math.round(s.slowBpsH), knee = s.kneeBps;
  const floor = s.saleFloorBps, top = Math.max(Math.min(s.markupBps, s.startCapBps), floor);
  const hrs = (x) => (+x).toFixed(x < 10 ? 1 : 0) + 'h';
  const head = (top / 100) + '% of the reference at listing (anchor 100%), ';
  if (floor >= knee) return head + (floor / 100) + '% at hour ' + hrs(Math.max(0, top - floor) / fast);
  const tKnee = Math.max(0, top - knee) / fast;
  return head + (top > knee ? (knee / 100) + '% at hour ' + hrs(tKnee) + ', ' : '') + (floor / 100) + '% at hour ' + hrs(tKnee + (Math.min(top, knee) - floor) / slow);
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
    volPreset: s.volPreset, volScale: s.volScale, volTail: s.volTail, volHalfLifeDays: s.volHalfLifeDays, buyShareLate: s.buyShareLate === 'auto' ? null : +s.buyShareLate,
    pricePath: s.pricePath, priceP0: s.priceP0, wtpMult: s.wtpMult, stmtPerDay: s.stmtPerDay, impactElast: s.impactElast, rateStart: rateOf(s),
    markupBps: s.markupBps, startCapBps: Math.max(s.startCapBps, s.markupBps), fastDecayBpsPerHour: Math.round(s.fastBpsH), kneeBps: Math.min(Math.max(s.kneeBps, 1000), Math.max(s.startCapBps, s.markupBps)), slowDecayBpsPerHour: Math.round(s.slowBpsH), saleFloorBps: s.saleFloorBps,
    basefeeGwei: s.basefeeGwei, keeperFee: s.keeperFee, keeperMaxBaseFee: s.keeperMaxBaseFee,
    buyerWaits: s.buyerWaits, feeToRedeemBurnBps: s.feeToRedeemBurnBps, saleToBuybackBps: s.saleToBuybackBps, royaltyBps: s.royaltyBps,
    anchorHalfLife: Math.round(s.anchorHalfLifeDays * 86400), anchorMinCost: s.anchorMinCost,
    dropPerCreditPct: s.dropPerCreditPct, dropToPct: s.dropToPct, climbPerMin: s.climbPerMin, ceilPct: s.ceilPct, idleLoosenPct: s.idleLoosenPct,
    recoveryClimbPerMin: Math.max(s.recoveryClimbPerMin, s.climbPerMin), recoveryGapPct: s.recoveryGapPct, peakHalfLifeHours: s.peakHalfLifeHours, // the Core needs the recovery climb at least the climb
    stepSec: 300, // 5 minute steps keep a live page responsive: credits within 6 percent of the 60 second steps (30 day runs, seeds 1 to 5)
    rateCap: Math.max(s.rateCap, rateOf(s)), // the Core refuses a deploy with rateStart above rateCap
    creditSaleOn: !!s.creditSaleOn, creditWindow: Math.max(60, Math.round(s.creditWindowHours * 3600)), creditFloorBps: s.creditFloorBps, creditStartBps: s.creditStartBps, creditCostToPotBps: s.creditCostToPotBps, creditBuyersPerDay: s.creditBuyersPerDay, creditWtpMult: s.creditWtpMult,
    refScore: Math.round(s.refScore), chosenComposeOn: !!s.chosenComposeOn, composeChoice: s.composeChoice, balancePoolMult: s.balancePoolMult,
    balanceDay: s.balanceOn ? s.balanceDay : null, balanceDayMode: +s.balanceDayMode, xpPerPoint: s.xpPerPoint, balancePoolSet: !!s.balancePoolSet, balanceBidMarginBps: s.balanceBidMarginBps, redeemSlippageBps: Math.min(200, s.balanceBidMarginBps), redeemBurnBps: s.redeemBurnBps,
    days: +s.days, seed: s.seed,
  };
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
