// Read model of the indexer tables (indexer/ponder.schema.ts, docs/INDEXER.md section 6), as drizzle tables for
// @ponder/client. The indexer schema imports the `ponder` runtime, which does not bundle for the browser, so the
// columns the web reads are declared here. The guard at the end fails tsc when a column's type differs from the
// indexer schema or the column no longer exists there.

import { customType, integer, jsonb, pgTable, text } from "drizzle-orm/pg-core";
import type * as ix from "../../indexer/ponder.schema";

// numeric(78) read as bigint, like ponder's t.bigint(); sent as a decimal string.
const big = customType<{ data: bigint; driverData: string }>({
  dataType: () => "numeric(78)",
  fromDriver: (v) => BigInt(v),
  toDriver: (v) => v.toString(),
});
const hex = customType<{ data: `0x${string}`; driverData: string }>({ dataType: () => "text" });

export type CreditState = "outside" | "held" | "composed" | "sold" | "swapped_out" | "migrated";
export type AcquiredHow = "eth_bid" | "balance_bid" | "listing" | "adopted" | "swap_in";
export type StatementState = "outside" | "held" | "sold" | "redeemed";
export type ActivityKind =
  | "credit_bought"
  | "credit_adopted"
  | "listing_bought"
  | "credit_swapped"
  | "composed"
  | "restyled"
  | "statement_sold"
  | "credit_sold"
  | "redeemed"
  | "buyback"
  | "fees_added"
  | "funded"
  | "escrow_collected";

export const engine = pgTable("engine", {
  id: hex("id").primaryKey(),
  balanceToken: hex("balance_token"),
  artist: hex("artist"),
  payee: hex("payee"),
  creditCostToPotBps: integer("credit_cost_to_pot_bps"),
  lastBuybackBlock: big("last_buyback_block"),
  snapshotBlock: big("snapshot_block"),
});

export const credit = pgTable("credit", {
  id: big("id").primaryKey(),
  paidAt: big("paid_at").notNull(),
  score: big("score").notNull(),
  mask: integer("mask").notNull(),
  active: integer("active").notNull(),
  occupied: integer("occupied").notNull(),
  eights: integer("eights").notNull(),
  band: integer("band").notNull(),
  owner: hex("owner"),
  state: text("state").$type<CreditState>().notNull(),
  costBasis: big("cost_basis"),
  acquiredAt: big("acquired_at"),
  acquiredTx: hex("acquired_tx"),
  acquiredHow: text("acquired_how").$type<AcquiredHow>(),
  seller: hex("seller"),
  balancePaid: big("balance_paid"),
  pileOrder: big("pile_order"),
  statementId: big("statement_id"),
  salePrice: big("sale_price"),
  buyer: hex("buyer"),
  toArtist: big("to_artist"),
  toOperator: big("to_operator"),
  toPot: big("to_pot"),
  toBuyback: big("to_buyback"),
  costToPotBps: integer("cost_to_pot_bps"),
  tokenUri: text("token_uri"),
});

export const statement = pgTable("statement", {
  id: big("id").primaryKey(),
  state: text("state").$type<StatementState>().notNull(),
  owner: hex("owner"),
  composedAt: big("composed_at"),
  composeTx: hex("compose_tx"),
  composer: hex("composer"),
  mode: text("mode").$type<"default" | "chosen">(),
  cost: big("cost"),
  composePrice: big("compose_price"),
  rating: big("rating"),
  format: integer("format"),
  salePrice: big("sale_price"),
  buyer: hex("buyer"),
  toBuyback: big("to_buyback"),
  toArtist: big("to_artist"),
  toOperator: big("to_operator"),
  toPot: big("to_pot"),
  redeemedReceived: big("redeemed_received"),
  tokenUri: text("token_uri"),
  formatName: text("format_name"),
});

export const statementCredit = pgTable("statement_credit", {
  id: text("id").primaryKey(),
  statementId: big("statement_id").notNull(),
  position: integer("position").notNull(),
  creditId: big("credit_id").notNull(),
});

export const statementFormat = pgTable("statement_format", {
  id: text("id").primaryKey(),
  statementId: big("statement_id").notNull(),
  from: integer("from").notNull(),
  to: integer("to").notNull(),
  caller: hex("caller").notNull(),
  blockTimestamp: big("block_timestamp").notNull(),
  txHash: hex("tx_hash").notNull(),
  logIndex: integer("log_index").notNull(),
});

export const anchorMove = pgTable("anchor_move", {
  id: text("id").primaryKey(),
  statementId: big("statement_id").notNull(),
  saleBps: big("sale_bps").notNull(),
  anchorBps: big("anchor_bps").notNull(),
  blockTimestamp: big("block_timestamp").notNull(),
  txHash: hex("tx_hash").notNull(),
  logIndex: integer("log_index").notNull(),
});

export const activity = pgTable("activity", {
  id: text("id").primaryKey(),
  kind: text("kind").$type<ActivityKind>().notNull(),
  creditId: big("credit_id"),
  otherCreditId: big("other_credit_id"),
  statementId: big("statement_id"),
  account: hex("account"),
  amount: big("amount"),
  amount2: big("amount2"),
  blockNumber: big("block_number").notNull(),
  blockTimestamp: big("block_timestamp").notNull(),
  txHash: hex("tx_hash").notNull(),
  logIndex: integer("log_index").notNull(),
});

export const log = pgTable("log", {
  id: text("id").primaryKey(),
  args: jsonb("args").notNull(),
});

const counters = {
  creditsBought: big("credits_bought").notNull(),
  creditsAdopted: big("credits_adopted").notNull(),
  composed: big("composed").notNull(),
  toPayee: big("to_payee").notNull(),
  toArtist: big("to_artist").notNull(),
  toOperator: big("to_operator").notNull(),
  ccBurned: big("cc_burned").notNull(),
};

export const stats = pgTable("stats", { id: hex("id").primaryKey(), ...counters });
export const statsHourly = pgTable("stats_hourly", { hour: big("hour").primaryKey(), ...counters });

// ---- guard: every column declared here has the same type in the indexer schema -----------------------------------

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
] = [true, true, true, true, true, true, true, true, true, true];
void schemaMatchesIndexer;
