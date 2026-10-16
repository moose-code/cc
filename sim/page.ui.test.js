import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { pathToFileURL } from 'node:url';
const root = new URL('../', import.meta.url).pathname.replace(/\/$/, '');
const engine = await import(pathToFileURL(root + '/sim/engine.js'));
const ids = new Map();
function element(tag) {
  return { tag, children: [], style: {}, dataset: {}, events: {}, value: '',
    set id(v) { this._id = v; ids.set(v, this); }, get id() { return this._id; },
    appendChild(child) { this.children.push(child); }, addEventListener(name, fn) { this.events[name] = fn; },
  };
}
const document = { createElement: element, getElementById(id) { if (!ids.has(id)) { const e = element('div'); e.id = id; } return ids.get(id); } };
const context = vm.createContext({ ...engine, document, schedule() {} });
vm.runInContext(fs.readFileSync(root + '/sim/page.ui1.js', 'utf8') + '\nbuildControls(); syncControls(); globalThis.probe = { params: () => toParams(state), state, BASE_STATE, GROUPS, CHG };', context);
const probe = context.probe, initial = probe.params();
// promise: every initial on-chain setting comes from the launch package rather than a stale page copy.
for (const key of [...engine.SETTING_KEYS, ...engine.CONTROLLER_KEYS, ...engine.CREDIT_KEYS]) assert.equal(initial[key], engine.DEFAULTS[key], key);
assert.equal(initial.rateStart, engine.DEFAULTS.rateStart);
assert.equal(initial.stepSec, 60);
// promise: new numeric controls reach the engine without formatting or clipping their values.
const changed = { spendCapBps: 10000, bucketSeconds: 1, balanceBidCapBps: 20000, idleStepSeconds: 30, sniperSeconds: 0, climbMultiplierCapBps: 65535, anchorMoveBps: 0 };
for (const [key, value] of Object.entries(changed)) {
  const input = ids.get('c-' + key); assert.equal(input.type, 'number', key);
  input.value = String(value); input.events.input();
  assert.equal(probe.params()[key], value, key);
  assert.ok(probe.CHG[key], 'owner schedule exposes ' + key);
}
for (const group of probe.GROUPS) for (const control of group.ctl) if (['refScore', 'dropPerCreditPct', 'rateCap', 'creditStartBps', 'balanceBidMarginBps'].includes(control.k)) assert.equal(control.t, 'number', control.k);
assert.equal(ids.has('c-royaltyBps'), false);
probe.state.bucketSeconds = 0; assert.throws(() => probe.params(), /bucketSeconds/); probe.state.bucketSeconds = 60;
probe.state.recoveryClimbPerMin = 0.01; assert.throws(() => probe.params(), /recoveryClimbPerMin/); probe.state.recoveryClimbPerMin = engine.DEFAULTS.recoveryClimbPerMin;
// promise: page parameters exercise the economic model and produce finite accounting.
const began = performance.now();
const result = engine.simulate({ ...probe.params(), days: 1 });
assert.ok(Math.abs(result.stats.potCheck) < 1e-6);
assert.ok(Number.isFinite(result.core.ethPot));
vm.runInContext(fs.readFileSync(root + '/sim/page.ui3.js', 'utf8') + '\nglobalThis.chartProbe = CHART_SPECS;', context);
assert.equal(context.chartProbe.find((chart) => chart.id === 'rate').fixed, undefined);
const html = fs.readFileSync(root + '/sim/index.html', 'utf8');
const script = html.slice(html.indexOf('<script>') + 8, html.lastIndexOf('</script>'));
new vm.Script(script);
assert.ok(script.includes('const warmupStep') || script.includes('warmupStep = Math.min(120, p.stepSec)'));
assert.ok(script.includes('spendCapBps: 10000') || script.includes('spendCapBps: s.spendCapBps'));
console.log('UI parameter, control, validation, one-day simulation and generated-script checks passed; one-day run ' + Math.round(performance.now() - began) + ' ms');
