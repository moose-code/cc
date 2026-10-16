import { ponder } from "ponder:registry";
import { zeroAddress, type Hex } from "viem";

import { CORE_ADDRESS, STRATEGY_ADDRESS } from "../ponder.config";
import {
  activity,
  anchorMove,
  controller,
  credit,
  engine,
  settingChange,
  statement,
  statementCredit,
  statementFormat,
  strategyListing,
} from "../ponder.schema";
import { ensureCredit, ensureCredits, ensureEngine, ensureStatement, readController, refreshStatementArt, settingsColumns, snapshot } from "./chain";
import { composeModeOf } from "./lib/mode";
import { creditSaleSplit, statementPot } from "./lib/split";
import { act, bump, bumpBalancePaid, idOf, lc, posOf, record, toJson, type At, type Ctx } from "./shared";

// ---- per-transaction memory ----------------------------------------------------------------------------------
// Handlers run in log order, so facts that arrive earlier in a transaction are kept for the later event.

/** The transaction of the latest EthRateFill or ValueRateFill. Each eth bid credit is preceded by one in its transaction. */
let ethFill: string | null = null;
/** The credit of the latest balance bid CreditBought, completed by the BalanceRateFill that follows it. */
let balanceBuy: { tx: string; id: bigint; activityId: string } | null = null;
/** $CC burned by the Core, per transaction; the Buyback event that follows reports it. */
const coreBurn = new Map<string, bigint>();

// ---- shared steps ---------------------------------------------------------------------------------------------

/** Every Core event: log row, engine row, one snapshot per block. */
async function coreEvent(ctx: Ctx, e: At & { args?: unknown; log: { logIndex: number; address: Hex } }, name: string) {
  await record(ctx, e, "core", name);
  await snapshot(ctx, e.block);
}

/** Applies `patch` to the engine row and records the changed values before and after. */
async function setting(ctx: Ctx, e: At, name: string, patch: Partial<typeof engine.$inferInsert>) {
  const cur = await ensureEngine(ctx);
  const before = Object.fromEntries(Object.keys(patch).map((k) => [k, (cur as Record<string, unknown>)[k] ?? null]));
  await ctx.db.update(engine, { id: CORE_ADDRESS }).set(patch);
  await ctx.db
    .insert(settingChange)
    .values({ id: idOf(e), source: "core", name, before: toJson(before), after: toJson(patch), ...posOf(e) })
    .onConflictDoNothing();
}

/** Setting events whose value has no engine column. */
async function settingValue(ctx: Ctx, e: At, source: "core" | "controller", name: string, before: unknown, after: unknown) {
  await ctx.db
    .insert(settingChange)
    .values({ id: idOf(e), source, name, before: toJson(before ?? null), after: toJson(after), ...posOf(e) })
    .onConflictDoNothing();
}

/** A credit enters the pile at the next pile position. Fields of an earlier stay in the engine are cleared. */
async function enterPile(
  ctx: Ctx,
  e: At,
  id: bigint,
  how: typeof credit.$inferInsert.acquiredHow,
  cost: bigint,
  seller: Hex | null,
) {
  await ensureCredit(ctx, id);
  const eng = await ctx.db
    .update(engine, { id: CORE_ADDRESS })
    .set((row) => ({ pileSeq: row.pileSeq + 1n }));
  await ctx.db.update(credit, { id }).set({
    state: "held",
    costBasis: cost,
    acquiredAt: e.block.timestamp,
    acquiredBlock: e.block.number,
    acquiredTx: e.transaction.hash,
    acquiredHow: how,
    seller,
    balancePaid: null,
    pileOrder: eng.pileSeq,
    statementId: null,
    pagePosition: null,
    salePrice: null,
    buyer: null,
    toArtist: null,
    toOperator: null,
    toPot: null,
    toBuyback: null,
    costToPotBps: null,
  });
}

// ---- Core: credits in ----------------------------------------------------------------------------------------

ponder.on("Core:EthRateFill", async ({ event, context }) => {
  await coreEvent(context, event, "EthRateFill");
  ethFill = event.transaction.hash;
  await bump(context, event, { ethIntoCredits: event.args.spent });
});

// value mode (decision 148): an eth fill drops the shared balance instance and logs ValueRateFill in place of EthRateFill
ponder.on("Core:ValueRateFill", async ({ event, context }) => {
  await coreEvent(context, event, "ValueRateFill");
  ethFill = event.transaction.hash;
  await bump(context, event, { ethIntoCredits: event.args.spent });
});

ponder.on("Core:CreditBought", async ({ event, context }) => {
  await coreEvent(context, event, "CreditBought");
  const { id, from, cost } = event.args;
  const how = ethFill === event.transaction.hash ? "eth_bid" : "balance_bid";
  ethFill = null;
  await enterPile(context, event, id, how, cost, lc(from));
  await act(context, event, { kind: "credit_bought", creditId: id, account: lc(from), amount: cost, amount2: 0n });
  if (how === "balance_bid") balanceBuy = { tx: event.transaction.hash, id, activityId: idOf(event) };
  await bump(context, event, {
    creditsBought: 1n,
    ...(how === "eth_bid" ? { creditsEth: 1n } : { creditsBalance: 1n }),
  });
});

ponder.on("Core:BalanceRateFill", async ({ event, context }) => {
  await coreEvent(context, event, "BalanceRateFill");
  const { spent } = event.args;
  // This column follows earlier BalanceModuleSet logs, never a latest-state RPC read.
  const { balanceToken } = await ensureEngine(context);
  if (balanceBuy?.tx === event.transaction.hash) {
    await context.db.update(credit, { id: balanceBuy.id }).set({ balancePaid: spent, balancePaidToken: balanceToken });
    await context.db.update(activity, { id: balanceBuy.activityId }).set({ amount2: spent, balanceToken });
  }
  balanceBuy = null;
  if (balanceToken) {
    await bumpBalancePaid(context, event, balanceToken, spent);
  } else {
    console.error(
      `BalanceRateFill at ${event.transaction.hash} spent ${spent} while engine.balanceToken is null; the payout is credited to no token`,
    );
  }
});

ponder.on("Core:ListingBought", async ({ event, context }) => {
  await coreEvent(context, event, "ListingBought");
  const { id, caller, cost, paid } = event.args;
  ethFill = null;
  await enterPile(context, event, id, "listing", cost + paid, null);
  await act(context, event, { kind: "listing_bought", creditId: id, account: lc(caller), amount: cost + paid, amount2: paid });
  await bump(context, event, { creditsBought: 1n, creditsListing: 1n });
});

ponder.on("Core:CreditAdopted", async ({ event, context }) => {
  await coreEvent(context, event, "CreditAdopted");
  const { id, cost } = event.args;
  await enterPile(context, event, id, "adopted", cost, null);
  await act(context, event, { kind: "credit_adopted", creditId: id, amount: cost });
  await bump(context, event, { creditsBought: 1n, creditsAdopted: 1n });
});

// The in credit takes the out credit's pile position, cost basis and acquisition time. The event omits them.
ponder.on("Core:CreditSwapped", async ({ event, context }) => {
  await coreEvent(context, event, "CreditSwapped");
  const { inId, outId, caller, fee } = event.args;
  const out = await ensureCredit(context, outId);
  await ensureCredit(context, inId);
  await context.db.update(credit, { id: inId }).set({
    state: "held",
    costBasis: out.costBasis,
    acquiredAt: out.acquiredAt,
    acquiredBlock: event.block.number,
    acquiredTx: event.transaction.hash,
    acquiredHow: "swap_in",
    seller: lc(caller),
    balancePaid: null,
    pileOrder: out.pileOrder,
  });
  await context.db.update(credit, { id: outId }).set({ state: "swapped_out", pileOrder: null });
  await act(context, event, { kind: "credit_swapped", creditId: inId, otherCreditId: outId, account: lc(caller), amount2: fee });
  await bump(context, event, { creditsSwapped: 1n, ccBurned: fee });
});

// ---- Core: credits out, statements --------------------------------------------------------------------------

ponder.on("Core:Composed", async ({ event, context }) => {
  await coreEvent(context, event, "Composed");
  const { sid, ids, format, cost, price, caller } = event.args;
  await ensureStatement(context, sid);
  const mode = composeModeOf(event.transaction.to, CORE_ADDRESS, event.transaction.input);
  await context.db.update(statement, { id: sid }).set({
    state: "held",
    composedAt: event.block.timestamp,
    composedBlock: event.block.number,
    composeTx: event.transaction.hash,
    composer: lc(caller),
    mode,
    cost,
    composePrice: price,
    format,
  });
  await ensureCredits(context, ids);
  for (let i = 0; i < ids.length; i++) {
    await context.db.update(credit, { id: ids[i] }).set({ state: "composed", statementId: sid, pagePosition: i, pileOrder: null });
    await context.db
      .insert(statementCredit)
      .values({ id: `${sid}:${i}`, statementId: sid, position: i, creditId: ids[i] })
      .onConflictDoNothing();
  }
  await act(context, event, { kind: "composed", statementId: sid, account: lc(caller), amount: cost, amount2: price });
  await bump(context, event, { composed: 1n });
});

ponder.on("Core:HeldFormatSet", async ({ event, context }) => {
  await coreEvent(context, event, "HeldFormatSet");
  const { sid, format, caller } = event.args;
  const cur = await ensureStatement(context, sid);
  const art = await refreshStatementArt(context, sid);
  await context.db
    .insert(statementFormat)
    .values({ id: idOf(event), statementId: sid, from: cur.format ?? format, to: format, caller: lc(caller), ...posOf(event) })
    .onConflictDoNothing();
  await context.db.update(statement, { id: sid }).set({ format, ...art });
  await act(context, event, { kind: "restyled", statementId: sid, account: lc(caller) });
  await bump(context, event, { restyled: 1n });
});

ponder.on("Core:StatementSoldTo", async ({ event, context }) => {
  await coreEvent(context, event, "StatementSoldTo");
  const { sid, buyer, price, toBuyback, toArtist, toOperator } = event.args;
  await ensureStatement(context, sid);
  await context.db.update(statement, { id: sid }).set({
    state: "sold",
    salePrice: price,
    buyer: lc(buyer),
    toBuyback,
    toArtist,
    toOperator,
    toPot: statementPot(price, toArtist, toOperator, toBuyback),
  });
  await act(context, event, { kind: "statement_sold", statementId: sid, account: lc(buyer), amount: price, amount2: toBuyback });
  await bump(context, event, { statementsSold: 1n, toArtist, toOperator });
});

ponder.on("Core:CreditSold", async ({ event, context }) => {
  await coreEvent(context, event, "CreditSold");
  const { id, buyer, price, toArtist, toOperator } = event.args;
  const c = await ensureCredit(context, id);
  const eng = await ensureEngine(context);
  const bps = eng.creditCostToPotBps ?? 0;
  const split = creditSaleSplit(price, c.costBasis ?? 0n, toArtist, toOperator, BigInt(bps));
  await context.db.update(credit, { id }).set({
    state: "sold",
    pileOrder: null,
    salePrice: price,
    buyer: lc(buyer),
    toArtist,
    toOperator,
    toPot: split.toPot,
    toBuyback: split.toBuyback,
    costToPotBps: bps,
  });
  await act(context, event, { kind: "credit_sold", creditId: id, account: lc(buyer), amount: price, amount2: split.toPot });
  await bump(context, event, { creditsSold: 1n, toArtist, toOperator });
});

ponder.on("Core:StatementRedeemed", async ({ event, context }) => {
  await coreEvent(context, event, "StatementRedeemed");
  const { sid, received } = event.args;
  const { balanceToken } = await ensureEngine(context);
  await ensureStatement(context, sid);
  await context.db.update(statement, { id: sid }).set({ state: "redeemed", redeemedReceived: received });
  await act(context, event, { kind: "redeemed", statementId: sid, amount: received, balanceToken });
  await bump(context, event, { redeemed: 1n });
});

// ---- Core: money ----------------------------------------------------------------------------------------------

ponder.on("Core:Buyback", async ({ event, context }) => {
  await coreEvent(context, event, "Buyback");
  const { caller, amountIn } = event.args;
  const burned = coreBurn.get(event.transaction.hash) ?? 0n;
  coreBurn.delete(event.transaction.hash);
  await context.db.update(engine, { id: CORE_ADDRESS }).set({ lastBuybackBlock: event.block.number });
  await act(context, event, { kind: "buyback", account: lc(caller), amount: amountIn, amount2: burned });
  await bump(context, event, { buybacks: 1n, ethToBuybackSpent: amountIn });
});

ponder.on("Core:FeesAdded", async ({ event, context }) => {
  await coreEvent(context, event, "FeesAdded");
  const { amount, toPayee } = event.args;
  await act(context, event, { kind: "fees_added", amount, amount2: toPayee });
  await bump(context, event, { feesBooked: amount, toPayee });
});

ponder.on("Core:Funded", async ({ event, context }) => {
  await coreEvent(context, event, "Funded");
  await act(context, event, { kind: "funded", account: lc(event.args.from), amount: event.args.amount });
});

ponder.on("Core:EscrowCollected", async ({ event, context }) => {
  await coreEvent(context, event, "EscrowCollected");
  await act(context, event, { kind: "escrow_collected", amount: event.args.amount });
});

// ---- Core: settings, authority ---------------------------------------------------------------------------------

ponder.on("Core:SettingsSet", async ({ event, context }) => {
  await coreEvent(context, event, "SettingsSet");
  await setting(context, event, "SettingsSet", settingsColumns(event.args.settings));
});

ponder.on("Core:RateSet", async ({ event, context }) => {
  await coreEvent(context, event, "RateSet");
  const cur = await ensureEngine(context);
  await settingValue(context, event, "core", "RateSet", { ethRate: cur.ethRate }, { rate: event.args.rate });
});

ponder.on("Core:BalanceRateSet", async ({ event, context }) => {
  await coreEvent(context, event, "BalanceRateSet");
  const cur = await ensureEngine(context);
  await settingValue(context, event, "core", "BalanceRateSet", { balanceRate: cur.balanceRate }, { rateBps: event.args.rateBps });
});

ponder.on("Core:CreditCostToPotBpsSet", async ({ event, context }) => {
  await coreEvent(context, event, "CreditCostToPotBpsSet");
  await setting(context, event, "CreditCostToPotBpsSet", { creditCostToPotBps: Number(event.args.bps) });
});

ponder.on("Core:ChosenComposeOnSet", async ({ event, context }) => {
  await coreEvent(context, event, "ChosenComposeOnSet");
  await setting(context, event, "ChosenComposeOnSet", { chosenComposeOn: event.args.on });
});

ponder.on("Core:MinCcToChooseSet", async ({ event, context }) => {
  await coreEvent(context, event, "MinCcToChooseSet");
  await setting(context, event, "MinCcToChooseSet", { minCcToChoose: event.args.min });
});

ponder.on("Core:PausedSet", async ({ event, context }) => {
  await coreEvent(context, event, "PausedSet");
  await setting(context, event, "PausedSet", { paused: event.args.paused });
});

ponder.on("Core:PayeeSet", async ({ event, context }) => {
  await coreEvent(context, event, "PayeeSet");
  await setting(context, event, "PayeeSet", { payee: lc(event.args.payee) });
});

ponder.on("Core:ArtistSet", async ({ event, context }) => {
  await coreEvent(context, event, "ArtistSet");
  await setting(context, event, "ArtistSet", { artist: lc(event.args.artist) });
});

ponder.on("Core:BalanceModuleSet", async ({ event, context }) => {
  await coreEvent(context, event, "BalanceModuleSet");
  const { balanceModule, balanceToken, unitPerPoint } = event.args;
  await setting(context, event, "BalanceModuleSet", { balanceModule: lc(balanceModule), balanceToken: lc(balanceToken) });
  await settingValue(context, event, "core", "BalanceModuleSet.unitPerPoint", null, { unitPerPoint });
});

ponder.on("Core:AdapterSet", async ({ event, context }) => {
  await coreEvent(context, event, "AdapterSet");
  await settingValue(context, event, "core", "AdapterSet", null, { adapter: lc(event.args.adapter), allowed: event.args.allowed });
});

ponder.on("Core:ControllerSet", async ({ event, context }) => {
  await coreEvent(context, event, "ControllerSet");
  const addr = lc(event.args.controller);
  const cur = await ensureEngine(context);
  if (cur.controller && cur.controller !== addr) await context.db.update(controller, { id: cur.controller }).set({ active: false });
  const params = await readController(context, addr);
  await context.db
    .insert(controller)
    .values({ id: addr, setBlock: event.block.number, active: true, anchorBlock: event.block.number, ...params })
    .onConflictDoUpdate(() => ({ setBlock: event.block.number, active: true, anchorBlock: event.block.number, ...params }));
  await setting(context, event, "ControllerSet", { controller: addr });
});

ponder.on("Core:ControllerLocked", async ({ event, context }) => {
  await coreEvent(context, event, "ControllerLocked");
  await setting(context, event, "ControllerLocked", { controllerLocked: true });
});
ponder.on("Core:BalanceModuleLocked", async ({ event, context }) => {
  await coreEvent(context, event, "BalanceModuleLocked");
  await setting(context, event, "BalanceModuleLocked", { balanceModuleLocked: true });
});
ponder.on("Core:AdaptersLocked", async ({ event, context }) => {
  await coreEvent(context, event, "AdaptersLocked");
  await setting(context, event, "AdaptersLocked", { adaptersLocked: true });
});
ponder.on("Core:SuccessorLocked", async ({ event, context }) => {
  await coreEvent(context, event, "SuccessorLocked");
  await setting(context, event, "SuccessorLocked", { successorLocked: true });
});
ponder.on("Core:SuccessorSet", async ({ event, context }) => {
  await coreEvent(context, event, "SuccessorSet");
  await setting(context, event, "SuccessorSet", { successor: lc(event.args.successor) });
});
ponder.on("Core:EngineRetired", async ({ event, context }) => {
  await coreEvent(context, event, "EngineRetired");
  await setting(context, event, "EngineRetired", { retired: true });
});
ponder.on("Core:OwnershipTransferStarted", async ({ event, context }) => {
  await coreEvent(context, event, "OwnershipTransferStarted");
  await setting(context, event, "OwnershipTransferStarted", { pendingOwner: lc(event.args.pending) });
});
ponder.on("Core:OwnershipTransferred", async ({ event, context }) => {
  await coreEvent(context, event, "OwnershipTransferred");
  await setting(context, event, "OwnershipTransferred", { owner: lc(event.args.to), pendingOwner: null });
});

// Events logged without a projection. Pot and buyback balances come from the snapshot.
for (const name of ["RedeemBurnReleased", "CoinRescued", "NftRescued", "Migrated"] as const) {
  ponder.on(`Core:${name}`, async ({ event, context }) => {
    await coreEvent(context, event, name);
    await settingValue(context, event, "core", name, null, event.args);
  });
}

// ---- Controller ------------------------------------------------------------------------------------------------

async function controllerSetting(ctx: Ctx, e: At & { log: { logIndex: number; address: Hex } }, name: string, patch: Partial<typeof controller.$inferInsert>) {
  const id = lc(e.log.address);
  const cur = await ctx.db.find(controller, { id });
  if (!cur) throw new Error(`${name} from controller ${id} before its ControllerSet`);
  const before = Object.fromEntries(Object.keys(patch).map((k) => [k, (cur as Record<string, unknown>)[k] ?? null]));
  await ctx.db.update(controller, { id }).set(patch);
  await settingValue(ctx, e, "controller", name, before, patch);
}

ponder.on("Controller:Bought", async ({ event, context }) => {
  await record(context, event, "controller", "Bought");
});

ponder.on("Controller:AnchorMoved", async ({ event, context }) => {
  await record(context, event, "controller", "AnchorMoved");
  const { sid, saleBps, anchorBps } = event.args;
  await context.db
    .insert(anchorMove)
    .values({ id: idOf(event), controller: lc(event.log.address), statementId: sid, saleBps, anchorBps: BigInt(anchorBps), ...posOf(event) })
    .onConflictDoNothing();
  await context.db
    .update(controller, { id: lc(event.log.address) })
    .set({ anchorBps: BigInt(anchorBps), anchorBlock: event.block.number });
});

ponder.on("Controller:SaleSet", async ({ event, context }) => {
  await record(context, event, "controller", "SaleSet");
  const s = event.args.sale;
  await controllerSetting(context, event, "SaleSet", {
    markupBps: Number(s.markupBps),
    startCapBps: BigInt(s.startCapBps),
    decayHours: Number(s.decayHours),
    anchorHalfLife: BigInt(s.anchorHalfLife),
    anchorMinCost: s.anchorMinCost,
  });
});

ponder.on("Controller:CreditSaleSet", async ({ event, context }) => {
  await record(context, event, "controller", "CreditSaleSet");
  const c = event.args.credit;
  await controllerSetting(context, event, "CreditSaleSet", {
    saleOn: c.saleOn,
    window: BigInt(c.window),
    spreadBps: Number(c.spreadBps),
    startBps: BigInt(c.startBps),
  });
});

ponder.on("Controller:AnchorBpsSet", async ({ event, context }) => {
  await record(context, event, "controller", "AnchorBpsSet");
  await controllerSetting(context, event, "AnchorBpsSet", { anchorBps: BigInt(event.args.anchorBps), anchorBlock: event.block.number });
});

ponder.on("Controller:BalancePoolKeySet", async ({ event, context }) => {
  await record(context, event, "controller", "BalancePoolKeySet");
  const a = event.args;
  await controllerSetting(context, event, "BalancePoolKeySet", {
    balancePoolSet: true,
    balanceCurrency0: lc(a.currency0),
    balanceCurrency1: lc(a.currency1),
    balanceFee: Number(a.fee),
    balanceTickSpacing: Number(a.tickSpacing),
    balanceHooks: lc(a.hooks),
  });
});

// the protected price (decision 148): the quote settings and the rate limited reference of the balance token
ponder.on("Controller:QuoteSet", async ({ event, context }) => {
  await record(context, event, "controller", "QuoteSet");
  const q = event.args.quote;
  await controllerSetting(context, event, "QuoteSet", {
    quoteRateBpsPerHour: BigInt(q.rateBpsPerHour),
    quoteMaxStepBps: Number(q.maxStepBps),
    quoteTolBps: Number(q.tolBps),
    quoteMaxStale: BigInt(q.maxStale),
    quoteMinLiquidity: q.minLiquidity,
  });
});

ponder.on("Controller:Observed", async ({ event, context }) => {
  await record(context, event, "controller", "Observed");
  const id = lc(event.log.address);
  if (!(await context.db.find(controller, { id }))) throw new Error(`Observed from controller ${id} before its ControllerSet`);
  await context.db.update(controller, { id }).set({ refPrice: event.args.refPrice, refSpot: event.args.spot, refTime: event.block.timestamp });
});

// ---- tokens ----------------------------------------------------------------------------------------------------

// Coin burns. A burn by the Core is a buyback burn. Swap fee burns are counted from CreditSwapped.fee.
ponder.on("Coin:Transfer", async ({ event, context }) => {
  await record(context, event, "coin", "Transfer");
  if (lc(event.args.from) === CORE_ADDRESS) {
    coreBurn.set(event.transaction.hash, (coreBurn.get(event.transaction.hash) ?? 0n) + event.args.value);
    await bump(context, event, { ccBurned: event.args.value });
  }
});

ponder.on("BalanceToken:Transfer", async ({ event, context }) => {
  await record(context, event, "balance_token", "Transfer");
});

// Owner follows every Transfer. A transfer from the Core to the successor moves a held credit out of the pile
// (Core.migrate emits Migrated without the ids).
ponder.on("Credits:Transfer", async ({ event, context }) => {
  await record(context, event, "credits", "Transfer");
  const { from, to, id } = event.args;
  const c = await ensureCredit(context, id, lc(to));
  const patch: Partial<typeof credit.$inferInsert> = { owner: lc(to) };
  if (c.state === "held" && lc(from) === CORE_ADDRESS) {
    const eng = await context.db.find(engine, { id: CORE_ADDRESS });
    if (eng?.successor && eng.successor !== zeroAddress && eng.successor === lc(to)) {
      patch.state = "migrated";
      patch.pileOrder = null;
    }
  }
  await context.db.update(credit, { id }).set(patch);
  // a Credits Transfer out of the strategy ends its listing
  if (lc(from) === STRATEGY_ADDRESS) await endListing(context, event, id, lc(to));
});

// ---- CreditStrategy listings -------------------------------------------------------------------------------------

async function endListing(ctx: Ctx, e: At, id: bigint, buyer: Hex) {
  const row = await ctx.db.find(strategyListing, { id });
  if (!row?.active) return;
  await ctx.db.update(strategyListing, { id }).set({ active: false, soldBlock: e.block.number, soldAt: e.block.timestamp, buyer });
}

ponder.on("Strategy:NFTBoughtByProtocol", async ({ event, context }) => {
  await record(context, event, "strategy", "NFTBoughtByProtocol");
  const row = { listPrice: event.args.listPrice, active: true, boughtBlock: event.block.number, boughtAt: event.block.timestamp, soldBlock: null, soldAt: null, buyer: null };
  await context.db.insert(strategyListing).values({ id: event.args.tokenId, ...row }).onConflictDoUpdate(row);
});

ponder.on("Strategy:NFTSoldByProtocol", async ({ event, context }) => {
  await record(context, event, "strategy", "NFTSoldByProtocol");
  const { tokenId, buyer } = event.args;
  const row = await context.db.find(strategyListing, { id: tokenId });
  if (!row) return;
  await context.db.update(strategyListing, { id: tokenId }).set({ active: false, soldBlock: event.block.number, soldAt: event.block.timestamp, buyer: lc(buyer) });
});

ponder.on("Statements:Transfer", async ({ event, context }) => {
  await record(context, event, "statements", "Transfer");
  const { to, id } = event.args;
  await ensureStatement(context, id, lc(to));
  await context.db.update(statement, { id }).set({ owner: lc(to) });
});
