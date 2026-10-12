# security review of 55307c4 (owner decisions 84 to 87)

reviewer: independent read-only agent, 2026-10-12. clone `/private/tmp/sec-55307c4` at 55307c4.

## scope
`git diff 18a1aa2 55307c4 -- src script`: Core.sol, CoreLib.sol, ControllerV1.sol, CoreLens.sol, interfaces, SettingsBounds/Store, scripts and both configs. read against docs/FLOW.md rows 84 to 87 and docs/REVIEW-external-contracts.md.
runs: `forge build`; `--match-path` CoreLayout, ExitValueFloor, Redeem, SetSettings, Config, Phase2Flex, Lens (all pass); scratch PoCs in `test/SecPoC55307c4.t.sol` (5 pass). fork: tenderly public gateway, block 26158000. Credits `seedOf` was checked live: it returns a left-aligned bytes21, so the `bytes21` interface decodes it.

## findings (most severe first)

### M1. `unitPerPoint` is a snapshot, and `lockExitModule` freezes it
Core.sol:702, CoreLib.sol:584-591, Core.sol:946-957, ControllerV1.sol:254.
`unitPerPoint` is read from the module only inside `_setExitModule`. Three paths use the stored copy: the redemption minimum, the exit token bid and the controller value floor. Once `lockExitModule()` runs, `setExitModule` reverts `Locked`. After that the unit can never change again. docs/DEPLOY.md:368 says to lock the module once it is trusted.
- the module's rate falls more than `exitSlippageBps` (2%): every `exitStatement` reverts `Underpaid`. PoC `test_poc_lockedModuleStaleUnitBricksExit`: the unit is locked, the module pays 97%, the exit reverts and `setExitModule` reverts. Every held statement then has no exit path except `buy`. This is the "don't brick" case of decision 84, and the lock makes it permanent.
- the module's rate falls by any amount before the owner sets the module again: `sellForExitToken` pays the old unit. PoC `test_poc_staleUnitBidOverpays`: the unit halves, and the bid pays 0.012947 XT for a credit whose redemption now returns 0.008092 XT. That is 60% over, and the 20% margin is gone. A searcher can sell credits ahead of the owner's update and drain `xPot`. The loss per credit is `score * (oldUnit * 0.8 - newUnit)`, at most `xPot`.
- the rate rises: the value floor and the bid are understated. A buyer at `max(value, curve)` gets a statement whose redemption is worth more than the price paid.
Exploit precondition: the redemption rate of the exit token can change. FLOW 76 and 84 say it pays "by credit score"; it is not stated that the rate is fixed.
Fix: read `unitPerPoint` live from the module, with the bounded `_ask`, in `exitStatement`, `_sellForExitToken` and `_value`. Alternatively add a `refreshUnit()` that re-reads the unit from the current module and works after the lock. Keep `unit != 0 && unit <= type(uint128).max`.

### M2. the redeem burn reserve fills from launch and has no exit while phase 2 is off
Core.sol:319-322, 715-721; CoreLib.sol:422-426 (migrate leaves it); Core.sol:338 (skim excludes it).
At launch `feeToRedeemBurnBps` is 1000 and `exitMode` is 0. 10% of every fee flush goes to `ethRedeemBurn`. The only outflow is an eth lane `exitStatement`, which needs a module, `exitMode >= 1` and `atCost`. Each one moves 20% of the reserve, so 0.8^n of it stays after n redemptions. PoC `test_poc_redeemBurnStranded`: the reserve is 1.951 eth against a pot of 17.560 eth (exactly 1/9). With decision 82 (module unset) and the open risk that redemption could close, the reserve stays in the Core. `migrate` leaves it. The owner has no path that moves it to `ethToBuyback` or `ethPot`.
Fix (either): launch with `feeToRedeemBurnBps` 0 and raise it when phase 2 starts; or add an owner-only `releaseRedeemBurn(amount)` that moves the reserve into `ethToBuyback`. That function is not a withdrawal path, because the eth can only be spent by the buyback.

### L1. raising the anchor makes eligible statements ineligible again
ControllerV1.sol:267-270, 332-347, 362-380.
`atCost` uses the live curve, and the curve's start depends on the current anchor. A higher anchor lengthens the fast stage, so a statement already at cost is priced above cost again. PoC `test_poc_anchorRaiseRevokesEligibility`, launch settings: statement 1 becomes eligible. A griefer buys a fresh statement (cost 0.593 eth) at its start price of 0.890 eth, so the anchor goes 10000 to 12500. Statement 1 is then ineligible for 33 hours and `exitStatement` reverts `NotEligible`. The same applies to every held statement. Cost to the griefer is about 0.30 eth over cost per 33 h window, and the griefer keeps the statement. The engine is paid more and nothing is taken from it. This blocks redemptions and keeper payments only.
Fix (optional): store the time at which a statement first reached `atCost` and keep it eligible from then on. Or evaluate eligibility at the anchor floor (10000).

### L2. value floor: an upward pool push stops sales; a buyer's slack is taken
ControllerV1.sol:259-264, 278-290, 312-323.
The spot `sqrtPriceX96` raises the ask without limit. An in-block push of the exit token price makes `priceOf` jump. A `buy` sent with `msg.value` above the quote pays up to `msg.value` (the excess goes to the Core and the attacker gains nothing). In a thin pool, a price held high stops all sales until arbitrage restores it. `atCost` is unaffected. `mulDiv` overflows (and `priceOf` and `buy` revert) only when `rating * unit` is above about 3.4e38 at MIN_SQRT_PRICE, which needs a unit above about 2e30 per score unit; not realistic.
Fix: give `buy` a `maxPrice` argument (front-ends should send the exact quote); cap the value floor, e.g. at `startCapBps` of cost; choose the deepest pool.

### L3. the accepted lower bound holds, but its level is a setting
`buy` pays `max(value, curve)`. The curve is at least `floorBps * cost` and at least `saleFloorBps * cost` (`_quote`), and `sellTo` reverts `BelowFloor` under `cost * saleFloorBps / 1e4` (Core.sol:674). A manipulated pool can only reduce `_value` to 0. Confirmed in code: the ask falls to `max(curve, cost*saleFloorBps/1e4)` and no lower.
Max loss per statement is `V - max(curve, floor)`, with `V = rating * unitPerPoint * P_spot`. The attack is atomic: borrow the exit token via v4 flash accounting, sell it into the pool, `buy`, buy it back. It costs about 2 x pool fee x notional plus gas. Example: cost 0.593 eth and V = 1.5 x cost gives a loss of 0.297 eth per statement. This applies to every held eth lane statement with V above the curve. `saleFloorBps` and `floorBps` can each be lowered to 1000, so the floor under the bound is 10% of cost and not cost. Decision 85 keeps them adjustable.

### L4. `exitSlippageBps` is not bounded by `exitBidMarginBps`
SettingsBounds.sol:37-38. Slippage can be up to 1000 and margin can be 0. With margin below slippage, an exit lane cycle can return less than the bid paid, by up to `(slippage - margin)` of the rating value, before `Underpaid` reverts.
Fix: add the check `exitSlippageBps <= exitBidMarginBps`.

### I1. `setExitPoolKey` accepts keys that make the floor read 0
ControllerV1.sol:236-247. In v4 native eth is always currency0, so the `(token, eth)` order can never be an initialized pool. The setter also accepts an uninitialized pool. In both cases `_value` returns 0 and the floor turns off without notice.
Fix: require `c0 == 0` and a nonzero `getSlot0`.

### I2. stale comments
Core.sol:396 and 1002 say "four packed slots" (there are three). CoreLib.sol:51 says "the exit auction decay" (removed). CoreLib.sol:129 says "checkpointed both rates" (there is one rate).

### I3. Lens
`exitBidOf` (CoreLens.sol) returns a bid after `retired` and when the bid exceeds `xPot`. In both cases `sellForExitToken` reverts.

### I4. exit pile credits wait while `exitMode` is not 2
`composeExit` requires mode 2 (Core.sol:589). Credits bought into the exit pile stay there under mode 1 or 0 until mode 2 returns or `migrate` runs. The credits are not lost.

## verified correct
- exit check (Core.sol:693-724): `required` is computed before `_unhold`. The delta is measured on the exit token balance across the transfer and `exit`, and `received` (not `required`) goes to `xPot`. Rounding is down on `required`. Overflow: `rating < 2^30` times `unit <= 2^128` times 1e4 fits. The module cannot re-enter: `skim`, `sellTo` (and so `buy`), `sellForExitToken`, `compose` and the other doors are `nonReentrant`, so tokens that arrive cannot be booked twice. A module that pays more adds to `xPot`; one that pays less reverts, and the statement stays held.
- eligibility: `_atCost` is a bounded staticcall. A revert, a short answer or a gas-starved call reads as false, and only the caller is harmed. A non-0/1 answer reverts. While paused, `atCost` answers and the age is frozen. A statement on the exit lane skips the check, which matches decision 86.
- `sellForExitToken` (CoreLib.sol:577-603): gated on retired, mode 2, a nonempty list and a module. `owned` runs before the score read. A duplicate id fails `NotOwner` because the first copy moved to the Core earlier in the loop. Burned and nonexistent ids revert in `ownerOf`. A zero price reverts. The pot check runs per credit, `xPot` is written before the transfer, and `minOut` is checked. The score units match the stored rating (external review: `creditScoreOf` is the sum of `scoreOf`).
- redeem burn accounting: `receive` splits with floors, and the bounds enforce `feeToBuybackBps + feeToRedeemBurnBps <= 10000`, so the subtraction cannot underflow. A release moves value between trackers. `skim` and the lens `unbookedEth` subtract all three trackers. Solvency `balance >= ethPot + ethToBuyback + ethRedeemBurn` holds on every path read, and `_solvent` passes in Redeem.
- rating at compose: it is read after `STATEMENTS.compose`, the supply, owner and credit-count checks pass, and the `uint32` check rejects values that do not fit. The Statements callback hits the `view` `onERC721Received`. The Core approves no Statements operator, so the stored ratings cannot be overprinted.
- storage: Core order equals `CoreState` (CoreLayout passes). Settings use 3 slots: slot 0 is 248 bits, slot 1 is 240, slot 2 is 208. The `unpack` offsets match the compiler layout. The SetSettings TUPLE (23 fields), the SettingsFields indices and bounds, the DEPLOY.md jq order and 1-based indices, and the LaunchConfig reader all match the struct. mainnet.json and rehearsal.json differ only in `image` and `description`.
- removed surface: `src` and `script` have no references to xToBuyback, buybackExit, exitAfter, unitPerCredit, xRate*, the exit auction or SUPPLY.
- `_value` math for eth as currency0: `owed * Q96^2 / sqrtP^2` wei, rounded down. A zero or unset key gives 0.
- gas: in-test `priceOf` with the value floor and 1,000 pause windows uses 98,375; `atCost` uses 81,560. Cold-slot overhead is estimated at 30k to 40k, under the 200,000 lens and Core budgets.

## not examined
- the real exit module and redeem contract (not written). Whether the redemption rate can change decides how severe M1 is.
- `buyback` (unchanged): `sqrtPriceLimit` at MIN gives no slippage bound. M2 and the release on redemption add eth to that path.
- FeeRouter, the eth bid curve, `buyListing`, adopt and migrate apart from the reserve and `xPot` legs; deep invariant runs; the full suite.
