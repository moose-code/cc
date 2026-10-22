// focused checks of the value-referenced pricing study (sim/value.mjs). run: node sim/value.test.mjs
import { run } from './value.mjs';

let n = 0;
const ok = (c, m) => { n++; if (!c) { console.error('FAIL ' + m); process.exit(1); } };
const o = run();
// promise: a cap of 100 percent never pays above par, so conversion never loses on the bid alone
for (const r of o.organic.filter((r) => r.cell.cap === 10000)) ok(r.premiumLossPct < 1e-6 && r.meanPaidPct <= 100 + 1e-6, 'cap 100 pays at most par');
// promise: the premium paid above par rises with the cap and with the climb speed at the same seller flow
for (const lam of [3, 12]) for (const mean of [1, 0.95]) {
  const at = (cap, climb) => o.organic.find((r) => r.cell.cap === cap && r.cell.climb === climb && r.lam === lam && r.mean === mean).premiumLossPct;
  ok(at(11000, 200) >= at(10500, 200) && at(10500, 200) >= at(10000, 200), 'premium loss grows with the cap');
  ok(at(10500, 200) >= at(10500, 20) && at(10500, 20) >= at(10500, 10), 'premium loss grows with the climb');
}
// promise: the protected floor at the ceiling, (1 + spread) times the cap, leaves no gain to a buy at the floor and a sale back at the cap
for (const r of o.loop) {
  if (r.rule === 'ceiling') ok(r.gainPerCreditPct <= -100 * r.spread + 1e-9 && r.gainPerHourPctOfCapital === 0, 'ceiling floor closes the loop');
  else ok(Math.abs(r.gainPerCreditPct - (r.cell.cap / 100 - 100)) < 1e-6, 'current-bid floor leaves cap minus par per credit');
}
// promise: both budget rules absorb a dump at about the floor and never spend more than the capital
for (const r of o.dump) ok(r.meanPaidPct < 92 && r.ethSpent <= 10 + 1e-9 && r.left === 0, 'dump absorbed near the floor within the capital');
// promise: the pot loses on every floor sale and breaks even only above 1 / (0.75 * 0.97) times the bid paid
for (const r of o.split) ok(Math.abs(r.breakEvenMult - r.bid / (0.75 * 0.97)) < 1e-9 && (r.mult < r.breakEvenMult) === (r.potChange < 0), 'sale split break even');
// promise: against a patient seller the shipped eth bid (climb 200, rateCap 3x, the loosening) pays out most of a 10 eth pot in a day
// at a 0.005 eth market, and the loss falls with a lower rateCap, and with a slower climb once the cap is low enough that
// the pot does not fully drain either way (at the 3x cap both climbs empty the pot, so the slower climb's fewer but
// pricier sales do not lower the overpay there)
const pat = (climb, capX, loosen, PE = 0.005) => o.patient.find((r) => r.climb === climb && r.rateCapX === capX && r.loosening === loosen && r.marketEth === PE);
ok(pat(200, 3, 'shipped').overpay24h > 5, 'shipped bid loses most of the pot to a patient seller');
ok(pat(200, 1.2, 'shipped').overpay24h < pat(200, 3, 'shipped').overpay24h && pat(20, 1.2, 'shipped').overpay24h < pat(200, 1.2, 'shipped').overpay24h, 'rateCap and climb bound the patient seller');
console.log(`ok, ${n} checks passed`);
