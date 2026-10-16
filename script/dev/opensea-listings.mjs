#!/usr/bin/env node
// fetches the active Credits listings from the OpenSea API v2 (listings/collection/<slug>/best, the slug resolved from
// chain/ethereum/contract/<address>) and writes the ones a Seaport 1.6 basic order can
// fulfil as the input of script/dev/Activity.s.sol (stage bots).
//
//   OPENSEA_API_KEY=<key> node script/dev/opensea-listings.mjs --out <file> [--rpc <url> --adapter <SeaportBasicAdapter>]
//
// the key is read from the environment only. a listing is kept when it has one ERC721 offer item of Credits, native
// consideration items with equal start and end amounts, the first paid to the offerer, an open order type, every other
// recipient the offerer or an address the adapter allows, and an end time in the future. the allowlist comes from
// allowedRecipient(address) of the adapter at --rpc, or from ALLOWED_RECIPIENTS (comma separated) without an rpc; the
// default is the launch entry, the OpenSea fee collector.
//
// the listing pages carry no signature. the listings are ranked by price over fork score (the order in which a bid
// scaled by score reaches them), and the signature of the cheapest SIGN of them (default 40) comes from the
// fulfillment_data endpoint, whose parameters are the BasicOrderParameters of the order. without --rpc the ranking is
// by price.
//
// output: {"count": N, "orders": [{"id": "<credit id>", "price": "<wei>", "params": BasicOrderParameters}]}. every
// number is a decimal string. params carries the fields of BasicOrderParameters, built the way test/Seaport.t.sol
// _basicData builds them, plus the Seaport order hash. the fetch itself is packages/engine/src/opensea.mjs, shared
// with keeper/.

import { writeFileSync } from "node:fs";
import { fetchListings } from "../../packages/engine/src/opensea.mjs";

const arg = (name, dflt) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : dflt;
};
const out = arg("out");
const key = process.env.OPENSEA_API_KEY;
if (!out) throw new Error("--out <file> is required");
if (!key) {
  console.error("opensea: OPENSEA_API_KEY is not set, nothing fetched");
  writeFileSync(out, JSON.stringify({ count: 0, orders: [] }));
  process.exit(0);
}

const r = await fetchListings({
  key,
  rpc: arg("rpc", process.env.RPC_URL),
  adapter: arg("adapter", process.env.SEAPORT_ADAPTER),
  pages: Number(arg("pages", process.env.OPENSEA_PAGES ?? 3)),
  sign: Number(arg("sign", process.env.OPENSEA_SIGN ?? 40)),
  fulfiller: arg("fulfiller", undefined),
  allowedRecipients: process.env.ALLOWED_RECIPIENTS?.split(","),
  horizon: process.env.FORK_HORIZON ? Number(process.env.FORK_HORIZON) : undefined,
});
writeFileSync(out, JSON.stringify({ count: r.orders.length, orders: r.orders }, null, 1));
console.error(`opensea: fetched ${r.fetched} listings, ${r.fit} fit a basic order and the fork (${r.notHeld} not held by the offerer at the fork block or not started), ${r.orders.length} signed (cheapest by price over fork score)`);
for (const [why, n] of Object.entries(r.dropped)) console.error(`opensea: dropped ${n}: ${why}`);
