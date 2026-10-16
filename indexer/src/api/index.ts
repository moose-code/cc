import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { client, desc, graphql } from "ponder";

import { rpcStats } from "../lib/rpc";

// Public and read only. GraphQL over the schema, SQL over HTTP for @ponder/client, and two health routes.
// /health and /ready are reserved by Ponder.
const app = new Hono();

app.use("/graphql", graphql({ db, schema }));
app.use("/sql/*", client({ db, schema }));

// The newest parity row. 200 when every check passed, 503 when one failed or none exists yet.
app.get("/health/parity", async (c) => {
  const [row] = await db.select().from(schema.parity).orderBy(desc(schema.parity.blockNumber)).limit(1);
  if (!row) return c.json({ ok: false, reason: "no parity row yet" }, 503);
  const body = JSON.parse(JSON.stringify(row, (_k, v) => (typeof v === "bigint" ? v.toString() : v)));
  return c.json(body, row.ok ? 200 : 503);
});

// Requests and failures per RPC endpoint since process start. A failure is a request that the next endpoint served.
app.get("/health/rpc", (c) => c.json(Object.fromEntries(rpcStats())));

export default app;
