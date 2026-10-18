// promise: the release gate rejects a stale, wrong, or unreconciled indexer before coin launch.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createServer } from "node:http";
import { once } from "node:events";
import { promisify } from "node:util";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const exec = promisify(execFile);
const cwd = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const core = "0x1111111111111111111111111111111111111111";
const coin = "0x2222222222222222222222222222222222222222";
const state = {
  statusBlock: 1000,
  engine: { id: core, core, coin, deploy_block: "700", pile_size: "2", eth_pot: "20" },
  parity: { block_number: "900", ok: true },
  held: { n: "2" },
  credits: { n: "3" },
  statements: { n: "1" },
};
const json = (res, body) => {
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
};
const server = createServer((req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  if (url.pathname === "/status") return json(res, { chain: { id: 1, block: { number: state.statusBlock, timestamp: 1 } } });
  if (url.pathname !== "/sql/db") return json(res, { rows: [] });
  const query = JSON.parse(url.searchParams.get("sql")).json.sql;
  const rows = query.includes("from engine") ? [state.engine] :
    query.includes("from parity") ? [state.parity] :
    query.includes("from credit where") ? [state.held] :
    query.includes("from credit") ? [state.credits] :
    query.includes("from statement") ? [state.statements] : [];
  return json(res, { rows });
});

test("service acceptance requires the intended, current and reconciled Core", async () => {
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const origin = "http://127.0.0.1:" + server.address().port;
  const run = (requireActivity = "1", pile = "2") => exec(process.execPath,
    ["scripts/check-service.mjs", origin, "1", core, coin, "700", pile, "20", "1000", "5", requireActivity],
    { cwd });
  const rejectsWith = async (message) =>
    assert.rejects(run(), (error) => error.stderr.includes(message));
  try {
    const healthy = await run();
    assert.match(healthy.stdout, /"pileSize":"2"/);
    state.statusBlock = 990;
    await rejectsWith("more than 5 blocks behind");
    state.statusBlock = 1000;
    state.engine.coin = core;
    await rejectsWith("expected Core, coin");
    state.engine.coin = coin;
    state.parity.ok = false;
    await rejectsWith("parity row failed");
    state.parity.ok = true;
    state.parity.block_number = "699";
    await rejectsWith("parity row failed");
    state.parity.block_number = "900";
    state.engine.eth_pot = "21";
    await rejectsWith("SQL state differs");
    state.engine.eth_pot = "20";
    state.credits.n = "0";
    state.statements.n = "0";
    await rejectsWith("credit or statement SQL");
    state.engine.pile_size = "0";
    state.held.n = "0";
    await run("0", "0");
  } finally {
    server.close();
  }
});
