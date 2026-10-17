// Compile-time guard: every column web declares in lib/indexer-schema.ts has the same type in the indexer's ponder
// schema, and no declared column has been removed there. This lives in scripts/ (excluded from the Next build in
// tsconfig.json) because indexer/ponder.schema.ts imports the `ponder` runtime, which the web deploy does not install.
// It is enforced by `npm run check` (check:schema), where the indexer's dependencies are present.

import type * as ix from "../../indexer/ponder.schema";
import {
  activity,
  anchorMove,
  credit,
  engine,
  log,
  statement,
  statementCredit,
  statementFormat,
  stats,
  statsHourly,
  strategyListing,
} from "../lib/indexer-schema";

type Same<W, I> = [keyof W] extends [keyof I] ? ([W] extends [Pick<I, keyof W & keyof I>] ? ([Pick<I, keyof W & keyof I>] extends [W] ? true : false) : false) : false;
type Row<T extends { $inferSelect: unknown }> = T["$inferSelect"];
const schemaMatchesIndexer: [
  Same<Row<typeof engine>, Row<typeof ix.engine>>,
  Same<Row<typeof credit>, Row<typeof ix.credit>>,
  Same<Row<typeof statement>, Row<typeof ix.statement>>,
  Same<Row<typeof statementCredit>, Row<typeof ix.statementCredit>>,
  Same<Row<typeof statementFormat>, Row<typeof ix.statementFormat>>,
  Same<Row<typeof anchorMove>, Row<typeof ix.anchorMove>>,
  Same<Row<typeof activity>, Row<typeof ix.activity>>,
  Same<Row<typeof log>, Row<typeof ix.log>>,
  Same<Row<typeof stats>, Row<typeof ix.stats>>,
  Same<Row<typeof statsHourly>, Row<typeof ix.statsHourly>>,
  Same<Row<typeof strategyListing>, Row<typeof ix.strategyListing>>,
] = [true, true, true, true, true, true, true, true, true, true, true];
void schemaMatchesIndexer;
