
// ================================================================= page: calibration, scenarios, theme, start
const SCENARIOS = [
  { id: 'sc-base', label: 'as launched', set: {} },
  { id: 'sc-open75', label: 'opening limit 75%', set: { openPct: 75 } },
  { id: 'sc-open40', label: 'opening limit 40%', set: { openPct: 40 } },
  { id: 'sc-markup130', label: 'start price 130% of the anchor', set: { markupBps: 13000 } },
  { id: 'sc-floor14', label: 'floor 60% on day 14', set: { chgOn: true, chgDay: 14, chgKey: 'saleFloorBps', chgValue: 6000 } },
  { id: 'sc-floor75', label: 'floor 75% from launch', set: { saleFloorBps: 7500 } },
  { id: 'sc-floor60', label: 'floor 60% from launch', set: { saleFloorBps: 6000 } },
  { id: 'sc-pause', label: 'pause sales days 20 to 27', set: { pauseOn: true, pauseDay: 20, pauseDays: 7 } },
  { id: 'sc-wait', label: 'every buyer waits for the floor', set: { buyerWaits: 'floor' } },
  { id: 'sc-fee25', label: '25% of fees to the redeem burn reserve', set: { feeToRedeemBurnBps: 2500 } },
  { id: 'sc-burn100', label: 'all sale proceeds to burn', set: { saleToBuybackBps: 10000 } },
  { id: 'sc-burn0', label: 'no sale proceeds to burn', set: { saleToBuybackBps: 0 } },
  { id: 'sc-s17', label: 'sustained 17 eth a day', set: { volPreset: 'sustained17' } },
  { id: 'sc-dead', label: 'dead after week one', set: { volPreset: 'deadWeek1' } },
  { id: 'sc-recov', label: 'credit price recovery', set: { pricePath: 'recovery' } },
  { id: 'sc-p2hold', label: 'the balance side hold on day 30', set: { balanceOn: true, balanceDay: 30, balanceDayMode: 1, xpPerPoint: 0.0087 / 440 } },
  { id: 'sc-p2', label: 'the balance side on day 30', set: { balanceOn: true, balanceDay: 30, balanceDayMode: 2, xpPerPoint: 0.0087 / 440, balancePoolSet: true } },
  { id: 'sc-p2nores', label: 'the balance side on day 30, no reserve', set: { balanceOn: true, balanceDay: 30, xpPerPoint: 0.0087 / 440, feeToRedeemBurnBps: 0, balancePoolSet: true } },
  { id: 'sc-p2low', label: 'the balance side on day 30, pool price pushed down', set: { balanceOn: true, balanceDay: 30, balanceDayMode: 2, xpPerPoint: 0.0087 / 440, balancePoolSet: true, balancePoolMult: 0.3 } },
  { id: 'sc-credit', label: 'credit sale window on', set: { creditSaleOn: true } },
  { id: 'sc-credit24', label: 'credit sale window 24 hours, composer picks the richest', set: { creditSaleOn: true, creditWindowHours: 24, chosenComposeOn: true, composeChoice: 'richest' } },
  { id: 'sc-credit-day', label: 'credit sale window on from day 10', set: { chgOn: true, chgDay: 10, chgKey: 'creditSaleOn', chgValue: 1 } },
  { id: 'sc-ref', label: 'refScore 350 points', set: { refScore: 3500000 } },
  { id: 'sc-noimp', label: 'engine never moves the market', set: { impactElast: 0 } },
];
function applyScenario(sc) { state = Object.assign({}, BASE_STATE, sc.set); syncControls(); run(); }
let calCh = null;
function modelVolume(p, d) { return dayVolume(p, d) * p.volScale; }
function setCalData() {
  const p = Object.assign({}, DEFAULTS, toParams(state));
  calCh.xs = REAL_VOL.map((_, i) => i);
  calCh.data = [REAL_VOL, calCh.xs.map((d) => modelVolume(p, d))];
  paint(calCh);
}
function buildCalibration() {
  const spec = { id: 'cal', title: '', fmt: { l: (v) => (v >= 1 ? v.toFixed(0) : v.toFixed(1)) }, log: { l: true }, series: [
    { label: 'observed daily volume', short: 'observed', color: '--s2', f: null }, { label: 'model, current preset', short: 'model', color: '--s1', f: null } ] };
  calCh = { spec, cv: $('calChart'), ro: { textContent: '', dataset: {} }, hover: -1, xs: [], data: [] };
  $('calLegend').innerHTML = '<span><i style="border-color:var(--s2)"></i>observed</span><span><i style="border-color:var(--s1)"></i>model, current preset</span>';
  const rows = [
    ['flat credit price per credit', 'median 0.0089 eth now, 0.03 at launch, p10 0.0069, p90 0.0138', 'flat in score, premium only above 740 points, 2x at 790 and up'],
    ['credit scores', 'uniform 80 to 800, mean 440', 'census of 122,154 credits'],
    ['statement buyer willingness to pay', 'p10 0.48, p25 0.71, median 0.84, p75 1.07, 21% at 1.2 or more, max 1.32 of the MARKET cost of the 80 credits. the asking price is a share of what the engine PAID, a different number', '42 priced sales, 33 statements'],
    ['statement asking price', 'starts at 150% of the anchor and falls in a straight line to 100% over 12 hours. the reference is the larger of the cost and the value of the rating: the floor rate times the rating over 80 times refScore (433 points), or the balance token pool term once the pool key is set. the floor is saleFloorBps of the reference, 100% at launch, so an unsold statement is asked at its reference. artist and operator cuts come from the payment, then the rest splits between the buying pot and buyback', 'docs/DECISIONS.md decisions 62 to 65, 85, 90, 104, 105, 112'],
    ['credit sale window', 'on at launch. a pile credit sells at a price falling from 3 times its floor (creditStartBps 30000) to the floor over 4 hours. the floor is 1.1 times the larger of its cost and the value of its score, so the start is 3.3 times that value. buyers are a model input: 40 a day, each taking the lowest priced credit that fits a willingness to pay around the market price. the cost share returns to the pot, the markup buys and burns $CC', 'docs/DECISIONS.md decisions 88, 92, 93, 104, 112'],
    ['the balance side', 'redeemOn is true and balanceBidOn is false at launch; the module is unset. with redeemOn a statement redeems once its curve price has reached its floor and the balance token stays in the module, with balanceBidOn the balance token bid climbs from its configured floor toward balanceBidCapBps of par. a credit bought that way enters the one pile at the eth cost the Core records from the floor rate. each redemption moves 20% of the redeem burn reserve (10% of the fees) to buy and burn $CC', 'docs/DECISIONS.md decisions 84 to 87, 92, 93, 104, 107. balance token amounts are held as eth value, the module is assumed to return the whole rating times the per point value'],
    ['statement buyers a day', '13, 11, 8, 6, 4 in the first five days, model 8 decaying to 2', 'composed 119, 19, 9, 3, 3 a day'],
    ['comparable coin volume', 'day one 1,557 eth, 912 in hour one, then 81, 42, 46, 57, 13, 28, 58, 12, 41, 5, 2, 3', 'fit 123 exp(-0.286 d), floor 0.5 eth a day'],
    ['coin buys against sells', 'day one 819 to 738 eth, net 80 eth moves price 2.5e-8 to 4.4e-7', 'model reproduces 4.48e-7 on day one'],
    ['CreditStrategy inventory', '13,132 credits listed at median 0.036 eth, mean score 371', 'static, cleared through buyListing when the ceiling passes the ask'],
    ['statement sale', 'a buyer takes the statement with the lowest asking price at or under its willingness to pay and does not wait for a lower price. it pays the asking price and gets the statement at once through Core.sellTo, and the anchor moves by anchorMoveBps of the gap toward a qualifying sale', 'src/Core.sol, src/ControllerV1.sol'],
    ['launch position', 'tick -175000 to 887200, whole supply, 10% baseline skim, 9 points to the Core and 1 point to the protocol, payeePpm 0, 90% falling to 10% over 30 minutes, no lp fee', 'script/config/mainnet.json'],
  ];
  $('calTbl').innerHTML = '<thead><tr><th>input</th><th>value in the model</th><th>source</th></tr></thead><tbody>' + rows.map((r) => '<tr><td>' + r[0] + '</td><td style="white-space:normal;text-align:left">' + r[1] + '</td><td style="white-space:normal;text-align:left">' + r[2] + '</td></tr>').join('') + '</tbody>';
}
function setTheme(mode) {
  const root = document.documentElement;
  if (mode === 'auto') root.removeAttribute('data-theme'); else root.setAttribute('data-theme', mode);
  $('themeToggle').textContent = 'theme: ' + mode;
  $('themeToggle').dataset.mode = mode;
  redrawAll();
}
function start() {
  buildControls(); syncControls();
  const sc = $('scenarios');
  for (const s of SCENARIOS) { const b = el('button', null, s.label); b.type = 'button'; b.id = s.id; b.addEventListener('click', () => applyScenario(s)); sc.appendChild(b); }
  $('reset').addEventListener('click', () => applyScenario(SCENARIOS[0]));
  for (const spec of CHART_SPECS) mkChart(spec);
  buildCalibration();
  $('themeToggle').addEventListener('click', () => { const m = $('themeToggle').dataset.mode || 'auto'; setTheme(m === 'auto' ? 'light' : m === 'light' ? 'dark' : 'auto'); });
  if (window.matchMedia) window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', redrawAll);
  let raf = 0;
  const redraw = () => { cancelAnimationFrame(raf); raf = requestAnimationFrame(redrawAll); };
  if (window.ResizeObserver) new ResizeObserver(redraw).observe($('charts')); else window.addEventListener('resize', redraw);
  run();
}
start();
