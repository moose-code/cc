// promise: the indexer serves the intended Core and coin with a current, reconciled SQL projection.
import { createClient } from "@ponder/client";
import { sql } from "ponder";

const [origin, chainId, core, coin, deployBlock, expectedPile, expectedPot, head, maxBehind, requireActivity] =
  process.argv.slice(2);
if (!origin || !/^\d+$/.test(chainId ?? "") ||
    !/^0x[0-9a-fA-F]{40}$/.test(core ?? "") || !/^0x[0-9a-fA-F]{40}$/.test(coin ?? "") ||
    ![deployBlock, expectedPile, expectedPot, head, maxBehind].every((value) => /^\d+$/.test(value ?? "")) ||
    !["0", "1"].includes(requireActivity)) {
  throw new Error("usage: check-service.mjs <origin> <chainId> <core> <coin> <deployBlock> " +
    "<pileSize> <ethPot> <head> <maxBehind> <requireActivity:0|1>");
}

const client = createClient(origin + "/sql");
const status = await client.getStatus();
const chain = Object.values(status).find((entry) => entry.id === Number(chainId));
if (!chain || chain.block.number + Number(maxBehind) < Number(head)) {
  throw new Error("indexer is more than " + maxBehind + " blocks behind chain head " + head);
}

const query = async (statement) => {
  const result = await client.db.execute(sql.raw(statement));
  return Array.isArray(result) ? result : result.rows;
};
const [engine] = await query("select id, core, coin, deploy_block, pile_size, eth_pot from engine " +
  "where id = '" + core.toLowerCase() + "' limit 1");
if (!engine || engine.core?.toLowerCase() !== core.toLowerCase() ||
    engine.coin?.toLowerCase() !== coin.toLowerCase() || BigInt(engine.deploy_block) !== BigInt(deployBlock)) {
  throw new Error("expected Core, coin or deploy block is missing from indexer SQL");
}
if (BigInt(engine.pile_size) !== BigInt(expectedPile) || BigInt(engine.eth_pot) !== BigInt(expectedPot)) {
  throw new Error("engine SQL state differs from Core reads: " +
    JSON.stringify(engine, (_key, value) => typeof value === "bigint" ? value.toString() : value));
}
const [parity] = await query("select block_number, ok from parity order by block_number desc limit 1");
if (!parity || String(parity.ok) !== "true" || BigInt(parity.block_number) < BigInt(deployBlock) ||
    BigInt(parity.block_number) + 300n + BigInt(maxBehind) < BigInt(head)) {
  throw new Error("latest parity row failed or is older than one 300-block interval");
}

const [held] = await query("select count(*) as n from credit where state = 'held'");
const [credits] = await query("select count(*) as n from credit");
const [statements] = await query("select count(*) as n from statement");
if (!held || BigInt(held.n) !== BigInt(expectedPile) || !credits || !statements ||
    (requireActivity === "1" && (BigInt(credits.n) === 0n || BigInt(statements.n) === 0n))) {
  throw new Error("credit or statement SQL projection is missing or inconsistent");
}
console.log(JSON.stringify({
  block: chain.block.number,
  parityBlock: String(parity.block_number),
  pileSize: String(engine.pile_size),
  ethPot: String(engine.eth_pot),
  credits: String(credits.n),
  statements: String(statements.n),
}));
