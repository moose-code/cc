// builds index.html: engine.js is the single source, inlined here with its export keywords removed
import fs from 'node:fs';
const here = new URL('./', import.meta.url).pathname;
const rd = (f) => fs.readFileSync(here + f, 'utf8');
// the browser build cannot read the filesystem: strip the node-only imports and inline script/config/mainnet.json as
// LAUNCH_RAW and sim/live-state.json as LIVE, the same sources engine.js reads under node, so neither path hand copies
// a value
const cfgText = rd('../script/config/mainnet.json').trim();
const liveText = rd('live-state.json').trim();
// upstream.js is the single source for Jack's balance token constants; inline it before engine.js, exports stripped, so
// the browser build carries the same values engine.js imports under node
const upstream = rd('upstream.js').replace(/^export /gm, '');
const engine = rd('engine.js')
  .replace(/^(import|export) .*\/\/ build-strip$/gm, '')
  .replace(/^export const LAUNCH_RAW = .*\/\/ build-inline$/m, `const LAUNCH_RAW = ${cfgText};`)
  .replace(/^const LIVE = .*\/\/ build-inline-live$/m, `const LIVE = ${liveText};`)
  .replace(/^export /gm, '');
const ui = ['page.ui1.js', 'page.ui2.js', 'page.ui3.js', 'page.ui4.js'].map(rd).join('\n');
const html = [
  '<title>Credits Engine Simulator</title>',
  '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;500;600&display=swap">',
  '<style>', rd('page.css').trim(), '</style>',
  rd('page.body.html').trim(),
  '<script>', '(function () {', 'try {', upstream, engine, ui, '} catch (e) { document.getElementById("v1").textContent = "script error: " + e.message; throw e; }', '})();', '</script>', '',
].join('\n');
fs.writeFileSync(here + 'index.html', html);
console.log('index.html', html.length, 'bytes');
