import { index, onchainEnum, onchainTable, type PgColumnsBuilders } from "ponder";

// Conventions: addresses are lowercase hex, amounts are bigint base units (wei for ETH, 18 decimals for $CC,
// balance token units for $BALANCE). Every row written from an event carries blockNumber, blockTimestamp,
// txHash and logIndex. docs/INDEXER.md section 6 is the contract for these tables.

export const creditState = onchainEnum("credit_state", ["outside", "held", "composed", "sold", "swapped_out", "migrated"]);
export const acquiredHow = onchainEnum("acquired_how", ["eth_bid", "balance_bid", "listing", "adopted", "swap_in"]);
export const statementState = onchainEnum("statement_state", ["outside", "held", "sold", "redeemed"]);
export const composeMode = onchainEnum("compose_mode", ["default", "chosen"]);
export const activityKind = onchainEnum("activity_kind", [
  "credit_bought",
  "credit_adopted",
  "listing_bought",
  "credit_swapped",
  "composed",
  "restyled",
  "statement_sold",
  "credit_sold",
  "redeemed",
  "buyback",
  "fees_added",
  "funded",
  "escrow_collected",
]);

/** Every decoded event of every indexed address. Typed tables are projections of it. args holds bigints as strings. */
export const log = onchainTable(
  "log",
  (t) => ({
    id: t.text().primaryKey(), // txHash:logIndex
    address: t.hex().notNull(),
    contract: t.text().notNull(), // core, controller, coin, balance_token, credits, statements
    event: t.text().notNull(),
    args: t.json().notNull(),
    blockNumber: t.bigint().notNull(),
    blockTimestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({
    byEvent: index().on(table.contract, table.event, table.blockNumber),
  }),
);

/**
 * One row per Core. Address and flag columns follow the matching setter event. Values read at the first Core
 * event (constructor values emit no event) are creditCostToPotBps, chosenComposeOn, minCcToChoose, artist,
 * owner, payee, coin. The latest snapshot columns mirror the newest engine_snapshot row.
 */
export const engine = onchainTable("engine", (t) => ({
  id: t.hex().primaryKey(), // core address
  core: t.hex().notNull(),
  controller: t.hex(),
  coin: t.hex(),
  balanceModule: t.hex(),
  balanceToken: t.hex(),
  owner: t.hex(),
  pendingOwner: t.hex(),
  payee: t.hex(),
  artist: t.hex(),
  successor: t.hex(),
  paused: t.boolean().notNull().default(false),
  retired: t.boolean().notNull().default(false),
  controllerLocked: t.boolean().notNull().default(false),
  balanceModuleLocked: t.boolean().notNull().default(false),
  adaptersLocked: t.boolean().notNull().default(false),
  successorLocked: t.boolean().notNull().default(false),
  chosenComposeOn: t.boolean().notNull().default(false),
  payeeOn: t.boolean().notNull().default(false),
  settings: t.json(), // full Settings struct, bigints as strings
  saleToArtistBps: t.integer(),
  saleToOperatorBps: t.integer(),
  saleToBuybackBps: t.integer(),
  feeToRedeemBurnBps: t.integer(),
  payeePpm: t.integer(),
  creditCostToPotBps: t.integer(),
  minCcToChoose: t.bigint(),
  lastBuybackBlock: t.bigint(),
  ethPot: t.bigint(),
  ethToBuyback: t.bigint(),
  ethRedeemBurn: t.bigint(),
  ethRate: t.bigint(),
  floorRate: t.bigint(),
  balanceRate: t.bigint(),
  coreEthBalance: t.bigint(),
  balanceAvailable: t.bigint(),
  pileSize: t.bigint(),
  snapshotBlock: t.bigint(),
  pileSeq: t.bigint().notNull().default(0n), // last assigned credit.pileOrder
  deployBlock: t.bigint().notNull(),
}));

/** One row per snapshot block: every block with an engine event, plus every 300th block. */
export const engineSnapshot = onchainTable("engine_snapshot", (t) => ({
  blockNumber: t.bigint().primaryKey(),
  blockTimestamp: t.bigint().notNull(),
  ethPot: t.bigint().notNull(),
  ethToBuyback: t.bigint().notNull(),
  ethRedeemBurn: t.bigint().notNull(),
  ethRate: t.bigint().notNull(),
  floorRate: t.bigint().notNull(),
  balanceRate: t.bigint().notNull(),
  coreEthBalance: t.bigint().notNull(),
  balanceAvailable: t.bigint(),
  balanceToken: t.hex(), // the token balanceAvailable is denominated in at this block; changes at BalanceModuleSet
  pileSize: t.bigint().notNull(),
  payeeOn: t.boolean().notNull(),
  paused: t.boolean().notNull(),
}));

/** One row per setter, lock or ownership event. before and after hold the changed values as json. */
export const settingChange = onchainTable(
  "setting_change",
  (t) => ({
    id: t.text().primaryKey(), // txHash:logIndex
    source: t.text().notNull(), // core or controller
    name: t.text().notNull(), // event name
    before: t.json(),
    after: t.json(),
    blockNumber: t.bigint().notNull(),
    blockTimestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({ byName: index().on(table.name, table.blockNumber) }),
);

/** One row per controller named by ControllerSet. Parameters are read at its ControllerSet block and follow its setter events. */
export const controller = onchainTable("controller", (t) => ({
  id: t.hex().primaryKey(), // controller address
  setBlock: t.bigint().notNull(),
  active: t.boolean().notNull(),
  markupBps: t.integer(),
  startCapBps: t.bigint(),
  decayHours: t.integer(),
  anchorHalfLife: t.bigint(),
  anchorMinCost: t.bigint(),
  saleOn: t.boolean(),
  window: t.bigint(),
  spreadBps: t.integer(),
  startBps: t.bigint(),
  anchorBps: t.bigint(), // stored value, decays with anchorHalfLife from anchorBlock
  anchorBlock: t.bigint(),
  balancePoolSet: t.boolean().notNull().default(false),
  balanceCurrency0: t.hex(),
  balanceCurrency1: t.hex(),
  balanceFee: t.integer(),
  balanceTickSpacing: t.integer(),
  balanceHooks: t.hex(),
  // the protected price (decision 148): the quote settings (QuoteSet) and the reference of the balance token with the
  // pool spot it moved toward, wei per 1e18 base units, at the last Observed
  quoteRateBpsPerHour: t.bigint(),
  quoteMaxStepBps: t.integer(),
  quoteTolBps: t.integer(),
  quoteMaxStale: t.bigint(),
  quoteMinLiquidity: t.bigint(),
  refPrice: t.bigint(),
  refSpot: t.bigint(),
  refTime: t.bigint(),
}));

/**
 * One row per Credits token id. Fixed facts (seed to tokenUri) are read once, at the latest block, when the id is
 * first seen. owner follows the Credits Transfer log. pileOrder is non-null exactly while state = held.
 */
export const credit = onchainTable(
  "credit",
  (t) => ({
    id: t.bigint().primaryKey(),
    seed: t.hex().notNull(),
    paidAt: t.bigint().notNull(),
    score: t.bigint().notNull(), // ten-thousandths of a point
    rating: t.text().notNull(), // score / 10000 as a decimal string
    mask: t.integer().notNull(), // bit0 C, bit1 M, bit2 Y, bit3 K; a set bit is a printed plate
    active: t.integer().notNull(),
    occupied: t.integer().notNull(),
    eights: t.integer().notNull(),
    band: t.integer().notNull(),
    owner: t.hex(),
    state: creditState("state").notNull(),
    costBasis: t.bigint(),
    acquiredAt: t.bigint(),
    acquiredBlock: t.bigint(),
    acquiredTx: t.hex(),
    acquiredHow: acquiredHow("acquired_how"),
    seller: t.hex(),
    balancePaid: t.bigint(), // BalanceRateFill.spent, in balancePaidToken's base units
    balancePaidToken: t.hex(), // the balance token active at the sale; changes at BalanceModuleSet
    pileOrder: t.bigint(), // insertion sequence; a swap-in takes the out credit's value
    statementId: t.bigint(),
    pagePosition: t.integer(),
    salePrice: t.bigint(),
    buyer: t.hex(),
    toArtist: t.bigint(),
    toOperator: t.bigint(),
    toPot: t.bigint(),
    toBuyback: t.bigint(),
    costToPotBps: t.integer(),
    tokenUri: t.text(),
  }),
  (table) => ({
    byOwner: index().on(table.owner),
    byState: index().on(table.state, table.pileOrder),
  }),
);

/** One row per Statements token id. state = outside until the Core composes it. */
export const statement = onchainTable(
  "statement",
  (t) => ({
    id: t.bigint().primaryKey(),
    state: statementState("state").notNull(),
    owner: t.hex(),
    composedAt: t.bigint(),
    composedBlock: t.bigint(),
    composeTx: t.hex(),
    composer: t.hex(),
    mode: composeMode("mode"), // null for a compose through another contract
    cost: t.bigint(),
    composePrice: t.bigint(),
    rating: t.bigint(), // Statements.creditScoreOf, ten-thousandths of a point
    format: t.integer(),
    salePrice: t.bigint(),
    buyer: t.hex(),
    toBuyback: t.bigint(),
    toArtist: t.bigint(),
    toOperator: t.bigint(),
    toPot: t.bigint(),
    redeemedReceived: t.bigint(),
    tokenUri: t.text(), // refreshed after HeldFormatSet
    formatName: t.text(), // Format trait of the token metadata
  }),
  (table) => ({ byState: index().on(table.state), byOwner: index().on(table.owner) }),
);

/** The 80 credits of a composed statement, position 0..79 in pile order. */
export const statementCredit = onchainTable("statement_credit", (t) => ({
  id: t.text().primaryKey(), // statementId:position
  statementId: t.bigint().notNull(),
  position: t.integer().notNull(),
  creditId: t.bigint().notNull(),
}), (table) => ({ byStatement: index().on(table.statementId), byCredit: index().on(table.creditId) }));

export const statementFormat = onchainTable("statement_format", (t) => ({
  id: t.text().primaryKey(), // txHash:logIndex
  statementId: t.bigint().notNull(),
  from: t.integer().notNull(),
  to: t.integer().notNull(),
  caller: t.hex().notNull(),
  blockNumber: t.bigint().notNull(),
  blockTimestamp: t.bigint().notNull(),
  txHash: t.hex().notNull(),
  logIndex: t.integer().notNull(),
}), (table) => ({ byStatement: index().on(table.statementId) }));

export const anchorMove = onchainTable("anchor_move", (t) => ({
  id: t.text().primaryKey(), // txHash:logIndex
  controller: t.hex().notNull(),
  statementId: t.bigint().notNull(),
  saleBps: t.bigint().notNull(),
  anchorBps: t.bigint().notNull(),
  blockNumber: t.bigint().notNull(),
  blockTimestamp: t.bigint().notNull(),
  txHash: t.hex().notNull(),
  logIndex: t.integer().notNull(),
}), (table) => ({ byStatement: index().on(table.statementId) }));

/**
 * The ledger: one row per user-visible event. amount is ETH wei unless the kind says otherwise.
 * amount2 per kind: credit_bought balance token paid (balance bid) or 0; listing_bought keeper payment;
 * credit_swapped $CC fee; composed listed price; statement_sold toBuyback; credit_sold toPot;
 * redeemed none (amount is the balance token received); buyback $CC burned; fees_added toPayee; others none.
 * account per kind: seller, adapter caller, swap caller, composer, buyer, buyer, none, keeper, none, funder.
 */
export const activity = onchainTable(
  "activity",
  (t) => ({
    id: t.text().primaryKey(), // txHash:logIndex
    kind: activityKind("kind").notNull(),
    creditId: t.bigint(),
    otherCreditId: t.bigint(), // credit_swapped: the credit that left the pile
    statementId: t.bigint(),
    account: t.hex(),
    amount: t.bigint(),
    amount2: t.bigint(),
    balanceToken: t.hex(), // event-time currency for balance purchases and redemption
    blockNumber: t.bigint().notNull(),
    blockTimestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({
    byKind: index().on(table.kind, table.blockNumber),
    byAccount: index().on(table.account),
    byCredit: index().on(table.creditId),
    byStatement: index().on(table.statementId),
    byOrder: index().on(table.blockNumber, table.logIndex),
  }),
);

const counters = (t: PgColumnsBuilders) => ({
  creditsBought: t.bigint().notNull().default(0n), // credit_bought plus listing_bought plus credit_adopted
  creditsEth: t.bigint().notNull().default(0n),
  creditsBalance: t.bigint().notNull().default(0n),
  creditsListing: t.bigint().notNull().default(0n),
  creditsAdopted: t.bigint().notNull().default(0n),
  creditsSwapped: t.bigint().notNull().default(0n),
  composed: t.bigint().notNull().default(0n),
  restyled: t.bigint().notNull().default(0n),
  statementsSold: t.bigint().notNull().default(0n),
  creditsSold: t.bigint().notNull().default(0n),
  redeemed: t.bigint().notNull().default(0n),
  buybacks: t.bigint().notNull().default(0n),
  ethIntoCredits: t.bigint().notNull().default(0n), // sum of EthRateFill.spent
  feesBooked: t.bigint().notNull().default(0n),
  toPayee: t.bigint().notNull().default(0n),
  toArtist: t.bigint().notNull().default(0n),
  toOperator: t.bigint().notNull().default(0n),
  ccBurned: t.bigint().notNull().default(0n), // Core buyback burns plus CreditSwapped.fee
  ethToBuybackSpent: t.bigint().notNull().default(0n), // sum of Buyback.amountIn
  balancePaidByToken: t.json().$type<Record<string, string>>().notNull().default({}), // raw units keyed by token
});

/** Singleton per Core. */
export const stats = onchainTable("stats", (t) => ({ id: t.hex().primaryKey(), ...counters(t) }));

/** The same counters per hour bucket (blockTimestamp / 3600). */
export const statsHourly = onchainTable("stats_hourly", (t) => ({ hour: t.bigint().primaryKey(), ...counters(t) }));

/** Reconciliation result every 300 blocks (docs/INDEXER.md section 8.4). */
export const parity = onchainTable("parity", (t) => ({
  blockNumber: t.bigint().primaryKey(),
  blockTimestamp: t.bigint().notNull(),
  ok: t.boolean().notNull(),
  pileSizeOk: t.boolean().notNull(),
  heldStatementsOk: t.boolean().notNull(),
  pileFirstPageOk: t.boolean().notNull(),
  ethPotOk: t.boolean().notNull(),
  detail: t.json().notNull(), // chain and indexed values compared
}));

/**
 * One row per Credits id the CreditStrategy has listed. active follows NFTBoughtByProtocol (true, listPrice set),
 * NFTSoldByProtocol and a Credits Transfer out of the strategy (false). A price change emits no event; consumers
 * re-read nftForSale(id) for the rows they use.
 */
export const strategyListing = onchainTable(
  "strategy_listing",
  (t) => ({
    id: t.bigint().primaryKey(), // credit id
    listPrice: t.bigint().notNull(), // wei, from the latest NFTBoughtByProtocol
    active: t.boolean().notNull(),
    boughtBlock: t.bigint().notNull(),
    boughtAt: t.bigint().notNull(),
    soldBlock: t.bigint(),
    soldAt: t.bigint(),
    buyer: t.hex(), // NFTSoldByProtocol.buyer; the recipient of the Transfer when that event is absent
  }),
  (table) => ({ byActive: index().on(table.active, table.listPrice) }),
);
