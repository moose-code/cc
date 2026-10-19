# Indexer audit (indexer/**, docs/INDEXER.md) at 84ea170

Scope read in full: indexer/ponder.config.ts, ponder.schema.ts, src/index.ts, src/chain.ts, src/shared.ts, src/state.ts, src/api/index.ts, src/lib/*.ts (+tests), scripts/*, deploy.sh, check-live.sh, fly.mainnet.toml, env/*, Dockerfile, .dockerignore, .env.example, README.md, abis/*.ts (event and function inventory), docs/INDEXER.md, decisions 132/133/177 (+134/163/164 for the rules the handlers cite), and the contract paths the handlers depend on (Core.sol sellForEth/buyListing/_compose/sellTo/sellCreditTo/redeemStatement/buyback/pilePage/constructor; CoreLib spend, _fillBalance/_fillOne, rescue*, adopt, swapCredit, migrate/_moveCredits; CoreOpsLib event list; ControllerV1 events). Ponder 0.17.8 runtime behaviour was verified in node_modules (build/config.js, runtime/historical.js, indexing/profile.js, server/index.js, client/index.js, utils/sql-parse.js). Not run: forge, anvil, Postgres, a live Ponder process. docs/reviews/* and STATUS.md section 1 were not read.

## Findings

### I-01  Medium  launch readiness  Two emitted events are never fetched: `TokenRescued` (Core) and `AgeEligibilitySet` (Controller)
- Where: indexer/src/index.ts (no `ponder.on("Core:TokenRescued")`, no `ponder.on("Controller:AgeEligibilitySet")`); indexer/src/chain.ts:248-288 `readController` reads no `ageEligibilityOn`; ponder.schema.ts `controller` has no column for it; docs/INDEXER.md 5.1 Controller row and 6.4 omit `AgeEligibilitySet`.
- Evidence: src/Core.sol:210 `event TokenRescued(address indexed token, address indexed to, uint256 amount)` emitted at src/lib/CoreLib.sol:847 (`rescueToken`); src/ControllerV1.sol:62/427 `emit AgeEligibilitySet(v)` in `setAgeEligibilityOn`, read at :507 to gate statement sales. Both are in the generated ABIs (abis/Core.ts has 41 events, abis/ControllerV1.ts 9). Ponder builds the `eth_getLogs` topic0 list only from registered handlers: node_modules/ponder/dist/esm/build/config.js:302-353 (`registeredLogEvents` from `indexingFunctions`, `topic0: eventSelector` per registered event). Handlers exist for 40 of 41 Core events and 8 of 9 controller events.
- Failure: goal 2 of docs/INDEXER.md ("Every event from every engine contract is stored") is false for these two; an ERC20 rescue by the owner leaves no `log` row; the controller's age gate can be flipped with no `setting_change` and no `controller` column, so a page or keeper reading `controller` sees a stale eligibility rule. Nothing fails loudly: no parity check covers either.
- Fix: add both handlers (`settingValue` for TokenRescued; `controllerSetting` plus an `ageEligibilityOn` column, also read in `readController`); add a unit test that diffs the event names in abis/Core.ts and abis/ControllerV1.ts against the `ponder.on("Core:..."/"Controller:...")` names in src/index.ts so a future event cannot be dropped silently (the typecheck does not catch this; `tsc --noEmit` passes today).

### I-02  Medium  best practice (restart safety)  Per-transaction state lives in process memory, and a crash-recovery checkpoint can fall inside a transaction
- Where: indexer/src/index.ts:26-30 (`let ethFill`, `let balanceBuy`, `const coreBurn`), used at :112-116, :131-137, :275-278.
- Evidence: Ponder commits historical batches by event count, not by block: node_modules/ponder/dist/esm/runtime/historical.js:118-121 `limit: Math.round(syncEventsQuerySize / (chains + 1)) + 6` (syncEventsQuerySize 12_000, internal/options.js:67), and on restart drops only events "that have a checkpoint earlier than (or equal to) the crash recovery checkpoint" (historical.js:~318). A checkpoint is per event, so the first event of the next run can be the `CreditBought` of a transaction whose `EthRateFill` was committed in the previous run.
- Failure: after such a restart (`ethFill === null`) the credit is written as `acquiredHow = balance_bid`, `royalty = null`, `creditsBalance` is bumped instead of `creditsEth`, and `toArtistBuys` misses the royalty; a split between `CreditBought` and `BalanceFill` leaves `balancePaid`/`balancePaidToken`/`royalty` null and `activity.amount2 = 0`; a split between `Coin:Transfer` and `Buyback` writes `activity.amount2 = 0` for the burn. All silent; the parity checks (pile size, held statements, first page, ethPot) cannot see it. Decision 177 names "retries that could ... leave stale indexer state" as in scope.
- Fix: derive the route from committed data instead of memory: in `CreditBought` query the `log` table for an `EthRateFill`/`ValueRateFill` row with the same `txHash` and a `logIndex` between the previous `CreditBought`/`ListingBought` of that tx and this one (the `log` row of the fill is written by its own handler before the batch commits); same for the Coin burn (sum of `log` rows `coin:Transfer` with the tx hash and `from = core`). Alternatively persist the three values in a small table keyed by tx hash.

### I-03  Low  best practice  `CreditSwapped` does not clear the in credit's earlier-stay columns
- Where: indexer/src/index.ts:181-195 vs `enterPile` :59-91.
- Evidence: the swap path sets `state, costBasis, acquiredAt, acquiredBlock, acquiredTx, acquiredHow, seller, balancePaid, pileOrder` only. `enterPile` additionally nulls `royalty, statementId, pagePosition, salePrice, buyer, toArtist, toOperator, toPot, toBuyback, costToPotBps`. A credit the engine sold (`sellCreditTo`, state `sold`, sale columns set) can be swapped back in by its new owner (CoreLib.sol:929-957 forbids only the return lock and lower scores).
- Failure: a row with `state = held` and non-null `salePrice/buyer/toPot` and the previous `royalty`; the credit detail "sold split" row (docs/INDEXER.md 9.4) shows a sale that is not the current stay.
- Fix: factor the field reset out of `enterPile` and call it from the swap handler.

### I-04  Low  best practice  The per-event snapshot runs before the setter projection, so the snapshot of a `BalanceModuleSet` block names the old module
- Where: indexer/src/index.ts:35-38 `coreEvent` (record, then `snapshot`) is the first line of every handler; `setting()` runs after it. indexer/src/chain.ts:84-85 and :121-122 take `balanceModule`/`balanceToken` from the engine row.
- Failure: `engine_snapshot` at the `BalanceModuleSet` block carries `balanceToken = old token` and `balanceAvailable = old module.available()` (or null) although the chain state at that block is the new module; `engine.balanceAvailable` is stale until the next Core event or Tick. One row, self-healing, but it contradicts the schema comment "changes at BalanceModuleSet" (ponder.schema.ts:108).
- Fix: in `Core:BalanceModuleSet` apply `setting()` before `snapshot()`, or move `snapshot` to the end of `coreEvent` callers.

### I-05  Low  best practice (RPC)  Inner per-endpoint retries defeat fast failover
- Where: indexer/src/lib/rpc.ts:37 `http(url, { timeout: 20_000, retryCount: 2 })`; :81-85 `fallback(..., { rank: false, retryCount: 0 })`.
- Evidence: viem's http transport retries a `TimeoutError` (no rpc code) and 429/5xx responses before rejecting, so one hung or throttled endpoint costs up to 3 x 20 s before the fallback moves on; with `rank: false` every request starts at Tenderly. docs/INDEXER.md 7.2 calls this a "short timeout". docs 10.1 already records "Unable to find available JSON-RPC provider" during a full backfill.
- Failure: realtime sync at a 12 s block time stalls for a minute per hung request; the web's 5-block lag rule (docs 11.2) flips the site to chain mode while the data is correct.
- Fix: `retryCount: 0` (or 1) and a 10 s timeout on the inner transport; leave retries to the fallback (`retryCount` on `fallback`) so the next endpoint is tried first.

### I-06  Low  security (API)  Public SQL endpoint has no visible row or time cap
- Where: indexer/src/api/index.ts:13 `app.use("/sql/*", client({ db, schema }))`.
- Evidence (verified): Ponder validates the AST (SELECT only, no system tables, single statement: node_modules/ponder/dist/esm/utils/sql-parse.js) and adds CORS `origin: "*"` (server/index.js:45). Not verified: any `statement_timeout` or row limit on the readonly pool (the only `statement_timeout` found is on the admin pool, database/index.js, 10 min). `log.args` and `tokenUri` columns hold large payloads.
- Failure: `select * from log` or a cross join from any origin occupies the single shared-cpu machine (fly.mainnet.toml: 1 cpu, 1 GB, hard_limit 30 requests). This is denial of service, not data exposure (the data is public by design, docs 3).
- Fix: set `statement_timeout` and `work_mem` on the Postgres role the indexer uses, or front the API with a rate limiter; record the choice in docs/INDEXER.md 3.

### I-07  Low  launch readiness  `/health/parity` reports freshness it does not check
- Where: indexer/src/api/index.ts:16-21.
- Evidence: the route returns 200 whenever the newest `parity` row has `ok = true`; it ignores the row's `blockNumber`/`blockTimestamp`. check-live.sh:35 treats a 200 as a pass (the age check happens only in check-service.mjs:36-40). `/ready` (Ponder) only says historical indexing finished once.
- Failure: a realtime sync that stalled days ago still answers 200 on `/health/parity`; a human or a monitor reading that route takes stale data as fresh.
- Fix: return 503 when `now - blockTimestamp` exceeds two snapshot intervals (about 2 h at 300 blocks), and say so in README.md and docs/INDEXER.md 8.4.

### I-08  Low  legibility  The `BalanceToken` source filter cannot match
- Where: indexer/ponder.config.ts:116-123 (`filter: { event: "Transfer", args: { from: CORE } }`).
- Evidence: balance payouts leave the module, not the Core: CoreLib.sol:1153-1156 pays the artist with `module.call(IBalanceModule.pay ...)`; `_fillBalance` "returns the balance token totals owed to the seller and to the artist" for the module to pay; `rescueToken` refuses the balance token (CoreLib.sol:845). Seller payout path not read line by line (partially verified).
- Failure: one `eth_getLogs` per block range for a source that writes no rows; docs/INDEXER.md 6.1 and the schema comment list `balance_token` as a `log.contract` value that never appears.
- Fix: filter on `from: <module>` (second factory parameter `balanceModule`) if module outflows are wanted, else remove the source and the enum value.

### I-09  Low  launch readiness (deploy guards)  The schema-reuse ledger exists only on the deploying machine
- Where: indexer/deploy.sh:32-39, :81-84; .gitignore:10 ignores `deployments/1.json`; `git ls-files indexer` shows no `indexer/deployments.json`.
- Failure: the guard "a DATABASE_SCHEMA already used for a different Core address" holds only for repeat deploys from one checkout; a second machine or fresh clone deploys the same `cc_mainnet_v1` schema for a new Core unchecked and a database with the old Core's rows is reused.
- Fix: commit the ledger after each deploy (the script could `git add` and print the instruction), or read `select core from <schema>.engine limit 1` from the live database when `DATABASE_URL` is available.

### I-10  Info  launch readiness  check-live.sh is prelaunch-only and compares three unpinned reads
- Where: indexer/check-live.sh:16-17 (`coinLive == false` required), :24-26 (`HEAD`, `PILE`, `POT` at three different `latest` blocks), README.md:25 calls it "read-only chain-1 service acceptance after backfill".
- Failure: after coin launch there is no scripted acceptance; a fill between the two `cast call`s yields a false "engine SQL state differs" (docs 10 says retry).
- Fix: pass `--block "$HEAD"` to both `cast call`s; drop or invert the `coinLive` gate behind a flag.

### I-11  Info  best practice  gen-abis.mjs merges CoreLib events only
- Where: indexer/scripts/gen-abis.mjs:2-3, :15-18. CoreOpsLib events (CoreOpsLib.sol:29-38) are covered only because Core.sol re-declares each of them (verified: all ten present in Core.sol:178-227).
- Fix: merge `CoreOpsLib` too and assert the union equals the event set of `out/ICore.sol/ICore.json`.

### I-12  Info  best practice  Two reads without `allowFailure` can halt indexing on a foreign implementation
- indexer/src/chain.ts:243 `refreshStatementArt` (`tokenURI` revert stops the handler; `ensureStatement` reads the same call with `allowFailure: true`); :251-268 `readController` with `allowFailure: false` assumes every future controller exposes ControllerV1's view set.
- Fix: `allowFailure: true` with null columns, as `readQuote` already does.

## Verified OK (traced)
- ABI parity: abis/Core.ts holds 41 events, equal to the 41 declared in src/Core.sol and to ICore.sol:80-137 field by field (indexed flags included); every CoreLib and CoreOpsLib event is re-declared in Core.sol, so the "library emits under the Core address" case is covered by the ABI. abis/ControllerV1.ts holds the 9 events of IControllerV1.sol:36-44. Functions the handlers call (`storedAnchorBps`, `balancePoolKey`, `quote`, `referencePrice`, `referenceTime`, `heldStatements`, `pilePage`, `settings`, `creditCostToPotBps`) exist.
- Event order the handlers rely on: `_spend` emits `EthRateFill`/`ValueRateFill` (CoreLib.sol:387, 394) before each `CreditBought` (Core.sol:705-709); `_fillOne` emits `CreditBought` (CoreLib.sol:1224) before `_fillBalance` emits `BalanceFill` (CoreLib.sol:1205); `ICoin.burn` (Core.sol:1105) precedes `Buyback` (:1116); the swap fee is `burnFrom(msg.sender)` (CoreLib.sol:940) so `Coin:Transfer` with `from = core` and `CreditSwapped.fee` never double count `ccBurned`.
- Cost basis: eth bid `cost = pay + toArtist` (Core.sol:709); listing basis `value + toArtist + paid` (Core.sol:757) equals the handler's `cost + toArtist + paid`; balance bid basis `floor * score / RATE_SCORE` from the event; swap-in inherits cost and `acquiredAt` (CoreLib.sol:944-951), handler copies `costBasis`, `acquiredAt`, `pileOrder`.
- Splits: `creditSaleSplit` equals Core.sol:1021-1026 (`min(cost*bps/BPS, rest)`); `statementPot` equals Core.sol:991-997 (`rest - toBuyback`). Unit tests assert these numbers.
- Pile replay: the pile is a doubly linked list; `_pull` preserves order, `pilePage` walks from `head` oldest first (Core.sol:1551-1562), `swapCredit` reuses the node, `_moveCredits` pops from the head (CoreLib.sol:1019-1038) and the `Credits:Transfer(core -> successor)` handler marks those `migrated`; held statements stay with the Core on migrate (CoreLib.sol migrate doc). `rescueNft` refuses Credits and held statements (CoreLib.sol:870-884), so no silent pile exit. `Composed.ids` are pulled in order (Core.sol:903-906).
- Compose mode selectors `compose()`, `compose(uint8)`, `composeChosen(uint256[80],uint8)` match Core.sol:841/846/879.
- Block pinning: `cache: "immutable"` requests go to `latest` (ponder indexing/profile.js:580) exactly as chain.ts:133-134 states; every other `context.client` read is at the event block.
- Snapshot gate: the gate keys on a persisted `engine_snapshot` row and Ponder reverts onchain tables on reorg, so no in-memory height is cached (docs 8.1 holds). Tick handler snapshots first, then compares at the same block.
- Settings columns follow events in log order (`BalanceFill` uses `engine.balanceToken` from prior `BalanceModuleSet`, never a live read); `paused` is excluded from the snapshot overwrite (chain.ts:128).
- Start blocks and guards: chain 1 requires `CREDITS_START_BLOCK`, `STATEMENTS_START_BLOCK`, `STRATEGY_START_BLOCK`, `DATABASE_URL` (ponder.config.ts:42-46, 56-61, 89); deploy.sh:30 enforces the same three; the values 26037292 / 26100733 / 26037623 agree across env/mainnet.env, README.md and docs 10.1. `CHAIN_ID` vs record `chainId` mismatch refuses to start.
- Coinless deferred state: the `Coin` source on a codeless address returns no logs; `engine.coin` comes from `Core.COIN()`; check-live.sh asserts `cast code == 0x` and `COIN()` equals the record.
- API: `/ready` is 503 until historical indexing completes (ponder server/index.js:58-66); `/health` is liveness only (fly check uses it, correct). check-service.mjs validates every CLI input with regexes before string-building SQL (no injection). No API key can leak through `/health/rpc`: only `URL.host` and the first line of viem's multi-line error message are kept (rpc.ts:36, 49-55).
- Dockerfile/.dockerignore exclude node_modules, .ponder and .env*; the image carries only indexer/ and reads all values from `-e` env (record fallback path is absent in the image, by design).
- Vocabulary: no em or en dashes, no "exit" vocabulary in indexer/** or docs/INDEXER.md; every decision number cited (102, 132, 133, 134, 147, 148, 154, 157, 159, 163, 164, 177) exists in docs/DECISIONS.md.

## Misleading tests
None found that passes while asserting the wrong rule. Notes:
- indexer/scripts/check-service.test.mjs:61-62 `state.parity.block_number = "699"; await rejectsWith("parity row failed")` exercises only the `< deployBlock` branch of check-service.mjs:37-38; the staleness branch `parity.block_number + 300 + maxBehind < head` is untested. `npm test` does not run this file (package.json `"test": "node --test src/lib/*.test.ts"`), so the "release gate" promise at line 1 is not part of the repo's test command.
- indexer/src/lib/snapshot-gate.test.ts:30 `rows.delete(42n); // Ponder rolled back` simulates the rollback by hand; the promise depends on Ponder reverting `engine_snapshot` rows, which the test cannot see (verified separately above).
- indexer/src/lib/tokenuri.test.ts covers `;utf8,` and `;base64,`; the regex at tokenuri.ts:5 rejects `data:application/json;charset=utf-8;base64,` (charset before the encoding). The Statements contract's real encoding was not verified (external contract).

## Stale comments and names

| file:line | text | why | replacement |
|---|---|---|---|
| docs/INDEXER.md:3 and 5.1, 6.9, 9.6 (balance row), 9.7 | "phases 1 and 2 ... are built"; "(phase 2)" on pool `Swap`, `price_hourly`, "$BALANCE price history (phase 2)" | section 12 puts pool sources, `price_hourly` and accounts in phase 3; phase 2 is the web switch | "(phase 3)" in 5.1, 6.9, 9.6, 9.7 |
| docs/INDEXER.md 3 layout | "src/lib/*.ts pure helpers (splits, price curves, eta)" | no price curve or eta helper exists; the files are split, mode, tokenuri, snapshot-gate, reconcile, balance-history, rpc | "(splits, compose mode, token URI, snapshot gate, reconcile, balance history, rpc transport)" |
| docs/INDEXER.md 5.1 Credits and Statements rows | "collection deploy block (to be read)" and the paragraph "event lists must be confirmed ... before build" | both blocks are known (26037292, 26100733) and the ABIs were confirmed (README "external ABIs") | the numbers, and drop the paragraph or mark it done |
| docs/INDEXER.md 5.1 Core row | "every Core and CoreLib event (inventory B1, about 35)" | 41 events; CoreOpsLib omitted | "every Core, CoreLib and CoreOpsLib event (41)" |
| docs/INDEXER.md 5.1 Controller row, 6.4 | event list without `AgeEligibilitySet` | the controller emits it (ControllerV1.sol:427) | add it (and the handler, I-01) |
| docs/INDEXER.md 5.2 statement facts | "Core `ratingOf(sid)` at the event block; Statements `tokenURI`" | chain.ts:214-228 reads Statements `creditScoreOf` (immutable, latest), `formatOf`, `tokenURI`, `ownerOf` | "Statements `creditScoreOf` (immutable), `formatOf`, `tokenURI`, `ownerOf` at the event block" |
| docs/INDEXER.md 6 conventions | "enums are text with a CHECK listing the values" | ponder.schema.ts:7-25 uses `onchainEnum` (Postgres enum types) | "enums are Postgres enum types (`onchainEnum`)" |
| docs/INDEXER.md 6.1 and indexer/ponder.schema.ts:33 | `contract` values "(core, controller, coin, balance_token, credits, statements, pool_manager)" / "core, controller, coin, balance_token, credits, statements" | `strategy` is written (shared.ts:36); `pool_manager` is not | add `strategy`; move `pool_manager` to the phase 3 note |
| docs/INDEXER.md 6.10 `account` | described as a table | not in ponder.schema.ts | label "(phase 3, not built)" |
| docs/INDEXER.md 7.2 | "`guardedHttp` is the artcoins wrapper ... Extend it to throw on archive errors" | done (rpc.ts:30-32, 48-56); the signature is `guardedHttp(url, rps)` | describe the current rpc.ts |
| docs/INDEXER.md 9.1 value mode row | "`noQuote` when value mode is on ..." | no `noQuote` identifier in web/** | the web name that holds this flag, or drop the backticks |
| docs/INDEXER.md 9.6a bid row | "D `ethRate * score / RATE_SCORE` (`RATE_SCORE` is 1,000,000 ...)" | no `RATE_SCORE` identifier in web/** (it is a Solidity constant) | name the web constant or write "the Solidity `RATE_SCORE`" |
| docs/INDEXER.md 9.9 | "recorded deployment in `docs/DEPLOY-credit-score-lens.md` at `5875fbd`" | the file does not exist at HEAD or anywhere in `git log --all` | the path that exists, or the Sourcify record alone |
| docs/INDEXER.md 13 item 1 | "Confirm the Credits and Statements event ABIs ... read both collection deploy blocks" | done (README, env/mainnet.env) | remove; item 2 (measured caps) remains open and is not evidenced in the repo |
| indexer/ponder.schema.ts:167-168 | "Fixed facts (seed to tokenUri) are read once, at the latest block" | tokenUri and owner are read at the event block (chain.ts:135-136, 169-176); only seed, paidAt, score, traits are latest | "seed, paidAt, score and traits are read once at the latest block; tokenUri and owner at the event block" |
| indexer/ponder.schema.ts:319 | `ethIntoCredits` "sum of EthRateFill.spent" | the handler also adds `ValueRateFill.spent` (index.ts:103-107) | "sum of EthRateFill.spent and ValueRateFill.spent" |
| indexer/src/state.ts:14 | "Every 300 blocks" | the interval is `SNAPSHOT_INTERVAL_BLOCKS` (default 300) | "Every SNAPSHOT_INTERVAL_BLOCKS (default 300)" |
| indexer/scripts/gen-abis.mjs:2-3 | "Core functions and events plus the CoreLib events" | CoreOpsLib also emits under the Core address (covered only by Core.sol's re-declarations) | name CoreOpsLib and merge it (I-11) |
| indexer/README.md:25 | "read-only chain-1 service acceptance after backfill" | the script refuses unless `coinLive=false` (check-live.sh:16) | "prelaunch (coinLive=false) acceptance after backfill" |

## Test results
- `cd indexer && npm ci` (NODE_USE_ENV_PROXY=1): installed, no errors.
- `npm test` (`node --test src/lib/*.test.ts`): 14 tests, 14 pass, 0 fail, 0 skipped (balance-history 2, mode 2, reconcile 2, snapshot-gate 2, split 4, tokenuri 2), 610 ms.
- `node --test scripts/check-service.test.mjs` (not part of `npm test`): 1 test, 1 pass, 11.9 s.
- `npx ponder codegen && npm run typecheck` (`tsc --noEmit`): clean.
- Not run: forge, anvil, Postgres, `ponder start`, `script/dev/check-indexer.sh` (needs a fork and Postgres).

## Unverified
- Statements `tokenURI` encoding versus the tokenuri.ts regex (external contract).
- Whether Ponder's readonly pool sets a `statement_timeout` (I-06).
- The seller payout path of `sellForBalance` (I-08 relies on the artist path and the module custody comments).
- Whether the public endpoint caps in env/mainnet.env were measured per docs 7.5 (open item 13.2 still listed).
