// ================================================================= page: charts, verdict, table
const markX = () => {
  const p = toParams(state), out = [];
  if (p.balanceDay != null) out.push({ x: p.balanceDay, label: 'the balance side' });
  for (const e of p.schedule) out.push({ x: e.day, label: Object.keys(e.patch)[0] });
  return out;
};
const CHART_SPECS = [
  { id: 'pot', title: 'eth pot, cumulative fees, eth in statements not yet sold', fmt: { l: fmtAx }, marks: markX, series: [
    { label: 'eth pot', short: 'pot', color: '--s1', f: (r, h) => r.S.pot[h] },
    { label: 'cumulative fees', short: 'fees', color: '--s4', dash: true, f: (r, h) => r.S.cumFees[h] },
    { label: 'cost of statements not sold', short: 'unsold', color: '--s2', f: (r, h) => r.S.locked[h] } ] },
  { id: 'rate', title: 'bid rate against market rate, wei per point, and the bid for a 440 point credit as percent of market', fmt: { l: fmtSci, r: (v) => v.toFixed(0) + '%' }, log: { l: true }, fixed: { r: [0, 200] }, marks: markX, series: [
    { label: 'bid rate', short: 'bid', color: '--s1', f: (r, h) => r.S.rate[h] },
    { label: 'market price over 440 points', short: 'market', color: '--s4', dash: true, f: (r, h) => r.S.mktPerPoint[h] },
    { label: 'bid as percent of market', short: 'bid%', color: '--s2', axis: 'r', f: (r, h) => r.S.bidRatio[h] * 100 } ] },
  { id: 'credits', title: 'credits acquired, total and per day', fmt: { l: fmtAx, r: fmtAx }, marks: markX, series: [
    { label: 'credits acquired', short: 'total', color: '--s1', f: (r, h) => r.S.credits[h] },
    { label: 'credits per day (last 24h)', short: 'per day', color: '--s2', axis: 'r', f: (r, h) => r.S.creditsDay[h] } ] },
  { id: 'price', title: 'price paid per credit against the market, eth, and average score bought', fmt: { l: (v) => v.toFixed(4), r: (v) => v.toFixed(0) }, fixed: { r: [0, 800] }, marks: markX, series: [
    { label: 'paid per credit, cumulative', short: 'paid', color: '--s1', f: (r, h) => r.S.costPerCredit[h] || NaN },
    { label: 'market price of a credit', short: 'market', color: '--s4', dash: true, f: (r, h) => r.S.mktPerCredit[h] },
    { label: 'average score, last 24h', short: 'score', color: '--s2', axis: 'r', f: (r, h) => (r.S.avgScoreDay[h] || NaN) } ] },
  { id: 'stmts', title: 'statements created, sold, waiting, redeemed', fmt: { l: fmtAx }, marks: markX, series: [
    { label: 'created and listed', short: 'created', color: '--s4', dash: true, f: (r, h) => r.S.composed[h] },
    { label: 'sold', short: 'sold', color: '--s3', f: (r, h) => r.S.sold[h] },
    { label: 'waiting for a buyer or a redemption', short: 'waiting', color: '--s2', f: (r, h) => r.S.waiting[h] },
    { label: 'redeemed through the balanceModule', short: 'redeemed', color: '--s1', f: (r, h) => r.S.redeemed[h] } ] },
  { id: 'pile', title: 'the credit pile, and pile credits sold through the credit sale window', fmt: { l: fmtAx, r: fmtAx }, marks: markX, series: [
    { label: 'credits in the pile', short: 'pile', color: '--s2', f: (r, h) => r.S.pile[h] },
    { label: 'pile credits sold, cumulative', short: 'sold', color: '--s3', axis: 'r', f: (r, h) => r.S.creditSold[h] } ] },
  { id: 'saleprice', title: 'statements: average sale price as percent of cost, and hours from listing to the first buyer', fmt: { l: (v) => v.toFixed(0) + '%', r: fmtAx }, fixed: { l: [0, 120] }, marks: markX, series: [
    { label: 'average sale price, percent of what the engine paid', short: 'price', color: '--s1', f: (r, h) => r.S.avgSalePct[h] },
    { label: 'average hours from listing to the first buyer', short: 'hours', color: '--s2', axis: 'r', f: (r, h) => r.S.avgSaleAgeH[h] } ] },
  { id: 'burn', title: 'eth sent to buy and burn $CC: from sales, from fees and from the redeem burn reserve, eth spent, and $CC burned', fmt: { l: fmtAx, r: (v) => v.toFixed(1) + '%' }, marks: markX, series: [
    { label: 'eth to burn from sale proceeds', short: 'from sales', color: '--s3', f: (r, h) => r.S.saleToBuyback[h] },
    { label: 'eth to burn from fees', short: 'from fees', color: '--s4', dash: true, f: (r, h) => r.S.feeToBuyback[h] },
    { label: 'eth released by redemptions from the reserve', short: 'from reserve', color: '--s5', f: (r, h) => r.S.redeemBurnMoved[h] },
    { label: 'eth from credit sales', short: 'from credits', color: '--s3', dash: true, f: (r, h) => r.S.creditToBuyback[h] },
    { label: 'eth spent buying $CC', short: 'spent', color: '--s1', f: (r, h) => r.S.burnEth[h] },
    { label: '$CC burned, percent of supply', short: 'burned', color: '--s2', axis: 'r', f: (r, h) => r.S.burnedPct[h] } ] },
  { id: 'coin', title: '$CC price, eth per coin', fmt: { l: fmtSci }, log: { l: true }, marks: markX, series: [
    { label: 'pool price', short: 'price', color: '--s1', f: (r, h) => r.S.coinPrice[h] } ] },
  { id: 'x', title: 'the balance side: balance token pot and redeem burn reserve, eth', fmt: { l: fmtAx }, marks: markX, series: [
    { label: 'balance token pot (eth value)', short: 'balancePot', color: '--s3', f: (r, h) => r.S.balancePot[h] },
    { label: 'redeem burn reserve', short: 'reserve', color: '--s2', dash: true, f: (r, h) => r.S.redeemBurn[h] },
    { label: 'filled from fees, cumulative', short: 'filled', color: '--s4', dash: true, f: (r, h) => r.S.feeToRedeemBurn[h] } ] },
];
let lastRes = null;
function renderVerdict(res, ms) {
  const p = res.params, days = res.H / 24, sm = summary(res), st = res.stats;
  const last7 = (res.S.credits[res.H] - res.S.credits[Math.max(0, res.H - 168)]) / 7;
  const flowing = last7 >= 1;
  // credits keep flowing in unless the last week bought nothing. unsold statements are fine, they wait for the balance side
  $('verdict').className = 'verdict ' + (!flowing ? 'bad' : sm.steadyCredits != null && sm.steadyCredits < 50 ? 'warn' : 'good');
  $('v1').textContent = 'day ' + days + ': ' + fmtN(sm.credits) + ' credits acquired, ' + fmtN(sm.statements) + ' statements created, ' + fmtN(sm.sold) + ' sold at ' + (st.saleOverCost * 100).toFixed(0) + '% of cost on average, ' + fmtN(sm.waiting) + ' still waiting, ' + fmtN(sm.burnEth) + ' eth to buy and burn $CC (' + sm.burnPct.toFixed(1) + '% of supply), launch pot spent ' + (sm.potGoneDay == null ? 'not within ' + days + ' days' : 'by day ' + sm.potGoneDay.toFixed(1)) + '';
  const steady = sm.steadyCredits == null ? '' : ' after the pot ran out: ' + fmtN(sm.steadyCredits) + ' credits and ' + fmtN(sm.steadyStatements) + ' statements a day.';
  $('v2').textContent = 'fees in ' + fmtN(res.S.cumFees[res.H]) + ' eth (' + fmtN(res.core.feeToRedeemBurn) + ' to the redeem burn reserve). credits cost ' + st.costVsMarket.toFixed(2) + 'x the flat market price, average score ' + st.avgScoreBought.toFixed(0) + '. ' + 'burn from sale proceeds ' + fmtN(sm.saleToBurn) + ' eth, from fees ' + fmtN(sm.feeToBurn) + ' eth.' + ' the anchor ended at ' + (st.finalAnchorBps / 100).toFixed(0) + '% of the reference.' + steady + (!flowing ? ' no credit was bought in the last week.' : '');
  $('runinfo').textContent = 'ran ' + Math.round(ms) + ' ms, ' + res.H + ' hours, seed ' + p.seed;
}
function renderTable(res) {
  const days = res.H / 24, ds = [1, 3, 7, 14, 30, 60, 90, 180].filter((d) => d <= days);
  if (!ds.length || ds[ds.length - 1] !== days) ds.push(days);
  const cols = [['day', (a) => a.day], ['credits acquired', (a) => fmtN(a.credits)], ['statements created', (a) => fmtN(a.composed)], ['sold', (a) => fmtN(a.sold)],
    ['waiting', (a) => fmtN(a.waiting)], ['redeemed', (a) => fmtN(a.redeemed)], ['average sale price, percent of cost', (a) => (isNaN(a.avgSalePct) ? 'n/a' : a.avgSalePct.toFixed(0) + '%')],
    ['eth to burn from sales', (a) => fmtN(a.saleToBuyback)], ['eth to burn from fees', (a) => fmtN(a.feeToBuyback)], ['eth spent buying $CC', (a) => fmtN(a.burnEth)],
    ['percent of supply burned', (a) => a.burnedPct.toFixed(2) + '%'], ['fees in, eth', (a) => fmtN(a.cumFees)], ['pot now, eth', (a) => fmtN(a.pot)]];
  let h = '<thead><tr>' + cols.map((c) => '<th>' + c[0] + '</th>').join('') + '</tr></thead><tbody>';
  for (const d of ds) { const a = res.at(d); h += '<tr>' + cols.map((c) => '<td>' + c[1](a) + '</td>').join('') + '</tr>'; }
  $('tbl').innerHTML = h + '</tbody>';
  const st = res.stats, T = res.T;
  const notes = [
    '<b>cost per credit</b> ' + st.costVsMarket.toFixed(2) + 'x the flat price, ' + st.costVsAsk.toFixed(2) + 'x what sellers asked',
    '<b>first fill</b> hour ' + (st.firstFillHour < 0 ? 'none' : st.firstFillHour.toFixed(1)) + (st.first80 ? ', first 80 credits cost ' + st.first80.ratio.toFixed(2) + 'x market at score ' + st.first80.avgScore.toFixed(0) : ''),
    '<b>statement sales</b> ' + (T.sold ? fmtN(T.sold) + ' sold, the first buyer came ' + st.saleAgeHours.toFixed(0) + ' hours after listing on average, ' + (st.saleAtFloorShare * 100).toFixed(0) + '% sold at the lowest price, ' + (st.saleOverFloor * 100 - 100).toFixed(0) + '% over the hard floor on average' : 'none sold'),
    '<b>climb clamp</b> active ' + fmtN(st.clampSteps) + ' hours',
  ];
  if (T.settingsChanges) notes.push('<b>setting changes</b> applied on day ' + p0().schedule.map((e) => e.day).join(', '));
  if (res.core.ethRedeemBurn + res.core.redeemBurnMoved > 0) notes.push('<b>redeem burn reserve</b> ' + fmtN(res.core.feeToRedeemBurn) + ' eth filled from fees, ' + fmtN(res.core.redeemBurnMoved) + ' eth released to buy and burn $CC by redemptions, ' + fmtN(res.core.ethRedeemBurn) + ' eth still held');
  if (T.boughtX || T.redeemed) notes.push('<b>the balance side</b> ' + fmtN(T.redeemed) + ' statements redeemed' + (T.redeemed ? ' after ' + (T.redeemedAge / T.redeemed / 3600).toFixed(0) + ' hours on average' : '') + ', balance token bid bought ' + fmtN(T.boughtX) + ' credits into the one pile, ' + fmtN(res.core.balancePot) + ' eth of balance token held');
  if (T.creditSold || T.creditMiss) notes.push('<b>credit sale window</b> ' + fmtN(T.creditSold) + ' pile credits sold at ' + (T.creditCost ? (T.creditGross / T.creditCost * 100).toFixed(0) : 'n/a') + '% of their cost' + (T.creditSold ? ', ' + st.creditSaleAgeHours.toFixed(1) + ' hours after acquisition on average' : '') + ', ' + fmtN(T.creditToPot) + ' eth back to the pot, ' + fmtN(T.creditToBuyback) + ' eth to buy and burn $CC, ' + fmtN(T.creditMiss) + ' buyers found nothing at their price');
  if (T.composedChosen) notes.push('<b>chosen composition</b> ' + fmtN(T.composedChosen) + ' statements composed from credits the composer named, average rating ' + (T.stRating / T.composed).toFixed(0) + ' points a statement');
  $('notes').innerHTML = notes.join(' &nbsp; ');
  $('tblnote').textContent = 'eth accounting closes to ' + Math.max(Math.abs(st.potCheck), Math.abs(st.saleCheck), Math.abs(st.creditCheck)).toExponential(1) + ' eth';
}
const p0 = () => toParams(state);
let rejected = null;
function run() {
  const t = performance.now();
  let res;
  try { res = simulate(toParams(state)); rejected = null; } catch (e) {
    rejected = String(e.message || e);
    $('verdict').className = 'verdict bad';
    $('v1').textContent = 'the Core would reject this change: ' + rejected;
    $('v2').textContent = 'the value is outside the bounds in src/lib/SettingsBounds.sol. pick another value.';
    return;
  }
  const ms = performance.now() - t;
  lastRes = res;
  renderVerdict(res, ms); renderTable(res);
  for (const ch of charts) {
    if (ch.spec.id === 'x') ch.ro.dataset.idle = res.params.balanceDay == null ? 'the balance side is off, switch it on in the controls' : 'move over the chart for values';
    setChartData(ch, res);
  }
  setCalData();
}
let timer = null;
function schedule() { clearTimeout(timer); timer = setTimeout(run, 140); }
