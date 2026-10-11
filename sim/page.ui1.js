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
  floorBps: { label: 'lowest price (floorBps and saleFloorBps together)', unit: 'bps of cost, 1000 to 10000, 1000 to 40000 for saleFloorBps', to: 6000, also: ['saleFloorBps'] },
  markupBps: { label: 'markupBps (start price over the anchor)', unit: 'bps, 10000 to 40000', to: 12000 },
  feeToBuybackBps: { label: 'feeToBuybackBps (fee share to burn $CC)', unit: 'bps, 0 to 10000', to: 2500 },
  saleToBuybackBps: { label: 'saleToBuybackBps (sale proceeds to burn $CC)', unit: 'bps, 0 to 10000', to: 2500 },
  exitAfter: { label: 'exitAfter', unit: 'hours, 1 to 8760', to: 24, hours: true },
  rateCap: { label: 'rateCap (most the eth rate can be)', unit: 'wei per credit, 1e13 to 1e18', to: 2.2e16 },
};
// every control: key in the state object, how to show it. launch values are the Core's (script/config/mainnet.json)
const BASE_STATE = { volPreset: 'comparable', volScale: 1, volTail: 17, volHalfLifeDays: 3, buyShareLate: 'auto', pricePath: 'flat', priceP0: 0.0089, wtpMult: 1, stmtPerDay: 8, buyerWaits: 'no', impactElast: 0.12,
  openPct: 100, markupBps: 15000, startCapBps: 100000, fastBpsH: 100, kneeBps: 10000, slowBpsH: 25, floorBps: 7500, saleFloorBps: 7500, saleToBuybackBps: 5000, feeToBuybackBps: 0, exitAfterH: 105, dropPerCreditPct: 0.5, dropToPct: 50, climbPerMin: 0.5, ceilPct: 110, idleLoosenPct: 2, rateCap: 26700000000000000, fundedRule: 'built',
  basefeeGwei: 1, keeperFee: 0.0005, buybackMaxBaseFee: 10,
  chgOn: false, chgDay: 30, chgKey: 'saleToBuybackBps', chgValue: 7500,
  phase2On: false, phase2Day: 14, xp: 0.0108, takerThreshold: 0.15, days: 90, seed: 7 };
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
    { k: 'exitAfterH', t: 'range', label: 'exitAfter, hours', min: 3, max: 336, step: 3, fmt: (v) => v + 'h', hint: 'a statement may exit in phase 2 after this long in the Core. 150 hours is when a 150% start reaches the 75% floor at launch settings' },
  ] },
  { title: 'selling statements', open: true, ctl: [
    { k: 'markupBps', t: 'range', label: 'start price over the anchor (markupBps)', min: 10000, max: 40000, step: 500, fmt: (v) => v / 100 + '%', hint: 'asking price when a statement is listed, as a share of the anchor, the running level of sale prices (100% of cost at launch, each sale moves it halfway to the price paid, never below 100%)' },
    { k: 'startCapBps', t: 'range', label: 'cap on the start price (startCapBps)', min: 15000, max: 200000, step: 5000, fmt: (v) => v / 100 + '%', hint: 'the start price never passes this share of cost, whatever the anchor' },
    { k: 'fastBpsH', t: 'range', label: 'fast fall, bps of cost an hour (fastDecayBpsPerHour)', min: 10, max: 2000, log: true, fmt: (v) => Math.round(v), hint: 'asking price walk:', hintFn: (s) => walkText(s) },
    { k: 'kneeBps', t: 'range', label: 'knee, where the fast fall ends (kneeBps)', min: 2000, max: 100000, step: 500, fmt: (v) => v / 100 + '%', hint: 'a start at or below the knee falls at the slow rate from the first second' },
    { k: 'slowBpsH', t: 'range', label: 'slow fall, bps of cost an hour (slowDecayBpsPerHour)', min: 5, max: 1000, log: true, fmt: (v) => Math.round(v), hint: 'the rate below the knee, down to the floor' },
    { k: 'floorBps', t: 'range', label: 'floor of the asking price (floorBps)', min: 2000, max: 10000, step: 500, fmt: (v) => v / 100 + '%', hint: 'the price falls to here and stops. at most the knee' },
    { k: 'saleFloorBps', t: 'range', label: 'hard floor, set in the Core (saleFloorBps)', min: 1000, max: 12000, step: 500, fmt: (v) => v / 100 + '%', hint: 'no sale ever goes under this share of cost, even if the floor above is lower' },
    { k: 'saleToBuybackBps', t: 'range', label: 'saleToBuybackBps, sale proceeds to burn $CC', min: 0, max: 10000, step: 500, fmt: (v) => v, hint: 'share of sale proceeds that buys and burns $CC, the rest goes to the pot' },
    { k: 'feeToBuybackBps', t: 'range', label: 'feeToBuybackBps, fee share to burn $CC', min: 0, max: 10000, step: 500, fmt: (v) => v, hint: 'share of $CC swap fee eth that buys and burns $CC instead of going to the pot' },
  ] },
  { title: 'engine settings', open: false, ctl: [
    { k: 'dropPerCreditPct', t: 'range', label: 'dropPerCreditBps', min: 0.1, max: 5, log: true, fmt: (v) => Math.round(v * 100), hint: 'bps the bid falls after each credit bought. launch 50' },
    { k: 'dropToPct', t: 'range', label: 'dropFloorBps', min: 50, max: 99, step: 1, fmt: (v) => v * 100, hint: 'within one minute the bid stays at or above this share of the rate at the first fill. launch 5000' },
    { k: 'climbPerMin', t: 'range', label: 'climbPerMinBps', min: 0.1, max: 3, log: true, fmt: (v) => Math.round(v * 100), hint: 'bps the bid climbs each minute. launch 50' },
    { k: 'ceilPct', t: 'range', label: 'ceilBps', min: 101, max: 300, step: 1, fmt: (v) => v * 100, hint: 'the bid never climbs above this share of the last fill rate. launch 11000' },
    { k: 'idleLoosenPct', t: 'range', label: 'idleLoosenBps', min: 0, max: 20, step: 0.5, fmt: (v) => Math.round(v * 100), hint: 'bps added to the ceiling anchor every 10 idle minutes. launch 200' },
    { k: 'rateCap', t: 'range', label: 'rateCap, wei per credit', min: 1.3e16, max: 1e18, log: true, fmt: fmtSci, hint: 'the eth rate never passes it. launch 2.67e16, 3 times rateStart. the page keeps it at or above rateStart' },
    { k: 'basefeeGwei', t: 'range', label: 'base fee of the buyback calls, gwei', min: 0.1, max: 200, log: true, fmt: (v) => fmtN(v) + ' gwei', hint: 'the caller is paid 270,000 gas at min(base fee, buybackMaxBaseFee) plus keeperFee out of each slice' },
    { k: 'keeperFee', t: 'range', label: 'keeperFee, eth', min: 0, max: 0.005, step: 0.00025, fmt: (v) => v.toFixed(5), hint: 'paid to the buyback caller on top of the gas. launch 0.0005, at most 0.005' },
    { k: 'buybackMaxBaseFee', t: 'range', label: 'buybackMaxBaseFee, gwei', min: 1, max: 100, step: 1, fmt: (v) => v + ' gwei', hint: 'the base fee the gas refund stops at. launch 10' },
  ] },
  { title: 'change a setting on day N', open: true, ctl: [
    { k: 'chgOn', t: 'check', label: 'the owner changes one setting' },
    { k: 'chgDay', t: 'range', label: 'on day', min: 1, max: 89, step: 1, fmt: (v) => 'day ' + v },
    { k: 'chgKey', t: 'select', label: 'setting', opts: Object.keys(CHG).map((k) => [k, CHG[k].label]) },
    { k: 'chgValue', t: 'number', label: 'new value', hint: 'unit:', hintFn: (s) => CHG[s.chgKey].unit },
  ] },
  { title: 'phase 2: exitModule and exitToken', open: false, ctl: [
    { k: 'phase2On', t: 'check', label: 'phase 2 switched on' },
    { k: 'phase2Day', t: 'range', label: 'on day', min: 1, max: 89, step: 1, fmt: (v) => 'day ' + v },
    { k: 'xp', t: 'range', label: 'exitToken price, eth per credit', min: 8e-4, max: 0.13, log: true, fmt: fmtSci, hint: 'a statement of 80 credits pays 80 times this, about 0.9 eth at 0.0108' },
    { k: 'takerThreshold', t: 'range', label: 'exitToken auction taker discount', min: 0.02, max: 0.4, step: 0.01, fmt: (v) => (v * 100).toFixed(0) + '%', hint: 'discount to the pool price, skim included, that triggers a fill' },
  ] },
  { title: 'run', open: false, ctl: [
    { k: 'days', t: 'select', label: 'horizon', opts: [[30, '30 days'], [60, '60 days'], [90, '90 days'], [180, '180 days']] },
    { k: 'seed', t: 'number', label: 'seed' },
  ] },
];
// the asking price walk in plain words: where it starts at the launch anchor, where it stops and when it gets there
function walkText(s) {
  const fast = Math.round(s.fastBpsH), slow = Math.round(s.slowBpsH), knee = s.kneeBps;
  const floor = Math.max(s.floorBps, s.saleFloorBps), top = Math.max(Math.min(s.markupBps, s.startCapBps), floor);
  const hrs = (x) => (+x).toFixed(x < 10 ? 1 : 0) + 'h';
  const head = (top / 100) + '% of cost at listing (anchor 100%), ';
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
    if (k === 'phase2Day' || k === 'xp' || k === 'takerThreshold') $('row-' + k).style.opacity = state.phase2On ? 1 : 0.5;
    if (k === 'chgDay' || k === 'chgKey' || k === 'chgValue') $('row-' + k).style.opacity = state.chgOn ? 1 : 0.5;
    if (c.hintFn) c.hintEl.innerHTML = c.hint + ' <b>' + c.hintFn(state) + '</b>';
  }
}
// the page state as the engine's parameters. settings carry the Core's names
function toParams(s) {
  const p = {
    volPreset: s.volPreset, volScale: s.volScale, volTail: s.volTail, volHalfLifeDays: s.volHalfLifeDays, buyShareLate: s.buyShareLate === 'auto' ? null : +s.buyShareLate,
    pricePath: s.pricePath, priceP0: s.priceP0, wtpMult: s.wtpMult, stmtPerDay: s.stmtPerDay, impactElast: s.impactElast, rateStart: rateOf(s),
    markupBps: s.markupBps, startCapBps: Math.max(s.startCapBps, s.markupBps), fastDecayBpsPerHour: Math.round(s.fastBpsH), kneeBps: Math.min(Math.max(s.kneeBps, s.floorBps), Math.max(s.startCapBps, s.markupBps)), slowDecayBpsPerHour: Math.round(s.slowBpsH), floorBps: s.floorBps, saleFloorBps: s.saleFloorBps,
    basefeeGwei: s.basefeeGwei, keeperFee: s.keeperFee, buybackMaxBaseFee: s.buybackMaxBaseFee,
    buyerWaits: s.buyerWaits, feeToBuybackBps: s.feeToBuybackBps, saleToBuybackBps: s.saleToBuybackBps, exitAfter: s.exitAfterH * 3600,
    bidRule: 'stepped', dropPerCreditPct: s.dropPerCreditPct, dropToPct: s.dropToPct, climbPerMin: s.climbPerMin, ceilPct: s.ceilPct, idleLoosenPct: s.idleLoosenPct,
    stepSec: 300, // 5 minute steps keep a live page responsive, credits within 1 percent of the 60 second steps of the batches
    rateCap: Math.max(s.rateCap, rateOf(s)), // the Core refuses a deploy with rateStart above rateCap
    phase2Day: s.phase2On ? s.phase2Day : null, xp: s.xp, takerThreshold: s.takerThreshold, days: +s.days, seed: s.seed,
  };
  if (p.phase2Day != null && p.phase2Day >= p.days) p.phase2Day = null;
  p.schedule = [];
  if (s.chgOn && s.chgDay < p.days) {
    const ch = CHG[s.chgKey], patch = {};
    patch[s.chgKey] = ch.hours ? Math.round(s.chgValue * 3600) : s.chgValue;
    for (const k of ch.also || []) patch[k] = s.chgValue;
    p.schedule.push({ day: s.chgDay, patch });
  }
  return p;
}
