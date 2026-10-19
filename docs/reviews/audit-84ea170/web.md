# web audit: /home/user/cc at 84ea170

Scope: `web/**` (app, components, lib, docs-sources, .env.example, README.md), `netlify.toml`, root `package.json`, `packages/engine/src/*`. Ground truth: `src/Core.sol`, `src/lib/CoreLib.sol`, `src/ControllerV1.sol`, `src/adapters/*.sol`, the generated `src/interfaces/*.sol` and the compiled ABI in `out/`. Intent: `docs/SPEC.md`, `docs/INDEXER.md` section 9, decisions 133 to 135, 173, 176, 179 to 185. No file under `/home/user/cc` was modified; no forge or anvil run. Every finding below was traced to the cited lines.

## 1. findings

| id | severity | category | where |
|---|---|---|---|
| W-01 | medium | legibility / launch readiness | `web/components/StatementLive.tsx:373,377` |
| W-02 | medium | display correctness (decision 176) | `web/app/sell/page.tsx:48,153` |
| W-03 | medium | display correctness (chain fallback, value mode) | `web/lib/events.ts:166-187` |
| W-04 | low | security | `web/app/api/listings/route.ts:176-177` |
| W-05 | low | display correctness | `web/lib/acquire.ts:26`, `web/lib/useListings.ts:571-574`, `web/lib/useAcquire.ts:90-94` |
| W-06 | low | display correctness (value mode) | `web/components/StatementLive.tsx:229-231,362` |
| W-07 | low | transaction construction / launch readiness | `web/components/StatementLive.tsx:24,295`, `web/lib/buy.ts:5,10` |
| W-08 | low | display correctness | `web/lib/live.ts:589-605`, `web/app/sell/page.tsx:62,196,239` |
| W-09 | low | best practice | `web/lib/sell.ts:56-59,138` |
| W-10 | low | legibility | `web/components/Flywheel.tsx:40,139-147` |
| W-11 | low | best practice | `web/lib/live.ts:265,296-302,316` |
| W-12 | low | launch readiness | `web/package.json:10` (`lint`), no ESLint config |
| W-13 | low | legibility (docs pages) | `web/lib/docs-content.ts:73,164,272`, `web/components/DocsPage.tsx:6` |
| W-14 | low | launch readiness | `web/lib/useAcquire.ts:296-351`, `web/components/ListingsTable.tsx:70-74` |
| W-15 | low | best practice | `packages/engine/src/snapshot.ts:109-123` |

### W-01 Statement page redeem copy says the redeemer gets $BALANCE (medium, legibility / launch readiness)

Claim: the redeem section tells a user the statement "can be redeemed for $BALANCE by its rating" and the button reads "redeem for $BALANCE", which reads as the caller receiving the tokens.

Evidence: `web/components/StatementLive.tsx:373` "once the price reaches its floor, the statement can be redeemed for {BALANCE_SYMBOL} by its rating."; `:377` label `redeem for ${BALANCE_SYMBOL}`. Contract: `Core.redeemStatement` (src/Core.sol:1041-1074) "hands a held statement to the balance module. the balance token the redemption returns stays in the module" and pays the caller only `_payCaller(...)`; `StatementBalanceModule.redeem` (src/adapters/StatementBalanceModule.sol:88-98) keeps the proceeds. Decision 183: "State that redemption leaves balance tokens in the module, while the caller may receive an ETH payment; align the Statement page action copy." The docs guides defer the redemption guide (decision 185), so this page is the only user-facing text.

Failure scenario: a holder pays gas to redeem expecting $BALANCE and receives at most the caller fee (`callerFee` 0.0003 ETH plus the capped gas refund), then reads the ledger "statement redeemed · received N $BALANCE" and looks for the tokens in their wallet.

Structural fix: change the copy to the rule: "redeem the statement into the balance module: the module receives N $BALANCE (rating x unit); the caller is paid the compose-style caller fee from the pot, not the tokens"; label the button "redeem into module" and show the expected caller payment.

### W-02 Sell page "pot" and "covers" use the gross booked pot (medium, display correctness)

Claim: the sell page head line shows `ethPot` and points covered from it, while the header, stats bar and keeper page show the buying room after the reserve and the artist royalty.

Evidence: `web/app/sell/page.tsx:48` `const pot = snap?.ethPot ?? 0n;` and `:153` `` `bid ... · pot ${eth(pot, 2)} ETH · covers ~${commas(potPoints(pot, bid))} pts` ``. Compare `web/components/EngineFeed.tsx:70-74` (`bidRoom = potRoom * 10_000 / (10_000 + buyToArtistBps)`, `potPoints(bidRoom, ethRate)`). Contract: the bid clamp is `_bidRoom` = (pages pot less reserve) / (1 + royalty) (src/lib/CoreLib.sol:626-635) and `spend` refuses `cost > ethPot - reserve` (src/lib/CoreLib.sol:359). Decision 176: "Show pot, processing reserve and buying room separately in the web, compute 'pot covers' from buying room after the artist payment"; INDEXER 9.1 names `potRoom`, `reserve`, `buyToArtistBps` as the inputs.

Failure scenario: with a 0.2 ETH pot, 0.1 ETH reserve and 2.5 percent royalty, the sell page says the pot covers twice the points the header says; a seller sizing a batch from the sell page sees later credits paid at the clamp or the batch refused `PotTooSmall`, which the page did not predict.

Structural fix: read `snap.potRoom`, `snap.reserve` and `snap.settings.buyToArtistBps` and reuse `usePotPage()` (or export the bidRoom math from one place) for the sell head line; label "buying room X · reserved Y".

### W-03 Chain-mode history has no `ValueRateFill` case (medium, display correctness in chain fallback)

Claim: in value mode the browser scan classifies every ETH-bid purchase as a $BALANCE bid.

Evidence: `web/lib/events.ts:166-169` sets `fill` only on `EthRateFill`; `:171-181` `const viaEth = fill?.tx === tx;` decides "eth bid" vs `${BALANCE_SYMBOL} bid`, increments `stats.creditsBalance` and leaves the row amount for a `BalanceFill` that never comes. Contract: `CoreLib.spend` emits `ValueRateFill(spent, rateBps, pot)` instead of `EthRateFill` while `valueModeOn` (src/lib/CoreLib.sol:375-388); `ValueRateFill` is in `engineEventsAbi` (packages/engine/src/abis.ts) so the log is decoded and ignored. Decision 133 requires the chain path to render the same values as the indexer.

Failure scenario: value mode on, indexer down: the ledger labels ETH purchases as balance purchases with a blank amount, the credit detail "got by" reads "$BALANCE bid", and `creditsBalance` counts them. Value mode is off at launch, so no launch impact.

Structural fix: handle `case "ValueRateFill"` like `EthRateFill` (set `fill = { tx, rate: a.rateBps, pot: a.pot }`) and add a history selfcheck row for it.

### W-04 Per-client rate limit keyed on a client-controlled header (low, security)

Claim: the fulfillment rate limit per client can be bypassed by rotating `X-Forwarded-For`.

Evidence: `web/app/api/listings/route.ts:176` `const client = req.headers.get("x-forwarded-for")?.split(",")[0].trim() || "unknown";` A client-supplied `X-Forwarded-For` arrives as the first entry (proxies append); each new value gets a fresh bucket of `BUCKET_BURST` 10 (`:64-75`), and `MAX_BUCKETS` eviction only recycles. The global budget (`UPSTREAM_BURST` 8, 4 per second, `:53-61`) and `MAX_FULFILL_INFLIGHT` 4 still bound OpenSea usage, and the key never reaches the browser.

Failure scenario: one attacker draining the global bucket at 4 POST/s makes every real user's fulfill request answer 503 "busy", so the header acquire button and the listings "acquire" never get params for OpenSea rows (CreditStrategy rows are unaffected). No key exposure, no cost beyond the plan's 4 POST/s.

Structural fix: key on the platform's trusted client address (`x-nf-client-connection-ip` on Netlify, else the last `X-Forwarded-For` hop) and keep the global bucket; the `listings-route.test.mjs` stub already passes a two-hop header and should assert the trusted hop.

### W-05 "clears" ignores the artist royalty the Core adds to the quote (low, display correctness)

Claim: a listing is shown as clearing when `price <= potRoom`, but the Core requires `value + value * buyToArtistBps / 10_000 <= room`.

Evidence: `web/lib/acquire.ts:26` `.filter((l) => l.price > 0n && l.price <= l.bid && l.price <= pot)`; `web/lib/useListings.ts:571` `r.price <= pot`; `web/lib/useAcquire.ts:90-94` `spendCost` adds only the fixed fee. Contract: src/Core.sol:737-739 `uint256 toArtist = value * s.settings.buyToArtistBps / BPS; ... if (value + toArtist > room) revert PotTooSmall();` and `:759` `_spend(value + toArtist + paid, score)`.

Failure scenario: a row priced in `(room / 1.025, room]` shows "clears" and an acquire button; `simulateContract` rejects it, the row is dropped for the block and the user sees "no listing available". Under a capped bucket the "this minute M" count and `waiting` are slightly high. No funds move.

Structural fix: carry `buyToArtistBps` into `clearing`/`spendCost` (`price * (10_000 + bps) / 10_000 <= pot`) and include the royalty in the booked cost.

### W-06 Statement curve floor in value mode (low, display correctness)

Claim: the price curve floor and the start clamp use `saleFloorBps` in every mode.

Evidence: `web/components/StatementLive.tsx:229-231` `startBps = Math.max(statementStartBps, saleFloorBps)`, `floor = reference * saleFloorBps / 10000`. Contract: `ControllerV1._quote` (src/ControllerV1.sol:629) prices with floor `cfg.valueModeOn ? BPS : cfg.saleFloorBps`, then `max(price, cost * saleFloorBps / BPS)`. `RedeemSection` (`:362`) derives "opens at floor" from the same decay. Value mode is off at launch; `saleFloorBps` is 10,000 at launch, so the two coincide today and diverge only if the owner lowers `saleFloorBps` while value mode is on.

Structural fix: `const floorBps = snap.settings.valueModeOn ? 10_000 : snap.settings.saleFloorBps` and show the cost floor line when it dominates.

### W-07 Buy buffers can be below the reference climb (low, transaction construction)

Claim: `buy` sends price + 1 percent and `buyCredit(s)` price + 2 percent, while a mode-off ask can rise about 2 percent a minute.

Evidence: `web/components/StatementLive.tsx:24` `BUFFER_BPS = 100n`, `:295` `value: s.price + s.price * BUFFER_BPS / 10000n` where `s.price` is the `priceOf` of the last 15 s multicall; `web/lib/buy.ts:5,10` `BUFFER_BPS = 200n`. Contract: the mode-off reference is `max(cost, valueOf(rating))` with `valueOf = floorRate * rating / RATE_SCORE` (src/ControllerV1.sol:470-493) and `floorRate` follows the climb (`climbPerMinBps` 200, `recoveryClimbPerMinBps` 200 per SPEC section 3); a credit floor is `max(cost, valueOf(score)) * floorMult` (`:544-557`). `buy`/`buyCredit` revert `Underpaid` and refund the excess otherwise (`:525,594,615`), so the failure is a wasted gas fee, never an overpayment.

Failure scenario: a statement whose reference is the climbing `valueOf` term, quoted 15 s ago and included 30 s later during a 2 percent per minute climb, reverts `Underpaid`; the page shows the raw error name.

Structural fix: re-read `priceOf`/`creditPrice` inside the `steps` just before `write` (the sell path already re-quotes at click time), and size the buffer from `climbPerMinBps` and the block interval, or state the caveat next to the button.

### W-08 Sell page $BALANCE figures ignore the module's `available()` bound (low, display correctness)

Claim: the per-credit and batch $BALANCE figures are the posted payout even when the module cannot pay it.

Evidence: `web/lib/live.ts:589-605` `balanceFills` replays `replayBalanceFills` from `balanceRate`, `balanceUnit`, `ethPrice`, `perPointSell` only; `web/app/sell/page.tsx:62` `balanceForId`, `:445` minOut from `balanceQuote`. Contract: `CoreLib._balancePayout` returns 0 when `pay + royalty > available()` (src/lib/CoreLib.sol:1268-1278, decision 159 C05) and `_fillBalance` reverts `PotTooSmall` once the running payouts plus royalties pass `avail` (`:1196-1207`). The snapshot already carries `balanceAvailable`.

Failure scenario: module holding 100 tokens, three credits posted at 50 each: the page shows 150 receivable and "approve & sell"; `estimateContractGas` fails before the wallet with `PotTooSmall` (rendered as the bare name by `txError`). No funds move.

Structural fix: fold `snap.balanceAvailable` into `balanceFills` (stop at the credit whose payout plus `buyToArtistBps` passes the remaining available, mark the rest 0 as `balanceBidOf` does) and disable the button with "module can pay N of the selected".

### W-09 Minute-anchor replay omits the zero-start reset (low, best practice)

Claim: `replayEthFills` resets the minute start only on a bucket change or a price under the floor; the contract also resets when `minuteStartRate == 0`.

Evidence: `web/lib/sell.ts:56-59` `if (bucket !== a.nowBucket || r < (start * a.dropFloorBps) / 10000n)`; contract `CoreLib._drop` (src/lib/CoreLib.sol:806) `if (bucket != a.minuteBucket || a.minuteStartRate == 0 || price < ...)`. `replayValueFills` (`:138`) assumes `start = a.rate`. The zero case arises after `_rebaseBucket` clears the start of the live bucket on a `bucketSeconds` edit (`:343-349`). The error is bounded by `dropFloorBps` (1 bps at launch) of the price, inside the 0.5 percent `minOut` margin.

Structural fix: add `|| start === 0n` and read the shared instance's `minuteStartRate` word for the value replay.

### W-10 Flywheel sale split omits the artist and operator cuts (low, legibility)

Claim: the home explainer says 75 percent of statement sales return to the pot and 25 percent burn $CC.

Evidence: `web/components/Flywheel.tsx:40` `split = { buyback: saleToBuybackBps, pot: 10000 - saleToBuybackBps }`, rendered at `:139-147` as "% of statement sales back to the pot". Contract `Core.sellTo` (src/Core.sol:990-998) takes `saleToArtistBps` and `saleToOperatorBps` off the payment first, then `saleToBuybackBps` of the rest; at launch values 72.75 / 24.25 / 3 percent, which `web/lib/sale-split.ts` computes and `StatementLive.tsx:240,300-303` shows. The two pages disagree by 2.25 points.

Structural fix: use `statementSaleSplit(snap.settings)` in the Flywheel.

### W-11 `valueOf` read per held statement has no consumer (low, best practice)

Evidence: `web/lib/live.ts:296-302` runs one `valueOf(rating)` multicall per held statement every 15 s when `balanceOn`, stored as `HeldStatement.value` (`:265,316`); no component reads `.value` (grep over `web/components`, `web/app`). `web/README.md:36` still lists "rating value" as a shown figure. Dead RPC work in the hot statements query.

Structural fix: remove the read or show the value on the statement page.

### W-12 `npm run lint` cannot run (low, launch readiness)

Evidence: `web/package.json:10` `"lint": "next lint"`; there is no `.eslintrc*` in `web/` or the root, so `next lint` opens an interactive configuration prompt and exits 1 (tool run below). Nothing in CI can rely on it.

Structural fix: commit `web/.eslintrc.json` (`{"extends": "next/core-web-vitals"}`) or drop the script.

### W-13 Docs page inaccuracies (low, legibility)

(a) `web/lib/docs-content.ts:164` "call Core.compose() for its chosen format": `compose()` picks `keccak256(prevrandao, ids[0]) % 8` (src/Core.sol:838-856); the controller's `format` is unused. Say "a random format".
(b) `:272` `migrate(uint256 amount)` "Move the bid pot and pile": the parameter is `maxCredits`; `migrate` moves `ethPot` and up to `maxCredits` credits per call, repeatable, and retires on the first call (src/lib/CoreLib.sol:982-1006).
(c) `:73` `spendState()` "Remaining ETH purchase budget": it returns the bucket's `budget` and `spent`; remaining is `budget - spent` (src/lib/CoreLib.sol:401-407).
(d) `web/components/DocsPage.tsx:6` pins source links to `08e2102`; since then `ICore.sol` changed parameter names only (`git diff 08e2102 HEAD -- src/interfaces/`), so no signature drift, but the pin should move with each release.
(e) INDEXER 9.9 says the CreditScoreLens address comes from `docs/DEPLOY-credit-score-lens.md` at `5875fbd`; neither the file nor the commit exists in this repository's history (`git log --all`, `git cat-file -t 5875fbd`). Sourcify confirms `0x7a3f3967cBB63E8d56e3f093069C62A25eebBda6` as `CreditScoreLens` with creation and runtime match (verified 2026-10-13), so the page is right, but the repository cannot reproduce it. Commit the record or cite the Sourcify match.
No docs page references `lockRecipients`, `lockAllowlist`, `renounceAdmin`, `unrestrict` or any coin function (grep over `web/`); the balance module and redemption guides are absent as decision 185 requires; the Docs link is in the footer (`web/components/Footer.tsx:84`).

### W-14 Acquire shows no expected caller payment (low, launch readiness)

Evidence: `web/lib/useAcquire.ts:296-351` and `web/components/ListingsTable.tsx:70-74` offer "acquire" with the listing price only. Contract: the caller is paid `min(gas * min(basefee, keeperMaxBaseFee) + keeperFee, bid - value, room - value - toArtist)` (src/Core.sol:756-758); with `keeperMaxBaseFee` 5 gwei and a listing at the bid, the refund can be far below the gas spent. The docs lifecycle page warns generally ("Do not assume a keeper reward exceeds transaction gas").

Failure scenario: a visitor clicks acquire on a row with `price` equal to `bid` at a 20 gwei basefee, pays about 400,000 gas and receives 0 from the pot.

Structural fix: compute the bound `min(bid - price, keeperFee + estimatedGas * min(basefee, keeperMaxBaseFee))` next to the button and warn when it is below the gas estimate.

### W-15 Silent defaults in the snapshot's tolerant reads (low, best practice)

Evidence: `packages/engine/src/snapshot.ts:120-123` default `climbMultiplier` to 1x, `reserve` to 0 and `ethRate`/`ethPrice` to 0 when the second multicall fails; `potRoom` then equals the whole pot and every bid reads 0. The comment (`:104-106`) explains the tolerance as support for a "pre-128 Core", which no deployment target is. A transient failure of that batch renders a wrong room and "pot covers 0" for one 15 s window rather than an unknown.

Structural fix: make the four reads `allowFailure: false` with the first batch, or surface `undefined` and render "—".

## 2. verified OK

ABI drift (item 5). `coreAbi.settings` and `SettingsSet` in `packages/engine/src/abis.ts` carry 39 fields in the order of `Settings` (src/interfaces/Interfaces.sol) and equal the compiled `out/Core.sol/Core.json` ABI (dumped: 39 components, same names and widths); `web/scripts/cap-selfcheck.ts:267-273` asserts 39 and the appended tail. The task's "37" and `docs/SPEC.md:133` ("37 fields ... eight fields from spendCapBps") are stale: ten fields follow `spendCapBps` inclusive; the web matches the contract. `Sale` (6) and `Quote` (6) match `setSale`/`setQuote` tuples; the web reads `quote()` as a 6-tuple, `markupBps`, `startCapBps`, `decayHours`, `anchorBps`, `startBps`, `floorMultBps`, `creditStartBps` as single getters. Every event the web decodes (`CreditBought`, `EthRateFill`, `ValueRateFill`, `BalanceFill`, `ListingBought`, `CreditAdopted`, `CreditSwapped`, `Composed`, `HeldFormatSet`, `StatementSoldTo`, `CreditSold`, `StatementRedeemed`, `Buyback`, `FeesAdded`, `Funded`, `SettingsSet`, `PausedSet`, `PayeeSet`, `ArtistSet`, `ControllerSet`, `BalanceModuleSet`, `Bought`, `AnchorMoved`) matches the compiled Core and Controller event list; every error matches (`Reentrant` is the controller's, `Reentrancy` solady's). Only drift: `controllerAbi` declares `refreshReference()` without `returns (bool)` (src/ControllerV1.sol:277); used only as a write, harmless. `hookAbi.skimConfig`/`poolInfo` tuples match `IArtCoinsHookV2.SkimConfig`/`PoolInfo` field order. `basicOrderParameters` has the 18 fields of `BasicOrderParameters` in `src/interfaces/ISeaport.sol` order.

Display versus contracts (item 1). `bidOf`/`ethRate`: header per point `ethRate / 100` = `ethPerPoint` (src/Core.sol:492); shortlist and listings estimates `ethRate * score / 1_000_000` with floor division = `bidForScore` (`:488`); `SCORE_PER_100_POINTS` = `RATE_SCORE`. Pot, reserve, room: `pendingIncome` reproduces `Core._income`/`_split` and `CoreLib._ethPagesPot` (payee share, then `feeToRedeemBurnBps`); `potRoom = potWithPending - reserve`; header "pot covers" divides by `1 + buyToArtistBps` (decision 176); StatsBar and keeper show pot, buying room and reserve separately. `spendState`: `spendRoom`/`fitsBucket` mirror `CoreLib.spend` (first purchase of a bucket passes, later `spent + cost > budget` reverts, 10,000 bypasses). `creditPrice` and `priceOf` are live reads every 15 s in both modes; the credit curve (`max(cost, valueOf) * floorMultBps`, `start = floor * creditStartBps`, linear over `creditWindow`) and the mode-off statement curve (`max(startBps, saleFloorBps)` to `saleFloorBps` over `decayHours`) match `ControllerV1._creditPrice`/`_ask`. `replayEthFills` reproduces `_sellForEth`: one checkpoint, per credit `min(price state, room / (1 + royalty)) * score / RATE_SCORE`, `_spend(pay + toArtist)`, the one-rounding fall, the minute floor, the peak and `ceilBps` cap, `rateCap` (edge in W-09). `replayValueFills` reproduces `_valueRate` (`bps * v * 100 / BPS` capped at `rateCap`) and the shared-instance drop floored at `10_000 - balanceBidMarginBps`. `replayBalanceFills` reproduces `_fillOne`: posted `score * unit * (10_000 - balanceDiscountBps) / 10_000`; in value mode the cap `ethPrice * score / RATE_SCORE * 1e18 / pSell` is computed through `valuePerPoint(true)` rounded up, so the web figure is at or below `balanceClampFor` (conservative); a missing or zero sale price pays 0 and the sell button reads "balance quote unavailable" (decision 173 item 2). `statementAge` is read from the Core (pause-excluded) and `liveAge` freezes while paused; `atFloor` is the controller's answer. Pause: sell, buy, compose, swap, buyback and acquire are gated on `snap.paused`; restyle and redeem are not, which matches `setHeldFormat` (callable while paused, src/Core.sol:860-871) and `redeemStatement` (no pause check). `useCoinLive` polls `getCode` every 15 s until the coin has code and then stops (decision 173 item 3); TradePanel, market and footer gate on it. Compose ETA: a full page waits for the newest credit's `acquiredAt + window` (the `nextPage` rule, src/ControllerV1.sol:712-723), window 0 while the sale is off (`pastWindow` true).

Transaction construction (item 2). `sellForEth(ids, minOut)`: ids in list order equal the quote order, `minOut` 99.5 percent of a click-time pinned replay, `setApprovalForAll(core, true)` only when not approved; `sellForBalance(ids, minOut, expectedToken)` pins the snapshot token; `buy`/`buyCredit`/`buyCredits` forward value with refund (W-07 on the margin); `swapCredit(inId, outId)` in the contract's argument order after `approve(core, fee)` (the Core burns with `burnFrom(msg.sender, fee)`) and the collection approval; `setHeldFormat(sid, uint8)` gated on `minCcToChoose`; `composeChosen(uint256[80], uint8)` only from credits past their window. `buyListing(adapter, id, params)`: the route encodes `BasicOrderParameters` in ISeaport order, accepts only `fulfillBasicOrder_efficient_6GL6yc` to Seaport 1.6, Credits token, amount 1, native consideration, order type 0 or 1, every extra recipient the offerer or live `allowedRecipient` of the adapter, and requires `considerationAmount + sum(additional) == tx.value`, the same `value` the adapter returns; candidates are simulated before the button enables and again before `write`; `useTx` runs `estimateContractGas` before the wallet so a reverting call is never signed. Swap panel: Permit2 and ERC20 approvals only when short, deadline from the pending block, `minOut` from the quoter with the stored slippage.

Server route (item 3). Key read server-side only; empty answer when the key, adapter or Core is unset; hash validated by regex; SSRF: fixed `api.opensea.io` base, slug constant, cursor URL-encoded, RPC URL from env; list cache 20 s shared per instance, fulfill cache 10 s LRU bounded at 200; global token bucket plus in-flight cap (`listings-route.test.mjs` asserts 404 without upstream POST, cache hits, 429 at the 11th burst, 8 then 4 per second globally with `Retry-After`); errors are wrapped as `skipped` strings, no stack or upstream body leaks. W-04 is the one gap.

Chain fallback (item 4). `IndexerSync` sets chain mode when `NEXT_PUBLIC_INDEXER_URL`, `NEXT_PUBLIC_CORE` or `NEXT_PUBLIC_DEPLOY_BLOCK` is unset, the health query fails, the indexer is more than 5 blocks behind the head, its chain id, Core, coin or deploy block differ, its held count differs from `pileSize`, or any `ix` query errored (5-block quarantine). Every indexer hook has a chain path with the other path's query disabled: home ledger and stats (log scan), credits (`pilePage` 200 with the "additional forming pages unavailable" note), credit detail (scan plus `creditInfo`), statements (scan plus the held multicall), sell (`tokensOf`), compose (`pilePage`), keeper (`lastBuybackBlock` view), listings and header (strategy `getLogs` from `STRATEGY_START_BLOCK` plus the route), balance (live only), docs (static), art (`tokenURI` multicall), page metadata (indexer then chain). Stale data: in ix mode rows are at most 5 blocks old and every price, bid, pot and age is a live read; "fills today" is hidden in chain mode; the chain scan is anchored by block hash and cleared on a reorg or restart. `npm run build` prerenders every static route with the engine unconfigured ("engine not deployed").

Tests (item 7). `selfcheck.ts`, `cap-selfcheck.ts`, `v4-selfcheck.ts`, `history-selfcheck.ts`, `listings-route.test.mjs`, `indexer-health.test.mjs` and `docs-selfcheck.mjs` pass and assert what their comments promise (the balance history test does exercise same-block token replacement, the cap test the 39-field decode at maximum width). No misleading test found; `climb-xcheck.ts` needs a live RPC and was not run.

## 3. stale comments and names

| file:line | text | why stale | fix |
|---|---|---|---|
| `web/components/StatementLive.tsx:151,388` | `ExitSection` | exit vocabulary (decision 102: "balance", never "exit") | rename `SoldOrRedeemedSection` |
| `web/lib/climb.ts:2-4` | `CoreLib._climb (src/lib/CoreLib.sol:334-356), _recover (:371-386) and _climbTo (:392-396) ... Core.ethRate / bidOf (src/Core.sol:458-470)` | now CoreLib 703-733, 758-779, 783-789; Core 482-500 | cite function names only |
| `web/README.md:3-7` | "Every value comes from the chain ... one incremental event scan" | indexer first, chain fallback since decisions 132/133 | describe the two modes |
| `web/README.md:31` | "`npm run check` runs scripts/selfcheck.ts ... and scripts/v4-selfcheck.ts" | `check` runs seven scripts | list them or point at package.json |
| `web/README.md:58` | "A sweep of a listing (buyListing) is a keeper action and has no page." | header acquire button and `/listings` (decisions 134, 135); table lacks `/listings` | add the row |
| `web/README.md:61` | "reads all 34 Core settings"; "100 bps per 60 seconds at launch" | 39 fields; launch `spendCapBps` is 10,000 (bypass, SPEC section 3), 100 bps is the dev scenario (decision 140) | correct both |
| `web/.env.example:17` | "unset, the pages show live state and mark history as unavailable" | chain scan is the fallback (decision 133); `NEXT_PUBLIC_STRATEGY_START_BLOCK` (config.ts:44, netlify.toml) missing | update, add the variable |
| `packages/engine/src/snapshot.ts:104-106` | "a pre-128 Core without the view" | no such deployment target; the tolerance hides failures (W-15) | drop |
| `web/app/sell/page.tsx:442-443` | "minOut replays the per-credit drop from the snapshot over the sell order, like the eth quote" | the posted balance bid has no drop (decision 164) | "minOut is 99.5 percent of the flat posted total" |
| `web/lib/sell.ts:78-80,119-123` | `BalanceReplay.dropPer100PointsBps`, `dropFloorBps`, `floorBps` "kept for the callers' shape" | unused fields | remove from the type and callers |
| `web/lib/live.ts:26`, `web/lib/useAcquire.ts:63` | "ponytail:" | private jargon for a known cap | "cap:" |
| `web/components/Flywheel.tsx:27`, `StatementLive.tsx:25-26`, `app/credits/[id]/page.tsx:158-159` | `TODO` notes referencing a design README open item | open work items in shipped UI | resolve or move to STATUS |
| `web/lib/indexer.ts:91` | `ccBurned: Core buyback burns plus swap fee burns` | chain mode counts buyback burns only (INDEXER 9.2) | say so in `data.ts useStats` |
| `web/components/DocsPage.tsx:6`, INDEXER 9.9 | source pin `08e2102`; lens record `docs/DEPLOY-credit-score-lens.md` at `5875fbd` | HEAD is `84ea170`; the record and commit are absent from this repository | move the pin per release; commit the record (W-13) |
| `packages/engine/src/abis.ts:151` | `"function refreshReference()"` (controller) | contract returns `bool` | add `returns (bool)` |
| `docs/SPEC.md:133` (out of scope, noted) | "The Settings tuple has 37 fields ... The eight fields from spendCapBps" | 39 fields, ten from `spendCapBps` | correct |

## 4. tool results

| command | result |
|---|---|
| `cd /home/user/cc && npm ci` | exit 0 |
| `web: npm run check` | pass: `selfcheck ok`, `climb selfcheck ok`, `cap selfcheck ok`, `all v4 encoder checks passed`, `history selfcheck ok`, `listings-route test ok`, indexer-health 1/1, `check:schema` (`tsc -p scripts/tsconfig.guard.json`) clean |
| `web: npm run check:docs` | pass: "docs catalog matches generated interfaces", "docs: 8 routes and contract reference names verified" |
| `web: npx tsc --noEmit -p tsconfig.json` | exit 0 |
| `web: npm run lint` | fails: no ESLint config, `next lint` opens an interactive prompt and exits 1 (W-12) |
| `web: NODE_USE_ENV_PROXY=1 npm run build` | exit 0; 29 routes, Google font fetched through the proxy, `.next` removed afterwards |
| `node` dump of `out/Core.sol/Core.json` and `out/ControllerV1.sol/ControllerV1.json` ABIs | `settings` 39 components; function, event and error lists compared with `packages/engine/src/abis.ts` (section 2) |
| `git diff --stat 08e2102 HEAD -- src/interfaces/` | ICore parameter names only; ICoreLib, ICoreOpsLib, Interfaces.sol changed (not referenced by the docs pages) |
| Sourcify `GET /server/v2/contract/1/0x7a3f3967cBB63E8d56e3f093069C62A25eebBda6` | `CreditScoreLens`, creationMatch and runtimeMatch `match`, verified 2026-10-13 |
| `web/scripts/climb-xcheck.ts` | not run (needs a live RPC and `.env.local`) |
