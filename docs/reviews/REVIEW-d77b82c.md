# security and acceptance review of d77b82c (delta 0d86ee7..d77b82c)

reviewer: independent, read only. clone at /private/tmp/rev-d77b82c, original worktree untouched.
scope: src, script, test, docs for owner decisions 64 to 69 (docs/DECISIONS.md last rows). previous review: docs/reviews/REVIEW-security-0d86ee7.md.
method: read src/Core.sol, src/ControllerV1.sol, src/CoreLens.sol, src/lib/*, the script and config diffs, name-diffed every test file, `forge test --match-path` per file on the fork (MAINNET_RPC_URL tenderly, FORK_BLOCK 26158000), one PoC (test/SecPoC.t.sol, untracked, in the clone).
result: no critical, high or medium finding. one low (F1), one low test gap (F2), doc drift (F3), three info.
supporting file: REVIEW-d77b82c-deleted-tests.txt (all 166 removed test functions, classified).

## part 1, findings, most severe first

### F1 (low) the anchor can be pumped for about 2,000 wei in total when the pot is empty
src/ControllerV1.sol `_moveAnchor` L200-214, with the clamp `read = price.min(pot)` (src/lib/CoreLib.sol L235) and `skim` (src/Core.sol L337).
decisions 64 and 68 (owner: "is this just griefing? if so, don't worry about it") accept a buy of a cheap statement at its start price on the stated ground that it "costs the buyer eth and takes nothing from the engine" (FLOW 68, ARCHITECTURE section 14 item 46). the ground is wrong when the pot is empty.
- `ethRate` is the pot when the pot is below the price state, so a credit sells for the pot. anyone can set the pot to 1 wei with `core.call{value:1}("")` then `skim()`, then `sellForEth([id])` pays 1 wei and books a basis of 1 wei. 80 such sells in one transaction fill a page. the launch pot is 0 until the first fee flush, so the window is open at launch and again whenever sellers drain the pot.
- PoC `test_poc_dustPotStatementsPumpTheAnchor` (fork, launch settings, pot 0): round 1 statement basis 80 wei, price 120 wei, anchor 10_000 -> 12_500. round 2 basis 140 wei, anchor 15_607. round 3 anchor 19_486. round 4 anchor 24_345, a fresh statement starts at 36_517 bps of cost. total spent by the attacker in 4 rounds: 2,150 wei. the attacker's 80 credits per round end up in the statement it buys, so the eth cost is the price in wei.
- extrapolation (1.25x per buy until the cap): 11 rounds reach `startCapBps` 100_000. a statement composed afterwards starts at 10x its cost and the fast stage takes 900 hours to reach 100 percent (`fastDecayBpsPerHour` 100), 1,000 hours to the 75 percent floor. the excess over 10_000 halves every 7 days, so a fresh statement starts at the 10x cap for about 5 days and above 8x for 7 days. statement sales then stall for weeks. no funds move. the engine keeps buying credits. recovery: owner `setAnchorBps(10_000)`.
- fix, long term: weight the anchor move by the wei cost of the sale against a reference of the page (for example move by `saleBps * cost / (cost + K)` with `K` = 80 * `RATE_START` / 4), or ignore sales of statements whose cost is under a setting. the same fix removes L2 of the previous review. if the owner keeps the acceptance, restate the ground in FLOW 68 and ARCHITECTURE item 46: the move costs the buyer the market value of the page only when the statement basis is at market scale.

### F2 (low, test gap) the 600,000 gas bound of the buyback payment has no test
src/Core.sol L751-753: `_payment(gasStart, BUYBACK_OVERHEAD_GAS, BUYBACK_GAS, ...)`. the deleted `BuybackPaymentTest::test_countedGasIsCappedAtTheBuybackGasConstant` drove counted gas past the bound with a gas burning house. no remaining test does (test/Fees.t.sol L1079 and L1109 assert counted gas under `BUYBACK_GAS / 2`; test/invariant/HandlerBase.sol L1686 checks only the upper bound of the payment). the formula is identical to 0d86ee7 (diffed), so no defect, only an unguarded line. the only external code left on the swap path is the pool and its hook; a stand-in hook that burns 3 million gas restores the test (put it in BuybackPaymentTest).

### F3 (low, docs) stale text, nothing executable
- sim/README.md L1-8, L59-100, L121-124, L228-334, L471-534 still describe the english auction, `buyOnly`, `collectSales`, `auctionDuration`, `reimburseBps` 8000 and `startBps` 11000. the header disclaims decisions 55, 61 and 62 only. add decision 68 (and 64, 65, 66, 67) to the header. sim/engine.js is current (`node sim/engine.test.mjs`: 1276 checks pass).
- docs/DECISIONS.md states "superseded text is marked in place". unmarked: decision 41 (`exitStatement` repays under `reimburseBps`, replaced by 66 and 67), 46 (rateCap 10x, replaced by 69), 50 (`idleLoosenBps` 2_000, replaced by 69), 57 (`collectSales`, house). section 9.2 L158-168 (`statementPrice`, `repriceStatement`, house `sellTo`), section 9.3 L172-179 (`buyOnly`, `startBps`; its note names `decayDuration`, itself replaced by 65), section 10.10 L311-316 and L330-336 (lens `listed`, `statementStatus`, `HOUSE()`, proceeds owed by the house). section 4 carries the one note of decision 68.
- change list item 31 (docs/NEXT.md, git history before packet 0) says the settings struct has 27 fields (26) and a largest compose of 11.4 million (measured counted gas 11,130,478 with the burning router, test_worstCaseCountedGasIsUnderTheBound; Core.sol L168 and ARCHITECTURE say 11.1 million; 13.7M is 1.23x that). item 21 still says rateCap 10 times rateStart, item 6 mentions `BadPrice`; both are history rows without a mark.
- docs/INTEGRATION.md section 7 says `exitStatement` reads no eth price; with a nonzero payment it checkpoints the price state (`_payCaller`). harmless.
- docs/RUNBOOK.md L109 says the cap is exactly 3x for every `rateStart` in the Core bounds; `rateCap` is bounded by 1e18, so the ratio holds up to `rateStart` 3.33e17.

### I1 (info) exit is allowed before the price reaches its floor
`exitAfter` 105 hours (script/config/mainnet.json 378000) against the floor at hour 150: at hour 105 the ask is 86.25 percent of cost (100 - 55 * 0.25). anyone can exit then and remove the statement from sale; with `callerFee` set the exit is paid. decision 65 says `exitAfter` is decided again at `setExitModule`, and docs/RUNBOOK.md L491 puts it in the runbook. no code change needed.

### I2 (info) caller payment bound at the largest settings
`callerMaxBaseFee` 100 gwei and `COMPOSE_GAS` 13.7M give up to 1.37 eth + 0.005 per compose (src/lib/SettingsBounds.sol L38-39), against a launch page cost of about 0.71 eth (80 * 8.9e15). counted gas is real gas plus 60,000, so the payment is at most 1.25x the real gas cost. off at launch (both 0). a cross bound (for example `callerMaxBaseFee` at most 20 gwei) would cap a typo.

### I3 (info) decision 69 is an economic setting
the measured leak numbers (4, 31, 157 eth) and the 7 hour follow time are the economic review's, not reproduced here. launch ceiling arithmetic checked: 1.1 * (1 + 0.02 n) = 2 at n = 41 intervals, 6.8 hours; the climb alone is 139 minutes.

## part 1, attacker models checked with no finding
- shared payer `_payment` (Core.sol L628-634) and `_payCaller` (L638-645): value = `min(gas + overhead, gasCap) * min(basefee, maxBaseFee) + fee`, then `min(ethPot)`. it reduces `ethPot` only (never `ethToBuyback`), checkpoints before the subtraction, and returns before any state write when the value is 0. launch settings (callerFee 0, callerMaxBaseFee 0) pay 0 at all three doors (CallerPay `test_launchSettingsPayZero`, Redeem `test_pay_launchSettingsPayZero`). the transfer is the last action under `nonReentrant`; the payee re entry test finds every door shut (`test_paidCallerFindsEveryDoorShut`). counted gas is capped (13.7M compose, 1.5M exit), so a gas burning router flush (1M forward cap), `nextPage` (500k) or exit module cannot inflate it. the payment is rate limited by 80 credits per compose and one exit per statement.
- buyback: the payment equals the 0d86ee7 formula (diff of the function body). `paid <= maxPay <= slice / 2`, `slice - spent - paid >= maxPay - paid >= 0`, no underflow. `setSlice - maxPay > 0` whenever the call passes `SliceTooSmall`.
- statement custody after the house removal: the record is created in `_compose` (held, composedAt, slot) and removed only by `_unhold`, which both `sellTo` and `exitStatement` call before the transfer. `sellTo` is `onlyController`, takes `msg.value >= cost * saleFloorBps / 10_000`, and the controller quote is lifted to the same expression. `exitStatement` for an eth lane statement needs `composedAt + exitAfter`. `rescueNft` refuses a statement while `held`; a statement returned after a sale has no record and leaves (Rescue `test_OK_aStatementThatCameBackAfterASaleLeaves`). `migrate` leaves statements and records in the Core, and `sellTo` and `exitStatement` do not check `retired` (Migrate `test_OK_aRetiredCoreStillSellsAndExitsStatements`). the Core approves nothing on Statements.
- controller: `buy` sets `_busy` first, moves the anchor before `sellTo`, refunds last; a revert in `sellTo` reverts the anchor move. `_ask` is monotone non increasing (fuzz tests pass), rounds against the buyer, clamp to the Core floor uses the same rounding. all setter orders keep markup <= cap, floor <= knee <= cap, anchor <= cap. division by `cost` is safe (cost >= 80 wei, adopt basis >= 1 wei). a front run that raises the anchor makes the victim revert or pay up to its own `msg.value`; the front runner pays the raised price, griefing without profit.
- settings repack: 26 fields, 4 slots. computed packing offsets: slot 0 holds eight uint16 (0..127), exitAfter at 128, saleToBuyback 160, exitToBuyback 176; slot 1 buybackSlice 0, buybackDelay 128, keeperFee 144, buybackMaxBaseFee 208; slot 2 x fields 0..63, xAuctionHalfLife 64, exitSliceCredits 96, rateCap 112, exitLaneToBuyback 176, feeToBuyback 192; slot 3 callerFee 0, callerMaxBaseFee 64. these equal `CoreLib.unpack` (L168-197). `Core.settings()` loads four words and forwards 0x84 bytes. `CoreState` equals the Core declaration order field by field. CoreLayout 3 pass, Flow roundtrip passes.
- immutables: Core runtime has 10 immutable ids at 27 sites (read from out/Core.sol/Core.json), matching the postflight message and `want[10]`.

## part 2, deleted tests audit
count of test and invariant functions: 1,024 at 0d86ee7, 958 at d77b82c. by function name 166 removed and 100 added (175 and 109 by Contract::function; 9 of those are suite renames such as SaleBuyOnlyTest -> SaleBuyTest with identical test names). test/Sale.t.sol is 74 -> 64 by this count (not 90 -> 64); test/Flow.t.sol is 67 -> 46 as stated.
class A = deletion correct (tested a removed function or the house), or behavior kept and covered by a renamed or re-valued test. class B = behavior still exists, coverage lost.

| file | removed | added | class | notes |
|---|---|---|---|---|
| Sale.t.sol | 33 | 23 | A | auction_*, reprice_*, flip_*, relist_*, buyOnly reserve, live bid, duration; `test_anchor_aSaleBelowTheCostLeavesTheAnchorAtTheLowerBound` -> `test_anchor_aSaleBelowTheAnchorLeavesIt`; `test_curve_durationBoundaries` -> `test_curve_rateBoundaries` |
| Flow.t.sol | 38 | 17 | A | bid_*, collect_*, sync_*, reprice_*, house_*; collect splits -> `test_sale_*` splits and `testFuzz_sale_anySplitIsExact`; `test_skim_beforeAndAfterTheSaleInEveryOrder` -> two `test_skim_*` (the skim before the sale step is not interleaved any more, minor) |
| ReviewSale.t.sol | 22 | 7 | A | reserve, reprice, house sellTo, notional cap repay -> `test_OK_exitPay_*`; `lockControllerAcceptsAControllerThatCannotPrice` -> Redeem `test_timing_independentOfTheController` |
| Redeem.t.sol | 15 | 13 | A | `test_repay_*` -> `test_pay_*` (cost cap, notional cap and ratio cases have no counterpart because the cap is removed), bid timing -> `test_timing_aBuyFirstMakesTheExitRevert` |
| ReviewFlowHouse.t.sol | 10 | 0 | A | file deleted; the 3 stranger and gas probes moved to ReviewStatements.t.sol |
| audit/FloorRaiseRace.t.sol | 7 | 0 | A | file deleted; reprice race. the raise of `saleFloorBps` now reaches held statements at once: Sale `test_floor_followsTheSettingAtOnce` |
| GasCap.t.sol | 6 | 2 | A | house, reprice, sync gas |
| SaleSmoke.t.sol | 7 | 4 | A | |
| Migrate.t.sol | 4 | 3 | A | relist, reprice, collect after retirement |
| Lifecycle.t.sol | 4 | 4 | A | |
| BidRule, Config, CoreUnit, Seaport, Lens, Fees (2), Launch, Resume, ReviewDeploy, ReviewV2Port, ReviewFlowCore, Rescue, SetSettings, Invariants | 1 to 3 each | | A | value changes (decision 69 tips, ceilings, ratio 3), house wiring, auction factory rows; invariant 03 renamed `noStatementSoldBelowTheHardFloor` |
| Fees.t.sol `BuybackPaymentTest::test_countedGasIsCappedAtTheBuybackGasConstant` | 1 | 0 | **B** | behavior: the 600,000 gas bound of the buyback payment. file: test/Fees.t.sol (BuybackPaymentTest) with a gas burning hook stand in (F2) |
| attackers/StatementBuyers.sol, invariant/HandlerHouse.sol | | | A | house bidders and house handler actions (bid, endAuction, collectSales, syncStatement, repriceStatement). `buy` action added in HandlerSale (selector 25), invariants 4, 5, 12 and 20 rewritten to the held/sold/exited model |
weakened but present: tests that moved to `ceilBps` 30_000 or `idleLoosenBps` 2_000 (CoreUnit `_wideCeiling`, Invariants fixture `wide`) exercise the climb curve off the launch values; launch values are pinned by BidRule, ReviewEcon `LaunchSettingsExactNumbers` and Config.

## part 3, acceptance (owner words from docs/DECISIONS.md)
- 64 (anchor moves up with sales, down with time, 7 day half life): code matches (`_moveAnchor`, `anchorBps` with `Halving.halve`). tests `test_anchor_*`, `floorSalesDoNotDragTheAnchor`.
- 65 (1 percent an hour to 100 percent, 0.25 percent an hour to 7_500, live settings): config fastDecay 100, knee 10000, slow 25, floor 7500; `_ask` and the controller setters; 150 percent start reaches 100 at hour 50 and the floor at hour 150; INTEGRATION examples (9,000 at hour 90) check.
- 66 and 67 (one rule, off at launch, `reimburseBps` and `reimburseCapBps` removed): matches; config callerFee 0, callerMaxBaseFee 0.
- 68 (house and auction mode removed; exit needs `exitAfter` since compose): matches. no reference to the house, `collectSales`, `syncStatement`, `repriceStatement`, `statementStatus`, `auctionDuration`, `buyOnly`, `statementPrice`, `BadPrice`, `AUCTION_FACTORY`, `HOUSE` in src, script, test (except the absence test `test_noAuctionSurfaceRemains`), config, README, DEPLOY, INTEGRATION, ARCHITECTURE. the residual ground is F1.
- 69 (launch values): `Mainnet.defaultSettings`, script/config/mainnet.json, DEPLOY table, ARCHITECTURE, sim/engine.js agree: idleLoosenBps 200, ceilBps 11_000, dropFloorBps 5_000, tipSavingsBps 2_500, tipCapBps 400, rateCap 26_700_000_000_000_000 (3 * rateStart 8.9e15); script/Checks.sol L171 `rateCap == 3 * rateStart`; Config `test_preflightRateCapIsThreeTimesRateStart`. bounds (dropFloorBps >= 5_000, idleLoosenBps >= 1, tipSavingsBps <= 2_500, tipCapBps <= 500) admit the values. the keeper is outside the repo (open launch prerequisite, NEXT 32).
- ARCHITECTURE section 1: rows for 64 to 69 are accurate. wording gap: the compose gas bound is "1.2 times 11.1 million" (13.7M is 1.23x; the test asserts at least 1.2x of 11.13M counted).

## verified correct
- build identity: BUILD_HASH_CORE, CORELIB, CONTROLLER, LENS and creation hash equal a fresh build (BuildIdentity 5 pass); `script/tools/gen-interfaces.sh --check` rc 0.
- scripts: `SetSettings.TUPLE` is 26 types in struct order; `SettingsFields` N = 26 with get, set, lo, hi, names aligned; RUNBOOK.md constructor tuple (L252, L416), jq field list (26 names, L250), the Stack tuple without `auctionFactory`, the Sale tuple `(uint16,uint32,uint16,uint32,uint16,uint16,uint32)` and the by hand index sentence (fields 8, 22 to 26) match; `LaunchConfig._loadSale`, `saleViolation` equal the controller constructor bounds; Postflight `_postSale`, `_postSettings`, `_postLibrary` and PostflightV2 allowlist were updated for the removed members; `SystemResumer` compares the remaining immutables.
- tests run, all pass: CallerPay 12, Redeem 22, BuildIdentity 5, CoreLayout 3, Config 32, SetSettings 9, Lens 11, Rescue 12, Migrate 35, Sale 64 (7 suites), Flow 46, ReviewStatements 3, PostflightSlots 8, Fees 75, GasCap 30 (1 skipped), ReviewSale 47, Lifecycle 20, CoreUnit 77, OwnerPowers 26, SaleSmoke 8, ReviewFlowCore 16, sim engine.test.mjs 1276 checks.

## not examined
- the full suite, invariants, INVARIANT_DEEP, fork lifecycle, Rehearsal (not run by rule).
- Statements contract internals (whether a composed statement can be unpacked); F1 does not depend on it.
- FeeRouter (unchanged), hook and sniper module gas, the buyback sandwich at current depth.
- the economic claims of decision 69 (leak in eth, follow time), the owner keeper, sim/index.html beyond launch defaults, project/evidence.json, script/director.py.
- the invariant handlers in detail (HandlerSale, HandlerBase) beyond the diff of Invariants.t.sol and selector wiring.
