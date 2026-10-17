# credits engine indexer: spec

status: approved (decision 132). phases 1 and 2 and the listing sources (decision 134) are built, 2026-10-15. phase 3 waits for a page that uses it; phase 4 waits for `deployments/1.json`.

This document is the data contract between the chain, the indexer and the web app. Every value the web shows has one row in section 9 that names its source. A change that adds a value to the web adds its row here in the same change.

## 1. goals

1. The web reads history, lists, counts and slow-moving state from one indexed database. The browser keeps direct chain reads only for values that change every block or every second (section 4).
2. Every event from every engine contract is stored, including events no page uses today, so a new page is a new query and a full reindex is rare.
3. The indexer runs on free public RPC endpoints, led by Tenderly's public gateway, inside a fixed request budget, with automatic failover.
4. One deploy path for local, testnet and mainnet, driven by the deployment record (`deployments/<chainId>.json`).
5. The indexer checks itself against the chain and reports drift.

## 2. best practice this design follows

- **Index the protocol, serve the product.** Tables mirror protocol objects (credit, statement, engine, controller, activity), never page layouts. Pages compose queries over them. A redesigned page reuses the same tables.
- **Keep every log.** A `log` table stores every decoded event from every indexed address with its full arguments. Typed tables are projections of it. A feature that needs an event nobody projected yet starts from `log` and promotes it to a typed column later.
- **Events for history, calls for state without events.** State that changes without an event (pots, bid rate, balances, pool price) is read by `eth_call` at chosen blocks and stored as snapshots. Section 5 lists each one.
- **The RPC cache is the backfill budget.** Ponder stores every RPC response in its database. A schema change reindexes from the cache with near zero RPC traffic. The cache survives redeploys because it lives in Postgres.
- **One source per value at a time.** The web reads each value from one place (section 9) chosen by one app-wide mode (section 11): the indexer while it is healthy, the browser's on-chain read path otherwise. The browser keeps the on-chain read paths (`web/lib/engine.ts` log scan, `creditInfo`, `tokensOf`, `ownerOf`, `tokenURI` reads) as an automatic fallback for every indexer read (owner decision 133, 2026-10-15). They run only in fallback mode.
- **Reconcile continuously.** A job compares indexed projections with on-chain views every N blocks and exposes the result (section 8.4).
- **Data contract in the repo.** This file is the contract. `AGENTS.md` gains a rule: a change that adds web data names its source in section 9.

## 3. framework, hosting, layout

| choice | value | reason |
|---|---|---|
| framework | Ponder 0.17.x, pinned exact (the shapes indexer pins 0.17.8) | the owner's other indexers use Ponder; native reorg handling, RPC response cache, factory sources for the swappable controller, GraphQL and SQL over HTTP built in |
| database | Postgres (Fly Postgres or Neon free tier); PGlite only for local dev | the RPC cache and schema-per-deploy blue/green redeploys need a database that outlives the machine |
| host | Fly.io, region iad, shared-cpu-1x, 1 GB, one always-on machine, `/health` check | same as artcoins and shapes |
| repo path | `indexer/` at the repo root, beside `web/` | the deployment record and ABIs are in this repo |
| API | GraphQL at `/graphql`, `@ponder/client` SQL over HTTP at `/sql`, both read only and public | the frontend is public; a bearer token in the browser bundle protects nothing |
| live updates | `@ponder/client` live queries (server-sent events), verify support in the pinned version | pages update when a new block is indexed, without a polling interval |

Layout, following `shapes/indexer`:

```
indexer/
  ponder.config.ts        chains, sources, start blocks, all from the record and env
  ponder.schema.ts        tables (section 6)
  abis/                   generated from forge out/ for Core, CoreLib, ControllerV1; pinned JSON for external contracts
  src/index.ts            event handlers
  src/state.ts            block handlers for state snapshots (section 5)
  src/lib/*.ts            pure helpers (splits, price curves, eta) with node --test unit tests
  src/api/index.ts        graphql, sql client, /health/parity
  deploy.sh               one deploy path (section 10)
  fly.<env>.toml          values only
```

ABIs for Core, CoreLib and ControllerV1 are generated from `forge build` output by a script, so an event change in `src/` fails the indexer typecheck.

## 4. what the indexer serves and what stays a live read

| class | examples | source |
|---|---|---|
| history and lists | feed, credit history, statement history, held pile with order, statements by state, sales, buybacks | indexer |
| per-token facts fixed at creation | credit seed, paidAt, score, traits mask, statement credit ids, rating, composer, compose mode | indexer (read once, stored) |
| token art | credit `tokenURI`, statement `tokenURI` (refreshed after `HeldFormatSet`) | indexer |
| settings and parameters | Core settings, controller sale and credit sale params, anchor, creditCostToPotBps, locks, owner, payee, artist | indexer (event projections plus deploy-block reads) |
| aggregates | counts by kind, ETH into credits, fees booked, $CC burned (all engine burns), buy rate per hour, payee and artist received | indexer |
| state without events, minute scale | pot, toBuyback, redeemBurn, bid rate, balance rate, module available | indexer snapshots at every engine-event block and every 300 blocks; the browser snapshot keeps the current value |
| state that moves every block or second | `ethRate` climb, `bidOf`, `creditPrice`, `priceOf`, pool slot0, quotes, Chainlink, hook skim decay | browser, one multicall (`web/lib/live.ts`) and market hooks, unchanged cadence |
| wallet data | balances, allowances, approvals, the wallet's credits | browser for balances and allowances; indexer for the wallet's credits and statements (owner column) |

The browser snapshot multicall stays because a price that decays every second is cheaper to read once per 15 s than to index per block. Its inputs that rarely change (settings, controller params) move to the indexer, which shrinks the multicall.

## 5. sources

All addresses and start blocks come from `deployments/<chainId>.json`. The config throws when a required value is missing.

### 5.1 log sources

| source | address | filter | start block | events |
|---|---|---|---|---|
| Core | record `core` (CoreLib events are emitted under the Core address) | all events | record `deployBlock` | every Core and CoreLib event (inventory B1, about 35) |
| Controller | factory over Core `ControllerSet(address controller)` | all events | block of each `ControllerSet` | `Bought`, `AnchorMoved`, `SaleSet`, `CreditSaleSet`, `AnchorBpsSet`, `BalancePoolKeySet`, `QuoteSet`, `Observed` |
| CC burns | record `coin` | `Transfer` with `to = 0x0` | record `deployBlock` | all burns; attribution to the engine via the tx (Buyback tx, `CreditSwapped.fee`) |
| $BALANCE paid | Core | `BalanceRateFill.spent`, associated with preceding `CreditBought` and latest prior `BalanceModuleSet` | Core deployment | module custody, per-credit payment in log order |
| Credits | `0x97630aA70AB14ed9883B41dAfccBc11349723043` | `Transfer` | collection deploy block (to be read) | owners for every credit, engine ins and outs, migrate moves |
| Statements | `0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b` | `Transfer` | collection deploy block (to be read) | statement owners after sale |
| CreditStrategy | `0x8e607209899b5d12Bd3167a6CD0E8E11FEB053d6` (proxy) | `NFTBoughtByProtocol`, `NFTSoldByProtocol` | env `STRATEGY_START_BLOCK`; chain 1 requires it (`26037623`, the first block with code); local fork: 60000 blocks before the Core deploy block | strategy listings (6.11) |
| CC pool swaps (phase 2) | PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90` | `Swap` with topic `id = ccPoolId` | record `deployBlock` | price history, volume, 24 h change; replaces the archive `getSlot0` read |
| $BALANCE pool swaps (phase 2) | PoolManager | `Swap` with topic `id = balancePoolId` | first `BalancePoolKeySet` | price history for `valueOf` inputs |

The Credits and Statements event lists must be confirmed against the deployed contracts before build. Their source is outside this repo.

The PoolManager sources filter on the indexed pool id topic, so the endpoint returns only this pool's swaps. The artcoins indexer dropped an unfiltered PoolManager source as too heavy for public RPCs; the topic filter is the difference.

### 5.2 call sources

| what | when | calls |
|---|---|---|
| engine state snapshot | every block that holds an engine event, plus a block interval of 300 blocks (about 1 h) | one Multicall3 at that block: `ethPot`, `ethToBuyback`, `ethRedeemBurn`, `ethRate`, `floorRate`, `balanceRate`, `getEthBalance(core)`, `pileSize`, `payeeOn`, `paused`, module `available()` |
| deploy-block reads | once per Core and once per controller at its first block | Core: `artist`, `creditCostToPotBps`, `chosenComposeOn`, `minCcToChoose`, `settings`, `owner`, `payee`. Controller: all sale and credit sale params, `anchorBps`, `balancePoolKey` |
| credit facts | first time a credit id appears in any source | Credits `seedOf`, `timestampOf`; CreditScore `scoreOf`, `traitsOf`; Credits `tokenURI` |
| statement facts | `Composed` | Core `ratingOf(sid)` at the event block; Statements `tokenURI`; again after each `HeldFormatSet` |
| credit sale split | `CreditSold` | `creditCostToPotBps` from the indexed setting in force at that block (the `CreditCostToPotBpsSet` history plus the deploy read); no call needed |

Historical `eth_call` needs archive state. The RPC list in section 7 puts archive-capable endpoints first.

## 6. schema

Conventions: addresses lowercase hex; amounts `bigint` in base units; every row written from an event carries `blockNumber`, `blockTimestamp`, `txHash`, `logIndex`; enums are text with a CHECK listing the values; comments in the schema state invariants.

### 6.1 `log` (every event)

`id` (`txHash:logIndex`), `address`, `contract` (core, controller, coin, balance_token, credits, statements, pool_manager), `event` (name), `args` (json, bigints as strings), block and tx fields. Index on (`contract`, `event`, `blockNumber`).

### 6.2 `engine` (one row per Core)

addresses: `core`, `controller`, `coin`, `balanceModule`, `balanceToken`, `owner`, `pendingOwner`, `payee`, `artist`, `successor`.
flags: `paused`, `retired`, `controllerLocked`, `balanceModuleLocked`, `adaptersLocked`, `successorLocked`, `chosenComposeOn`, `payeeOn`.
values: `settings` (all fields as typed columns plus json), `creditCostToPotBps`, `minCcToChoose`, `lastBuybackBlock`.
latest snapshot: `ethPot`, `ethToBuyback`, `ethRedeemBurn`, `ethRate`, `floorRate`, `balanceRate`, `coreEthBalance`, `balanceAvailable`, `snapshotBlock`.

### 6.3 `engine_snapshot`

One row per snapshot block (section 5.2) with the snapshot fields. Drives charts and lets history views show the pot at the time of an event.

### 6.4 `setting_change`

One row per setter event (`SettingsSet`, `RateSet`, `BalanceRateSet`, `CreditCostToPotBpsSet`, `ChosenComposeOnSet`, `MinCcToChooseSet`, `PausedSet`, `PayeeSet`, `ArtistSet`, `ControllerSet`, `BalanceModuleSet`, `AdapterSet`, lock events, ownership events, controller `SaleSet`, `CreditSaleSet`, `AnchorBpsSet`, `BalancePoolKeySet`, `QuoteSet`): `name`, `before` json, `after` json. Answers "what was X at block B" without archive calls.

### 6.5 `controller`

`address`, `setBlock`, `active`, sale params (`markupBps`, `startCapBps`, `decayHours`, `anchorHalfLife`, `anchorMinCost`), credit sale params (`saleOn`, `window`, `spreadBps`, `startBps`), `anchorBps` (stored value and its block), `balancePoolKey` fields, the quote settings (`quoteRateBpsPerHour`, `quoteMaxStepBps`, `quoteTolBps`, `quoteMaxStale`, `quoteMinLiquidity`, from `QuoteSet`), and the protected price reference at the last `Observed` (`refPrice`, `refSpot`, `refTime`, decision 148).

### 6.6 `credit`

| column | meaning |
|---|---|
| `id` | token id |
| `seed`, `paidAt`, `score`, `rating` (score / 10000 as text), `mask`, `active`, `occupied`, `eights`, `band` | fixed facts; mask bit0 C, bit1 M, bit2 Y, bit3 K, set means printed |
| `owner` | from Credits `Transfer` |
| `state` | `outside`, `held`, `composed`, `sold`, `swapped_out`, `migrated` |
| `costBasis`, `acquiredAt`, `acquiredBlock`, `acquiredTx`, `acquiredHow` | `eth_bid`, `balance_bid`, `listing`, `adopted`, `swap_in`; a swap-in copies the swapped-out credit's cost and time (the event omits them) |
| `seller` | `CreditBought.from` or listing seller |
| `balancePaid` | `BalanceRateFill.spent` for a balance bid |
| `pileOrder` | sort key for pile order: insertion sequence; a swap-in takes the out credit's key; `Migrated` removes from the head |
| `statementId`, `pagePosition` | after `Composed` |
| `salePrice`, `buyer`, `toArtist`, `toOperator`, `toPot`, `toBuyback`, `costToPotBps` | after `CreditSold`, split computed with the bps in force at that block |
| `tokenUri` | art data URI |

### 6.7 `statement`

`id`, `composedAt`, `composedBlock`, `composeTx`, `composer`, `mode` (`default` or `chosen`, from the tx input selector; null for an internal call), `cost`, `composePrice`, `rating`, `format`, `state` (`held`, `sold`, `redeemed`), `owner`, `salePrice`, `buyer`, `toBuyback`, `toArtist`, `toOperator`, `toPot`, `redeemedReceived`, `tokenUri`, `formatName` (metadata `Format` attribute).

`statement_credit`: (`statementId`, `position` 0..79, `creditId`), from `Composed.ids`, in pile order.

`statement_format`: one row per `HeldFormatSet`, (`statementId`, `from`, `to`, `caller`, block fields).

`anchor_move`: one row per `AnchorMoved`.

### 6.8 `activity` (the ledger)

One row per user-visible event, newest first by (`blockNumber`, `logIndex`): `kind` (`credit_bought`, `credit_adopted`, `listing_bought`, `credit_swapped`, `composed`, `restyled`, `statement_sold`, `credit_sold`, `redeemed`, `buyback`, `fees_added`, `funded`, `escrow_collected`), `creditId`, `statementId`, `account`, `amount` (ETH wei), `amount2` (kind specific, documented per kind in the schema), block and tx fields. Index on (`kind`, `blockNumber`) and on `account`.

### 6.9 aggregates

`stats` (singleton per Core): counts per activity kind, `ethIntoCredits`, `feesBooked`, `toPayee`, `toArtist`, `toOperator`, `ccBurned` (Buyback burns plus swap-fee burns), `ethToBuybackSpent`, `balancePaidByToken` (raw-unit decimal strings keyed by lowercase token address, also hourly; currencies are never summed).

`stats_hourly`: the same counters per hour bucket, plus `creditsBought`. The buy rate for compose estimates reads the last 24 rows.

`price_hourly` (phase 2): open, high, low, close and volume for the CC pool and the $BALANCE pool, from `Swap`.

### 6.10 `account`

`address`, credits sold to the engine, statements bought, credits bought, CC burned through swaps, first and last seen. Supports a future "your activity" view.

### 6.11 `strategy_listing`

One row per Credits id the CreditStrategy has listed: `id`, `listPrice` (wei, from `NFTBoughtByProtocol`), `active`, `boughtBlock`, `boughtAt`, `soldBlock`, `soldAt`, `buyer`. `NFTBoughtByProtocol` sets `active` and clears the sold fields; `NFTSoldByProtocol` and any Credits `Transfer` out of the strategy end the listing. A price change emits no event, so consumers read `nftForSale(id)` for the rows they use. Index on (`active`, `listPrice`).

## 7. RPC plan

### 7.1 endpoints

Ordered list. The first three serve archive state, which section 5.2 needs for historical calls.

1. `https://gateway.tenderly.co/public/mainnet` (Tenderly public gateway; archive; owner's preferred endpoint)
2. `https://eth-mainnet.public.blastapi.io` (archive)
3. `https://1rpc.io/eth` (archive)
4. `https://ethereum-rpc.publicnode.com` (recent state, logs)
5. `https://eth.drpc.org` (logs, head)
6. `https://rpc.mevblocker.io` (head)
7. optional paid endpoint from `PONDER_RPC_URL_1`, appended last as a reserve; it is used only when every public endpoint fails

### 7.2 transport

```ts
// each endpoint: own rate cap, malformed-response guard, short timeout
const endpoint = (url: string, rps: number) =>
  rateLimit(guardedHttp(url), { requestsPerSecond: rps, browser: false });

rpc: fallback(
  [endpoint(TENDERLY, 8), endpoint(BLAST, 8), endpoint(ONERPC, 5), endpoint(PUBLICNODE, 10), endpoint(DRPC, 5), endpoint(MEVBLOCKER, 5)],
  { rank: false, retryCount: 0 },
)
```

`guardedHttp` is the artcoins wrapper (`artcoins-v2-site/indexer/ponder.config.ts:118-148`): `http(url, { timeout: 20_000, retryCount: 2 })` that throws on a malformed `eth_getLogs` response, so the fallback moves on. Extend it to throw on archive errors (`missing trie node`, `header not found`) so a pruned endpoint hands a historical call to the next one.

Rate caps start at the values above and are tuned by measurement (7.5). Tenderly publishes 10 units per second for its free account plan and documents no limit for the public gateway, so 8 requests per second is the starting cap.

### 7.3 chain options

| option | value | reason |
|---|---|---|
| `ethGetLogsBlockRange` | 5000 | the artcoins value; public endpoints reject larger ranges unpredictably |
| `pollingInterval` | 12000 | one check per block; Ponder fetches every block for reorg checks, so a longer interval saves nothing |
| `reorgWindow` | default 180 s | |
| `cacheRpcRequests` | true (false only for local anvil) | |

### 7.4 budget

Steady state, per 12 s block: one `eth_getBlockByNumber`, one `eth_getLogs` per log source (8 sources), plus one multicall on blocks with engine events. About 0.8 requests per second, under 10 % of the combined caps.

Backfill: the engine's history starts at its deploy block, so its sources cost about one request per 5000 blocks per source. The two collection sources start at their deploy blocks; at 5000 blocks per request a year of history is about 530 requests per source. Credit facts cost two to four calls per credit, once, batched through Multicall3. Interval snapshots cost one call per 300 blocks. A first backfill finishes in minutes at the caps; every later reindex reads from the RPC cache.

### 7.5 verification before launch

1. Probe each endpoint for archive support: `eth_getStorageAt` on the Core at a pinned old block returns a value.
2. Measure each endpoint's real limit: send `eth_blockNumber` at rising rates and record the rate where 429 responses start. Set each cap to 70 % of it.
3. Run a full backfill against mainnet with only public endpoints and log requests per endpoint, failovers and 429s. Pass: zero failed handlers, under 1 % failovers.
4. Log a warning on every failover and a counter per endpoint, so a slide onto the paid reserve shows up in logs and on `/health/rpc`.

## 8. correctness

### 8.1 reorgs

Ponder rolls back writes inside `reorgWindow`. Snapshot rows written by block handlers roll back the same way.

### 8.2 ordering facts the handlers rely on

- `EthRateFill` (in value mode `ValueRateFill`, decision 148) precedes its `CreditBought` in the same tx; a bought credit with a preceding fill in the tx is an `eth_bid`, with a `BalanceRateFill` after it a `balance_bid`.
- `Bought` (controller) and `StatementSoldTo` (Core) are one sale; the activity row comes from `StatementSoldTo`.
- `CreditSwapped`: the in credit takes the out credit's pile key, cost basis and acquisition time.
- `Migrated` moves credits with no per-id event; Credits `Transfer(core, successor)` in the same tx gives the ids.
- `Composed.ids` is in pile order; it removes those 80 credits from the pile.

### 8.3 deploy-time state

Constructor values and a new controller's constructor settings emit no event. The handler for the first event of a Core or controller reads them by call at that block.

### 8.4 reconciliation

Every 300 blocks a block handler compares projections with views at the same block and writes a `parity` row: `pileSize` vs count of held credits, `heldStatements()` vs held statements, first page of `pilePage` vs `pileOrder`, `ethPot` vs the latest snapshot. `/health/parity` returns the last row and fails when any check failed. A failing check is a bug to fix in the handler, then reindex.

### 8.5 tests

- Pure helpers (`src/lib`): unit tests with `node --test`, as in shapes.
- End to end: the local e2e flow (`script/dev/e2e.sh`) runs the indexer against anvil and asserts the parity checks pass after the scripted trades, composes and sales.

## 9. frontend data contract

Source key: **I** indexer table.column, **L** live browser read, **D** derived in the browser from the named inputs. A value marked L today that moves to I is listed with its new source. Every I row has an on-chain fallback that runs in chain mode (section 11, owner decision 133); the tables name the indexer source. Wired in phase 2: the rows below as written.

### 9.1 shared

| value | source |
|---|---|
| block number in footer | L `getBlockNumber` (existing head poll) |
| contract addresses | L snapshot (Core reads, one multicall) |
| settings, controller params | L snapshot; also I `engine.settings`, `controller` (not read by the web yet) |
| pot (live, with unbooked income) | L snapshot; D `potWithPending` |
| reserve and the room the bids read (packet B, decision 154) | L `Core.reserve()` in the snapshot; D `potRoom` = `potWithPending` less the reserve, the clamp of the eth bid and the cap of a listing sweep |
| value mode and the quote (packet C, decision 148) | L snapshot: `settings.valueModeOn`; `noQuote` when value mode is on and `ethRate` reverts `NoQuote` (the snapshot then reads the eth bid as 0); controller `valuePerPoint(false)` and `valuePerPoint(true)` for `value.usable` and the per point values; also I `controller.quote*` (QuoteSet) |
| balance token reference against spot (packet C, decision 148) | L controller `refPrice()`, `refTime()`, `spotPrice()` and `quote()` in the snapshot (`value.refPrice`, `value.spot`); shown on the balance page; also I `controller.refPrice`, `refSpot`, `refTime` at the last `Observed` |
| ETH/USD | L Chainlink |
| rating display | D `score / 10000` from I `credit.score` (chain mode: `CreditScore.scoreOf`) |
| header bid at refScore | L snapshot `ethRate` |
| header acquire button: strategy listings | I `strategy_listing` where `active`, with `credit.score`; chain mode: browser `getLogs` of the two strategy events from `NEXT_PUBLIC_STRATEGY_START_BLOCK`, replayed in log order; both re-read live at each head: `nftForSale`, Credits `ownerOf`, Core `bidOf`, `ethPot`, `retired`, `allowedAdapter` |
| header acquire button: spend cap | L `Core.spendState()` in the shortlist multicall; a listing over the bucket's remaining budget waits for the next bucket; the first candidate whose `buyListing` call simulates enables the button |
| header acquire button: OpenSea listings | server route `web/app/api/listings` (OpenSea API v2 best listings and fulfillment data of the `credits` collection, `OPENSEA_API_KEY` server only, 20 s cache), filtered by the adapter's `allowedRecipient` |

### 9.2 home

| value | source |
|---|---|
| credits held, statements held | L snapshot `pileSize`, `heldStatements` |
| $BALANCE held by engine | L module `available()` (also I `engine.balanceAvailable`, minute scale) |
| $CC burned and % | I `stats.ccBurned` (chain mode: Core buyback burns scanned, swap-fee burns not included); D % over the launch supply constant |
| explainer fee wording | L hook skim and bounty (`useHookFeeBps`); D engine share |
| statement sale split | D from I `engine.settings` |
| ledger rows | Currency is I `activity.balanceToken` for balance purchases/redemptions (chain mode: prior `BalanceModuleSet` in log order); amount is `BalanceRateFill.spent` per credit or `StatementRedeemed.received`. Historical metadata is used only for the matching token, otherwise show exact raw units and token address. I `activity` joined to `statement`, `statement_format` and `log`; score and plates by id from I `credit` (`useScores`, `useCreditTraits`); art from I `credit.tokenUri`, `statement.tokenUri`; paged by row limit |
| next credit progress | D pot over bid from L snapshot |
| next statement progress | L snapshot `pileSize` mod 80 |

### 9.3 credits index

| value | source |
|---|---|
| held credits, newest first, paged | I `credit` where `held`, order `pileOrder` (no 200 cap; chain mode keeps the `pilePage` cap) |
| price per credit | L `creditPrice(id)` for every held credit (the pile is bounded by compose) |
| paid, got by, bought time, rating | I `credit` |
| buy rate per hour | I `stats_hourly` last 24 hourly buckets |
| compose estimate | D from I pile position, pile size, `controller.window`, `saleOn`, buy rate |
| header meta: bid at rating | L `ethRate` |

### 9.4 credit detail

| value | source |
|---|---|
| facts, holder, history | I `credit` (cost, time, how, tx, owner), `activity` where `creditId` or `otherCreditId`, `statement` for the composed step |
| plates | I `credit.mask` |
| prev / next | I neighbours by `pileOrder` |
| price curve | D from I `costBasis`, `acquiredAt`, `controller` params; L `valueOf(score)` for the floor (live pool term) |
| sold split | I `credit.salePrice`, `toArtist`, `toOperator`, `toPot`, `toBuyback` (chain mode: archive read in `useCreditCostToPotAt`) |
| composes into statement N | I next statement id (`stats.composed + 1` cross-checked with Statements supply) |
| swap panel: wallet credits with rating | I `credit` where `owner = wallet` (chain mode: `tokensOf`); L approvals |

### 9.5 statements index and detail

| value | source |
|---|---|
| lists by state, counts, next compose | I `statement`, `stats.composed`; D estimate |
| rating, format, format name, cost, composer, mode, credits | I `statement`, `statement_credit` |
| price, at floor, reference | L controller `priceOf`, `referenceOf`, `atFloor` for held statements (time and pool dependent) |
| price curve | D from L reference and I `controller` params, statement age (I `composedAt` and pause history from `setting_change`) |
| sold and redeemed details | I `statement`; redemption currency from I `activity.balanceToken`, captured from the prior `BalanceModuleSet` in log order; chain mode replays the same setter logs |
| history: composed, restyled, anchor moved, sold, redeemed | I `activity`, `statement_format`, `anchor_move` |
| holder | I `statement.owner` |
| art | I `statement.tokenUri` |

### 9.6 sell, compose, balance, keeper

| page | indexer | live |
|---|---|---|
| sell | wallet credits with scores (I `credit` by owner) | bids and quotes (`bidOf`, anchor slots; in value mode `balanceRate` and controller `valuePerPoint(false)`), approvals; per-credit batch fills D from the same quote reads (eth: `replayEthFills`; balance: `replayBalanceFills` over the L snapshot `balanceRate` and `balanceUnit`; value mode: `replayValueFills`); USD at the L Chainlink ETH/USD feed, the balance side through the L balance pool spot |
| compose | pile with order and window state (I) | `nextPage` readiness, CC balance |
| balance | $BALANCE price history (phase 2) | pool, quotes, module available |
| keeper | `engine.lastBuybackBlock` (I; chain mode: Core view), `stats` payouts | pots, artist, payee, head |

### 9.6a listings page

| value | source |
|---|---|
| listed credits, both venues | as the header acquire button (9.1): I `strategy_listing` where `active` (chain mode: the strategy event scan) and the `web/app/api/listings` route (200 cheapest OpenSea listings, bound `MAX_LISTINGS`, sent as `max` for the caption); one row per credit at its cheapest price |
| rating | I `credit.score`; chain mode `creditScores` |
| bid | D `ethRate * score / refScore` from the L snapshot for every row; L `bidOf`, `ownerOf` and `nftForSale` for the 100 rows nearest the bid |
| balance bid column and header line | L `Core.balanceBidOf(id)` for the 100 rows nearest the bid, in the same multicall (allowFailure, read only with a module set and `balanceBidOn`); D `score * balanceUnit * balanceRate / 10,000` for the other rows (marked ~); header "balance bid R% of par" from L snapshot `balanceRate` |
| fills today | I `stats_hourly.creditsEth` and `creditsBalance` summed over the hours since 00:00 UTC; hidden while the indexer is not serving |
| gap, counts, histogram | D price over bid |
| clears in | D `web/lib/climb.ts` (mirror of `CoreLib._climb`) from L `rateAtCheckpoint`, `checkpointTime`, `lastFillTime`, anchor storage slots 27, 29, 30, the settings and the pot less the snapshot reserve; assumes no fills and a constant pot |
| credit floor multiplier | L controller `floorMultBps()` in the snapshot (`creditFloorBps` of the snapshot): `(10,000 + creditSpreadBps)` of the Core's `balanceBidCapBps` |
| spend headroom ("pot covers N, this minute M", "next bucket" rows) | L `Core.spendState()` (bucket, budget, spent), the settings `spendCapBps`, `bucketSeconds`, `keeperFee`; D `fitsBucket` and `bucketCount` in `web/lib/acquire.ts`; the same read decides the header button |
| acquire action | L `Core.buyListing`, simulated before the header button enables and again before sending, shared with the header button (`useAcquireTx`) |

### 9.7 swap panel

Live only: slot0, quoter, hook fee, balances, allowances, receipts. Phase 2 adds I `price_hourly` for a 24 h change and a chart, replacing the archive `getSlot0` read.

### 9.8 page metadata and share images

Server side (`web/lib/meta.ts`), cached 60 s, each source under a 2.5 s timeout. The indexer is read first; the chain second.

| field | source |
|---|---|
| credit and statement title, rating, state, format name | I `credit`, `statement` row (`score`, `rating`, `state`, `formatName`) |
| token art of the share image | I `tokenUri`; L `tokenURI` when the row is absent |
| held and composed counts on the index share images | I count of `credit` rows in `held`, count of `statement` rows |

## 10. deploy

One path, as in shapes PR #59 and the owner's deploy rule:

- `indexer/deploy.sh <env>` reads `deployments/<chainId>.json` (Core, deploy block, coin, collections, pool key) and `indexer/env/<env>.env` (values only: chain id, Fly app, RPC caps, database schema name).
- It refuses when the record is missing, when the database schema name was already used for a different Core address (tracked in `indexer/deployments.json`), or when a required value is empty. `DRY_RUN=1` runs every check without deploying.
- Each deploy starts under a new `DATABASE_SCHEMA` and the public API switches to it after the backfill is ready (`/ready`), so a reindex never takes the site down.
- After deploy it probes `/health`, `/ready`, `/graphql` and `/health/parity`.
- Local: `script/dev` starts the indexer against anvil with PGlite and `cacheRpcRequests: false`, reading `deployments/31337.json`.

Prerequisites before mainnet: `deployments/1.json` with the mainnet Core, deploy block, controller block and module block; the collection deploy blocks.

## 11. web changes

The browser keeps the on-chain read paths as an automatic fallback for every indexer read (owner decision 133, 2026-10-15). Nothing may break while the indexer is down.

1. `NEXT_PUBLIC_INDEXER_URL` (`web/scripts/local-env.mjs` writes `http://localhost:42169` locally) and a typed client from `@ponder/client`. The indexer schema imports the `ponder` runtime, which does not bundle for the browser, so `web/lib/indexer-schema.ts` declares the columns the web reads as drizzle tables, and a compile-time guard fails `tsc` when a column type differs from `indexer/ponder.schema.ts`.
2. One app-wide mode (`useIxMode`, set by `web/components/IndexerSync.tsx`):
   - `ix` when the indexer answers `getStatus`, is at most 5 blocks behind the chain head (`useHead`) and its count of held credits equals `Core.pileSize`; `chain` when it is unconfigured, unreachable, behind, inconsistent, or one of its queries failed in the last 5 blocks; `checking` until the first health result (no source runs).
   - Each data hook reads the indexer in `ix` mode and its on-chain path in `chain` mode, with the other path's react-query `enabled` off. A healthy indexer therefore causes no `eth_getLogs`, no per-row `getBlock` and no `tokensOf`, `ownerOf` or `tokenURI` reads. Components call one hook and never branch.
   - Hooks: `useStats`, `useFeed`, `useBuyRate`, `useCreditDetail`, `useStatementIndex`, `useStatementView` (`web/lib/data.ts`); `usePile`, `useCredit`, `useWalletCredits`, `useScores`, `useCreditTraits`, owners, `useCreditCostToPotAt` (`web/lib/live.ts`); `useTokenMeta` (`web/lib/art.ts`).
3. Live reads stay in both modes: the snapshot multicall, `creditPrice`, `priceOf`, `referenceOf`, `atFloor`, `bidOf`, `valueOf`, market hooks, balances, allowances, approvals, receipts.
4. The browser transport is `fallback([primary, Tenderly public, publicnode, llamarpc])` on mainnet (`web/lib/wagmi.ts`); local anvil is one transport.
5. Freshness: one `@ponder/client` live query (server-sent events) on `engine.snapshotBlock` invalidates the indexer queries; while the stream is down a new chain head does.
6. "history unavailable" shows only when both sources fail (indexer mode off and the browser scan failed).
7. Chain mode keeps today's limits: the pile list is the first 200 credits of `pilePage`. Values with no on-chain equivalent degrade: the credit sale split of a sold credit uses the current `creditCostToPotBps` (marked "~") when the sale block's state is unreadable; the buy rate comes from the scanned buy events; formatName comes from the `tokenURI` Format attribute.

## 12. phases

1. Core, controller, burns, collections, snapshots, `log`, `activity`, `credit`, `statement`, `stats`; parity endpoint; local e2e.
2. Web switches to the indexer (section 11); browser scan removed.
3. Pool `Swap` sources, `price_hourly`, account views.
4. Mainnet deploy after the mainnet record exists.

## 13. open items

1. Confirm the Credits and Statements event ABIs against the deployed contracts, and read both collection deploy blocks.
2. Measure the public endpoint limits (7.5) and set the caps.
3. Pick Fly Postgres or Neon.
4. Confirm `@ponder/client` live queries in the pinned Ponder version.
5. Decide whether the coin's v2 factory, hook and escrow data come from the artcoins indexer or are indexed here as well.
6. The mainnet deployment record.

Balance token replacement schema update: replay the indexer from the Core deployment to populate `activity.balanceToken` and token-keyed payout totals before serving this web version. Existing raw amounts are kept as stored. Browser scan and query cache keys are versioned so pre-replacement history is discarded.
