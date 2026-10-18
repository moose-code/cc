// promise: the candidate indexer serves a current SQL projection that agrees with the seeded Core.
import { createClient } from "@ponder/client";
import { sql } from "ponder";

const [origin, core, expectedPile, expectedPot, expectedBlock] = process.argv.slice(2);
if (!origin || !/^0x[0-9a-fA-F]{40}$/.test(core ?? "") || !expectedPile || !expectedPot || !expectedBlock) {
  throw new Error("usage: check-smoke.mjs <origin> <core> <pileSize> <ethPot> <block>");
}

const client = createClient(origin + "/sql");
const status = await client.getStatus();
const chain = Object.values(status).find((entry) => entry.id === 31337);
if (!chain || chain.block.number < Number(expectedBlock)) {
  throw new Error("indexer has not reached candidate block " + expectedBlock);
}

const query = async (statement) => {
  const result = await client.db.execute(sql.raw(statement));
  return Array.isArray(result) ? result : result.rows;
};
const [engine] = await query("select id, pile_size, eth_pot from engine where id = '" + core.toLowerCase() + "' limit 1");
if (!engine) throw new Error("seeded Core missing from indexer SQL");
if (BigInt(engine.pile_size) !== BigInt(expectedPile) || BigInt(engine.eth_pot) !== BigInt(expectedPot)) {
  throw new Error("engine SQL state differs from Core reads: " +
    JSON.stringify(engine, (_key, value) => typeof value === "bigint" ? value.toString() : value));
}

const [held] = await query("select count(*) as n from credit where state = 'held'");
const [credits] = await query("select count(*) as n from credit");
const [statements] = await query("select count(*) as n from statement");
if (!held || BigInt(held.n) !== BigInt(expectedPile) || !credits || BigInt(credits.n) === 0n ||
    !statements || BigInt(statements.n) === 0n) {
  throw new Error("credit or statement SQL projection is missing or inconsistent");
}
console.log(JSON.stringify({
  block: chain.block.number,
  pileSize: String(engine.pile_size),
  ethPot: String(engine.eth_pot),
  credits: String(credits.n),
  statements: String(statements.n),
}));
