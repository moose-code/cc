import type { Context } from "ponder:registry";
import { replaceBigInts } from "ponder";
import type { Hex } from "viem";

import { CORE_ADDRESS } from "../ponder.config";
import { activity, log, stats, statsHourly } from "../ponder.schema";
import { addTokenPayment } from "./lib/balance-history";

export type Ctx = Context;

/** Chain position of the event being handled. */
export type At = {
  block: { number: bigint; timestamp: bigint };
  transaction: { hash: Hex };
  log: { logIndex: number };
};

export const lc = (a: string): Hex => a.toLowerCase() as Hex;

/** Bigints become decimal strings so a value fits a json column. */
export const toJson = (v: unknown) => replaceBigInts(v, (x) => x.toString());

export const idOf = (e: At) => `${e.transaction.hash}:${e.log.logIndex}`;

export const posOf = (e: At) => ({
  blockNumber: e.block.number,
  blockTimestamp: e.block.timestamp,
  txHash: e.transaction.hash,
  logIndex: e.log.logIndex,
});

/** Writes the `log` row of an event. Every handler calls it first. */
export async function record(
  ctx: Ctx,
  e: At & { args?: unknown; log: { logIndex: number; address: Hex } },
  contract: "core" | "controller" | "coin" | "balance_token" | "credits" | "statements" | "strategy",
  event: string,
) {
  await ctx.db
    .insert(log)
    .values({ id: idOf(e), address: lc(e.log.address), contract, event, args: toJson(e.args ?? {}), ...posOf(e) })
    .onConflictDoNothing();
}

type ActivityRow = typeof activity.$inferInsert;

export async function act(
  ctx: Ctx,
  e: At,
  row: Pick<ActivityRow, "kind"> & Partial<Pick<ActivityRow, "creditId" | "otherCreditId" | "statementId" | "account" | "amount" | "amount2" | "balanceToken">>,
) {
  await ctx.db
    .insert(activity)
    .values({ id: idOf(e), ...row, ...posOf(e) })
    .onConflictDoNothing();
}

export type CounterKey = Exclude<keyof typeof stats.$inferInsert, "id" | "balancePaidByToken">;

/** Adds `delta` to the singleton stats row and to the stats row of the event's hour. */
export async function bump(ctx: Ctx, e: At, delta: Partial<Record<CounterKey, bigint>>) {
  const add = (row: Record<string, unknown>) =>
    Object.fromEntries(Object.entries(delta).map(([k, v]) => [k, (row[k] as bigint) + (v as bigint)]));
  await ctx.db.insert(stats).values({ id: CORE_ADDRESS, ...delta }).onConflictDoUpdate(add);
  await ctx.db.insert(statsHourly).values({ hour: e.block.timestamp / 3600n, ...delta }).onConflictDoUpdate(add);
}

/** Token units are comparable only within one currency, including hourly totals. */
export async function bumpBalancePaid(ctx: Ctx, e: At, token: string, spent: bigint) {
  const initial = addTokenPayment({}, token, spent);
  const add = (row: { balancePaidByToken: Record<string, string> }) => ({ balancePaidByToken: addTokenPayment(row.balancePaidByToken, token, spent) });
  await ctx.db.insert(stats).values({ id: CORE_ADDRESS, balancePaidByToken: initial }).onConflictDoUpdate(add);
  await ctx.db.insert(statsHourly).values({ hour: e.block.timestamp / 3600n, balancePaidByToken: initial }).onConflictDoUpdate(add);
}
