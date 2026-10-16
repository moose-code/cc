import { ponder } from "ponder:registry";
import { asc, count, eq } from "ponder";

import { coreAbi } from "../abis/Core";
import { MULTICALL3 } from "../abis/external";
import { CORE_ADDRESS } from "../ponder.config";
import { credit, engine, parity, statement } from "../ponder.schema";
import { snapshot } from "./chain";
import { allPassed, pageMatches } from "./lib/reconcile";
import { toJson } from "./shared";

const PAGE = 20n;

// Every 300 blocks: snapshot, then compare the projections with the Core views at the same block
// (docs/INDEXER.md section 8.4). A false check is a handler bug; fix it and reindex.
ponder.on("Tick:block", async ({ event, context }) => {
  const e = await context.db.find(engine, { id: CORE_ADDRESS });
  if (!e) return;
  await snapshot(context, event.block);

  const core = { address: CORE_ADDRESS, abi: coreAbi } as const;
  const [pileSize, held, page, ethPot] = await context.client.multicall({
    multicallAddress: MULTICALL3,
    allowFailure: false,
    contracts: [
      { ...core, functionName: "pileSize" },
      { ...core, functionName: "heldStatements" },
      { ...core, functionName: "pilePage", args: [0n, PAGE] },
      { ...core, functionName: "ethPot" },
    ],
  });

  const [{ n: heldCredits }] = await context.db.sql.select({ n: count() }).from(credit).where(eq(credit.state, "held"));
  const [{ n: heldStatements }] = await context.db.sql.select({ n: count() }).from(statement).where(eq(statement.state, "held"));
  const firstPage = await context.db.sql
    .select({ id: credit.id })
    .from(credit)
    .where(eq(credit.state, "held"))
    .orderBy(asc(credit.pileOrder))
    .limit(Number(PAGE));
  const snap = await context.db.find(engine, { id: CORE_ADDRESS });

  const checks = {
    pileSize: BigInt(heldCredits) === pileSize,
    heldStatements: BigInt(heldStatements) === BigInt(held.length),
    pileFirstPage: pageMatches(page, firstPage.map((r) => r.id)),
    ethPot: snap?.ethPot === ethPot,
  };
  const row = {
    blockTimestamp: event.block.timestamp,
    ok: allPassed(checks),
    pileSizeOk: checks.pileSize,
    heldStatementsOk: checks.heldStatements,
    pileFirstPageOk: checks.pileFirstPage,
    ethPotOk: checks.ethPot,
    detail: toJson({ chain: { pileSize, heldStatements: held.length, ethPot, page }, indexed: { heldCredits, heldStatements, ethPot: snap?.ethPot, page: firstPage.map((r) => r.id) } }),
  };
  await context.db.insert(parity).values({ blockNumber: event.block.number, ...row }).onConflictDoUpdate(() => row);
  if (!row.ok) console.error(`[parity] FAILED at block ${event.block.number}`, JSON.stringify(row.detail));
});
