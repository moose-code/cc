# test suite and simulator audit, main 84ea170

scope: test/** (every .t.sol, utils, standins, attackers, invariant, audit, data) and sim/**. ground truth: src/Core.sol, src/lib/CoreLib.sol, src/lib/CoreOpsLib.sol, src/ControllerV1.sol, src/adapters/StatementBalanceModule.sol, docs/SPEC.md (sections 3 to 13), docs/DECISIONS.md section 11, docs/RUNBOOK.md (upstream token behavior). static review only; no forge or anvil run. one node invocation of `sim/market.mjs --spendcap` was made to confirm T-03 (output kept at `/tmp/claude-0/-home-user/221119c3-ace1-539b-80d3-3386d3108a03/scratchpad/spendcap.json`). the candidate suite log at `scratchpad/logs/suite.log` had only compiled and run test/CallerPay.t.sol (8 passed) at the time of reading. the working tree holds an untracked `test/audit/AuditFindings.t.sol` (01:24 today) that is not part of 84ea170; it is noted under T-13 and not counted as suite evidence.

severity: Critical, High, Medium, Low, Info. category: security | best practice | legibility | launch readiness.

## findings

### T-01 High, launch readiness: the adversarial owner erases the launch mechanisms from every invariant campaign

file: test/invariant/HandlerOwner.sol:51-93 (`_genSettings`), 218-247 (`setSettings`); test/invariant/InvariantFixture.sol:371-381 (every suite lists `HandlerOwner.setSettings`).

claim: SPEC 13 says the invariants run "against the real system" and section 11 that the hard rule holds "whatever settings the owner chooses"; the suites are read as covering the artist royalty (decision 163), the balance discount (164), the return lock and the reserve (155) under fuzz.

evidence: `_genSettings` starts from a fresh `Settings memory s` and assigns 36 fields; a grep of HandlerOwner.sol and Handler.sol for `buyToArtistBps`, `balanceDiscountBps`, `returnLockSeconds`, `reserveWei`, `valueModeOn` returns nothing. so the first successful `setSettings` action in any suite writes `buyToArtistBps = 0`, `balanceDiscountBps = 0` (the balance bid at par), `returnLockSeconds = 0`, `reserveWei = 0`, `valueModeOn = false`, and they stay there (the generator never copies `cur` for those fields; `_firstViolation` 263-296 does not mention them either). the hostile owner suite lists the action six times (InvariantsPhase2.t.sol:70-73), so the launch values survive only the first few calls of each run.

why it matters: invariants 1, 2, 7, 16, 19, 21 and 21b (royalty in the outflow, the room over `1 + royalty`, the lock refusal, the reserve floor, the discounted payout) are checked almost entirely in a configuration that differs from launch in four settings, and the no-profit round trip that depends on the return lock (SPEC 8) is never under fuzz with the lock on. the handler's own model reads the live settings (`_hasZeroSpend` adds `buyToArtistBps`, `_pickBalanceIds` reads the discount), so nothing fails; coverage is what is lost.

fix: fuzz the five fields over their bounds in `_genSettings` (`buyToArtistBps` 0 to 1,000, `balanceDiscountBps` 0 to 9,999, `returnLockSeconds` 0 to a day, `reserveWei` 0 to 1 ether, `valueModeOn` only when the quote is usable) and add corners that force the launch values; add the five to `_firstViolation`.

### T-02 High, legibility and launch readiness: sim/engine.js does not model the funded clock (decision 176) or the paused bid clock (decision 178)

file: sim/engine.js:484-507 (`priceRate`), 471-479 (`stepCeil`), 421-423 (`peakAt`), 554-557 (`checkpoint`, `syncFunded`), 1614 (the only reader of `funded`); sim/engine.test.mjs:173-183, 99-117.

claim: sim/README.md line 3 "`engine.js` models Core, CoreLib and ControllerV1"; SPEC 13 "the simulator (sim/) models the same rules"; engine.test.mjs:173 "promise: funded flag: the pot affords one credit at the rate".

evidence, contract: CoreLib.sol:607-620 `_ethClimb` sets `paused = bookedRoom < c.anchor.lastFillRate` where `bookedRoom = (ethPot - reserve) * BPS / (BPS + buyToArtistBps)` and passes `block.timestamp` as both the anchor time and the checkpoint time while paused (no climb, no idle steps); `_climb` 715-716 uses `growthNow = c.paused ? c.pausedSince : nowTs` for the peak, the idle and the climb.

evidence, sim: `syncFunded() { this.funded = this.ethPot * W >= this.rateAtCheckpoint; }` compares the whole pot (no reserve, no royalty) with the climbing checkpoint rate (not `lastFillRate`), and `funded` is read only by the statistics counter at line 1614. `priceRate` climbs from `checkpointTime` toward `min(cap, clamp())` with no funded or paused gate; `stepCeil` counts `floor((now - lastFillTime) / idleStepSeconds)` steps on wall time; `peakAt` halves on wall time; `setPaused` (776-782) touches only the pause bookkeeping. consequences: (a) with booked room between the dropped rate and `lastFillRate` the sim climbs while the Core pauses; (b) an unfunded interval adds idle loosening steps in the sim and none in the Core; (c) during an owner pause the sim keeps climbing and decaying the peak while the Core freezes both at `pausedSince`. engine.test.mjs tests the flag's value (173-183) and the pause's effect on the statement ask (99-117) and never the bid clock, so the model tests cannot see the gap.

why it matters: the exposure numbers the owner relies on (SPEC 4, decisions 146, 149, 151) come from this model; after 176 and 178 the model overstates the climb of an underfunded or paused engine.

fix: port `_ethClimb` to the model: `funded = room(ethPot) >= lastPaidRate` with the reserve and royalty adjustment, anchor time `max(lastFillTime, climbRestartTime)` reset to `now` while unfunded, a `climbRestartTime` set on the funding crossing, and `growthNow = paused ? pausedSince : now` in `priceRate`, `stepCeil` and `peakAt`; add a promise test for each.

### T-03 High, legibility: `sim/market.mjs --spendcap` sells nothing since decision 145 removed `refScore`

file: sim/market.mjs:275 (`bid * score * 1e4 / core.s.refScore >= askAt(t)`), 13 (an unused `REFSCORE` constant); sim/README.md:21 and "Run and verify" ("12 bounded exposure scenarios"); sim/page.ui1.js:26, 78, 143, 240 and sim/page.ui4.js:26 (a `refScore` control and scenario), sim/page.ui.test.js:30-31 (asserts the control exists).

evidence: `node -e "import('./sim/engine.js')..."` prints `core.s.refScore = undefined` (SETTINGS has no such field since 145). a fresh run of `node sim/market.mjs --spendcap` returns twelve rows with `"credits": 0` and `"unmarketableBlocks": 1800` in every row (the NaN comparison is always false). the README still presents the command as the exposure study behind decision 129, and the browser page carries a dead `refScore` slider whose test asserts its presence.

why it matters: the study cannot be rerun to check any later retune; anyone who runs it reads "no seller clears" as a result.

fix: `bid * pts * 1e4 / RATE_SCORE` at market.mjs:275 (the per point rule); delete `REFSCORE`; drop the `refScore` control, its scenario and the assertion; update README line 21 (launch `spendCapBps` is 10,000, decision 146, not 100).

### T-04 Medium, legibility: invariant 4 encodes the mock's custody of a redeemed statement, not the production module's

file: test/invariant/Invariants.t.sol:124-126; test/invariant/HandlerBase.sol:2932-2935.

claim: "4. every statement ever composed is, at all times, exactly one of: held by the core, sold or redeemed".

evidence: `assertEq(o, address(s.module), "an redeemed statement is not with the module that took it")`. the production module approves the token and calls `token.withdraw(statementId, expected)` (StatementBalanceModule.sol:85-87) and test/UpstreamBalance.t.sol:207 asserts `STATEMENTS.ownerOf(sid) == address(balanceToken)` after a real redemption. the handler's revert branch likewise treats `_ownerOf(sid) == address(module)` as the only legal departure (HandlerBase.sol:2933).

why it matters: the invariant is a statement about MockBalanceModule.redeem (which keeps the statement and mints); it could not be pointed at the production module without changing it, and its wording claims a general rule.

fix: assert the statement is no longer the Core's and not recorded as held, and accept owner in {module, balanceToken}.

### T-05 Medium, launch readiness: the balance stand ins omit or contradict the production module and token

file: test/standins/MockBalanceModule.sol, test/standins/MockBalanceToken.sol versus src/adapters/StatementBalanceModule.sol and docs/RUNBOOK.md:417-429.

| behavior | production | mock | where the production behavior is tested |
|---|---|---|---|
| `available()` | 0 until `totalRetired == launchRetirement` and `block.timestamp >= opensAt`, then balance less `totalOwed` (lines 94-104) | the holding, or `setAvailable` override; never gated, never net of owed (lines 86-88) | StatementBalanceModule.t.sol:266-296 (doubles), UpstreamBalance.t.sol:165-195 (skippable), LaunchDayPhase2 |
| `pay(to, amount)` | `onlyCore`; reverts `InsufficientAvailable` above `available()`; forwards all gas but 60,000; a short or failed transfer accrues `owed[to]`, `totalOwed`, `PaymentAccrued` (109-126) | any caller; no bound; `transfer(to, amount * payOutBps / 10_000)` (91-93) | StatementBalanceModule.t.sol:317-366, UpstreamBalance.t.sol:273-343 |
| `claim(to)` | permissionless, pays owed with full gas | absent | StatementBalanceModule.t.sol:354 |
| `redeem(sid)` | approves the token, `withdraw(sid, quote)`, requires out >= `rating * 1e14`, else `RedeemedBelowRating`; the token takes the statement | mints `rating * unit * payBps / 10_000` to itself, keeps the statement, optional gas burn and callout (113-126) | StatementBalanceModule.t.sol:242-265, UpstreamBalance.t.sol:175-250 |
| `unitPerPoint` | constant 1e14 | mutable, 1e10 in Fixture (`UNIT`), revertable, gas burning | StatementBalanceModule.t.sol:200-231 |
| `migrateReserve` | moves the unowed balance to the successor's bound module after retirement | absent | StatementBalanceModule.t.sol:368-520, UpstreamBalance.t.sol:345 |
| token transfer | Jack's token runs a renderer callback inside `transfer` (about 300,000 gas cold, RUNBOOK 427) | plain solady ERC20 with `transferMode` and `banned` switches | UpstreamBalance.t.sol:291-343 only |

consequences: (1) the `ARTIST_PAY_GAS` 600,000 bound and the owed accrual path of the Core's balance royalty (decision 166) are reached with real gas only in UpstreamBalance.t.sol, which skips when `out/upstream-balance.json` is absent (see the skip table). (2) magnitudes: at `UNIT` 1e10 a 433 point credit pays 4.33e16 base units; at 1e14 it pays 4.33e20. the fixture funds the module with 1e24 (Fixture.sol:754) and the invariant fixture with 1e20 (InvariantFixture.sol:229), which at the production unit cover about 2,300 and 0.23 credits; the balance `PotTooSmall` at production magnitude is reached only through `setAvailable` (BalanceFlat.t.sol:151-203, ColdAudit.t.sol:258). (3) overflow headroom of `score * unit * cap` style products at 1e14 is exercised only by OwnerPowers.t.sol:163 (`uint128.max + 1` refusal) and the handlers' units up to 5e10 (HandlerOwner.sol:578-597), never at 1e14 under fuzz. (4) the mock `pay` without `onlyCore` and without the `available()` revert means the Core's ordering (its own running total check before `pay`) is never confronted with a module that refuses.

fix: give the mock an `opensAt`/retired gate and an `owed` ledger behind a switch, default `UNIT` to 1e14 in the invariant fixture with module funding sized to it, and route at least one invariant suite through `StatementBalanceModule` with the `BalanceGateTokenDouble` of StatementBalanceModule.t.sol.

### T-06 Medium, best practice: invariant 6 and the pause tests cannot see a pause that shifts the funded restart past the last fill

file: src/lib/CoreOpsLib.sol:56-68; src/lib/CoreLib.sol:616; test/invariant/HandlerBase.sol:736-806 (`_rs`, `_modelPrice`); test/Pause.t.sol:229-248.

evidence: on resume `setPaused` shifts `climbRestartTime` and the two peak times by the pause length but leaves the eth `lastFillTime` where it was (only `balance.lastFillTime` is shifted, line 64). `_ethClimb` anchors the idle loosening at `max(lastFillTime, climbRestartTime)`. with a funded restart at T_r, a fill at T_f > T_r, a pause of length E that starts after the fill and T_r + E > T_f, the resumed idle is `now - (T_r + E)` while an unpaused run at the same unpaused age has `now_c - T_f`; the difference is `T_f - T_r`, idle the fill had reset. the invariant model does not compute the intended rule: `_rs` reads `restart` from Core storage slot 10 (`s.restart = uint64(vm.load(slot 10) >> 128)`) and `_modelPrice` uses `s.lastFill.max(s.restart)` as the Core does, so inv 6 follows whatever the contract shifted. Pause.t.sol:229 ("paused time cannot raise the bid") funds, waits 11 minutes and pauses with no fill between the restart and the pause, so the asymmetric branch (`climbStart < since` with a later fill) is not exercised; Pause.t.sol:250-290 likewise.

why it matters: decision 178 ("neither mode-off nor value-mode bid growth earns paused time") is the owner's statement; the suite's model restates the implementation's clock shift instead of the decision, so a shift error would pass inv 6 and the Pause suite. the untracked test/audit/AuditFindings.t.sol `test_pauseDoesNotAddIdleLooseningSteps` targets exactly this shape; it is not in the candidate and I did not run it.

fix: in `_modelPrice`, derive the restart from the handler's own ghost (the last funding crossing plus the pause lengths that followed it, which the handler already tracks in `HandlerSale._checkPauseClock`), not from slot 10; add a Pause test with fund, fill one hour later, pause, resume, and compare the price state with an unpaused control at equal unpaused idle (and the same for the value instance, whose `lastFillTime` is shifted and whose peak is shifted, an asymmetry with the eth instance worth a unit test either way).

### T-07 Medium, launch readiness: fixture realism and the rules only the overriding suites exercise

file: test/utils/Fixture.sol:59-65 (`OPEN_RATE` 1.732e15, `UNIT` 1e10), 172-188 (`reserveWei` 0, `saleOn` false), 751-757 (`_enterPhase2`).

the shared fixture differs from launch in four places (rate 1.732e15 vs 4.9e15; `reserveWei` 0 vs 1e17; credit sale off vs on; module unit 1e10 vs 1e14). rules therefore exercised only in the suites that override:

| rule | suites at the launch value |
|---|---|
| reserve floor 0.1 eth, `PotTooSmall` at or under it, room = pot less reserve | Reserve.t.sol (`_settings` 18-21), BidRule.t.sol:329, 358, 408 (inline), ClampDifferential.t.sol:24, ColdAudit.t.sol:381 and `ColdLaunchMatrixTest` (641), LaunchDay.t.sol:36 (`Mainnet.defaultSettings()`), ValueMode.t.sol:162, 859-929, Flow/Config launch asserts |
| opening rate 4.9e15 and the 3x cap | LaunchDay.t.sol:28, ColdAudit.t.sol:633, BidRule.t.sol:331-333 (`setRate(0.0049 ether)`), Config.t.sol:88 |
| credit sale on, four hour window, compose waits | LaunchDay.t.sol:32 and 531-550, ColdAudit `ColdLaunchMatrixTest`, CreditSale.t.sol:416-424 and ChosenCompose.t.sol:115-122 (switched on in the test), Flow launch asserts |
| module unit 1e14, `available()` gates, owed accrual | StatementBalanceModule.t.sol (doubles), UpstreamBalance.t.sol (skippable), LaunchDayPhase2.t.sol (requires the artifact) |

the five launch critical paths named in the brief, traced:

| path | launch value test | gap |
|---|---|---|
| funded clock threshold, booked pot 0.1050225 eth | BidRule.t.sol:326-345 asserts `threshold == 0.1050225 ether` and the one wei edge at 375-383; Reserve.t.sol:63-100 at 0.11 eth | none at the threshold; the empty interval and refill at 385-403 run at the fixture rate |
| reserve and `PotTooSmall` | Reserve.t.sol:122-160 (reserveWei 0.1, royalty 250) | `test_sellForEthKeepsTheReserve` 137-148 swallows every revert and never asserts a sale went through, so it also passes when nothing sells (see T-08) |
| four hour compose wait | LaunchDay.t.sol:531-550 (`nextPage` not ready inside the window, ready after), CoreUnit.t.sol:623-665 `NotReady`, CreditSale.t.sol:416-424 `composeChosen` | `compose()` itself refusing inside the window at launch settings is asserted only through `nextPage` in LaunchDay; the CoreUnit `NotReady` tests run at the fixture rate with the sale toggled on in the test |
| artist royalty under the room clamp | ArtistRoyalty.t.sol:140-163 (clamp over 1.025) and 228-237 run with "the fixture reserve is 0" (comment at 143); BidRule.t.sol:326-345 and Reserve.t.sol:150-160 combine royalty 250 and reserve 0.1 | the royalty and reserve combination is not in the ArtistRoyalty file itself; adequate overall |
| real module `available()` gates | StatementBalanceModule.t.sol:266-316 with `BalanceGateTokenDouble` (always runs), UpstreamBalance.t.sol:165-195 (skips without the artifact), LaunchDayPhase2.t.sol:26-44 (`require(vm.exists(...))`, fails without it) | the gates at Jack's bytecode run only when the candidate run builds the artifact; the default suite passes the doubles only |

fix: set `REQUIRE_UPSTREAM_BALANCE=1` in the candidate command (skip table) and move `test_sellForEthKeepsTheReserve` to an explicit count of successful sells.

### T-08 Low, best practice: tests whose assertion is weaker than their name or promise

| file:line | promise or name | assertion | what it proves |
|---|---|---|---|
| test/V2Port.t.sol:105-110 | "collectEscrow reverts with the escrow error when nothing is owed" | `vm.expectRevert(); core.collectEscrow();` | any revert passes; the escrow error is not checked |
| test/V2Port.t.sol:52-53 | "nobody can send it elsewhere" | `vm.expectRevert(); ESCROW.claimTo(...)` by a stranger | any revert, including a wrong argument, passes |
| test/Reserve.t.sol:137-148 | "an eth purchase never takes the pot under the reserve" | `try core.sellForEth(_one(ids[i])) {} catch {}` then `assertGe(core.ethPot(), core.reserve())` | holds vacuously when every sale reverts; no success count |
| test/CoreUnit.t.sol:267-275 | the "not approved" branch | `vm.expectRevert(); core.sellForEth(_one(id));` | a `PotTooSmall` or `ReturnLocked` would pass as "not approved" |
| test/UpstreamBalance.t.sol:329-331 | `pay` above available reverts | `vm.expectRevert(); m.pay(seller, funded - amount + 1);` | the module has `InsufficientAvailable`; not checked |
| test/CreditSale.t.sol:471-481 | "Reentrancy on buyCredit" | `vm.expectRevert(); attacker.buy(ids[0], pay);` | any failure of the outer buy passes; the post state assert (pile size 2) keeps the test meaningful |
| test/Lock.t.sol:111-121 | "the run stops before it sends when the postflight has a failed row" | `vm.expectRevert(); probe.run();` | a revert for another reason also passes; `assertFalse(coin.locked())` keeps the outcome |
| test/Resume.t.sol:309-312 | "the preflight rows of the launch step refuse the same factory" | bare `vm.expectRevert()` after two selector checks | the launch-step refusal reason is not checked |
| test/Fees.t.sol:817-820, 833-835 | the restricted coin refuses the rescue | bare `vm.expectRevert()` on an external token revert | acceptable for an external revert; a selector or message would pin it |
| test/Sale.t.sol:450-454, test/Adopt.t.sol:111-114, test/BuildIdentity.t.sol:170-172 | refund refusal, nonexistent id, assertion failure | bare `vm.expectRevert()` | acceptable: the revert originates outside the Core or is an assertion |

no assertion with a tolerance wide enough to disable its rule was found; the `assertApproxEq*` tolerances (BidRule 2 bps, Fees 2 to 3 wei or 0.005 eth on a 0.89 eth figure, ValueMode 1e12 to 2e16 relative, V2Port 2 to 5 percent on skim legs) are tight relative to the quantities.

### T-09 Low, best practice: invariant 14 has a reachable violating state in three of the nine suites only

file: test/invariant/HandlerBase.sol:2970-2987 (`moduleMode` sets `payBps`, `revertUnit`, `unitPerPoint` only), test/invariant/HandlerSale.sol:817-851 (`_callout` is the only `setCall`), test/invariant/Invariants.t.sol:288-298.

evidence: `MockBalanceModule.calledOk` is set only when `callTarget != 0`; `setCall` is reached only from `HandlerSale.hostileOwner`, listed when `_saleActions()` is true (InvariantsSale.t.sol:22-24). in InvariantsPhase2, InvariantsHostileController and InvariantsHostileOwner no module ever calls out, so `invariant_14` cannot fail there. SPEC 13 reads as if the fourteen run in all nine. (test/Redeem.t.sol:409 covers the rule as a unit test.)

fix: add a `moduleMode` branch that arms a callout, or state in SPEC 13 that inv 14 is enforced by the three sale suites.

### T-10 Low, legibility: the balance side invariant suites run in the runbook's hazard state and still carry the removed value floor in their comments

file: test/invariant/InvariantFixture.sol:138-160.

evidence: `_ownerSetup` sets `balanceBidOn = true`, leaves `valueModeOn` false and sets a balance pool key: the state RUNBOOK.md:78 calls "the hazard state" that `check-post.sh` fails on. the comments at 145-146 and 154-155 explain the pool as pricing "the statement value floor and the credit sale baseline" and "the decision 87 value floor", a rule decision 170 removed (with value mode off the pool prices nothing). the suites still exercise the balance route, which is useful, but no invariant there checks a third party round trip (ModeOffDifferential.t.sol:210-225 covers it as a unit test), so the state's known hazard is not what the suite measures.

fix: rewrite the two comments; add a sentence to the suite header that the state is the pre-switch hazard state by design and name the test that covers its round trip.

### T-11 Low, legibility: the handler keeps the rising balance instance model that decision 164 retired

file: test/invariant/HandlerBase.sol:2714-2745 (`_availBps`, `_availBpsRaw`, `_balanceBidState` reading `BAL_RATE_SLOT`, `BAL_CP_SLOT`, `BAL_ANCHOR_SLOT`).

evidence: the three helpers build a `BidModel.Bid` for the "balance instance price state" with the clamp "set to `availBps`"; no action calls `_balanceBidState` or `_availBps` (grep over test/invariant shows only their definitions), and the live checks use the posted rate (`_balanceExpected` 2749-2754, `_afterSellBalance` 2825-2854). dead model code for a removed rule, next to the live one.

fix: delete the three helpers and the slot constants, or move them to the value mode suite if the shared instance is to be modelled there.

### T-12 Info, legibility: fixture helper comments that state removed rules

file: test/utils/Fixture.sol:174 ("budget tests retain launch enforcement explicitly", launch bypasses since decision 146), 389-394 (`_fundPot`: "5.90 percent" then "5.31 percent ... less the 10 percent redeem burn share", `feeToRedeemBurnBps` is 0 at launch), 765-767 (`_setBalancePool`: "decision 92", "decision 87 value floor", removed by 170), 801 (`_makeEligible`: "over 50 hours", `decayHours` is 4), 59 (`OPEN_RATE` "wei per credit", the unit is wei per 100 points). listed in the stale table below.

### T-13 Info, launch readiness: an untracked audit test file in the working tree

file: test/audit/AuditFindings.t.sol (untracked, 141 lines, written 01:24 today).

it reproduces three suspected Core defects (an absorbing zero rate under `dropFloorBps` 1 at a wei scale rate, the pause idle loosening shift of T-06, and a frozen value mode fallback through a quote outage). it is not in 84ea170, it was not run here, and its contract claims belong to the contracts review; the candidate run must either include or exclude it explicitly, since a whole-suite run picks it up.

## coverage table, SPEC section 13 invariants

suites: P1 InvariantsPhase1, P1W Phase1Window, P2 Phase2, HC HostileController, HO HostileOwner, S1/S2/S3 the sale suites, V InvariantsValue. "reachable" means the handler can drive a state that would make the check fail.

| # | invariant | enforcing function(s) | reachable violating state | notes |
|---|---|---|---|---|
| 1 | eth leaves only by allowed paths | `invariant_01_ethOnlyLeavesByAllowedPaths` (codes 1, 2, 3, 4, 6, 17, 18, 19, 23); `invariant_v01` | yes, every suite: fills, listings, compose, buyback, migrate, forced eth | after the first owner `setSettings` the royalty is 0 (T-01), so the royalty leg is checked only early in a run |
| 2 | no credit above the read | `invariant_02_noCreditAboveTheRead` (code 5); `invariant_v02` | yes | same caveat on the royalty-adjusted room |
| 3 | no statement below the hard floor | `invariant_03_noStatementSoldBelowTheHardFloor`; `invariant_v03` | yes in S1, S2, S3 (`ownerSell`, `buy` at a short value); P1 to HO have `buy` only | |
| 4 | every statement in one place | `invariant_04_everyStatementIsInExactlyOnePlace` | yes | the redeemed branch asserts mock custody (T-04) |
| 5 | pots never exceed balances | `invariant_05_potsNeverExceedBalances`, `_solvent` in unit suites | yes | |
| 6 | the rate follows the model | `invariant_06_rateFollowsTheModel` (`_rsCheck`, `_modelPrice`) | partly: the model reads `climbRestartTime` from Core storage (T-06); funded clock and pause are modelled; `dropFloorBps` is generated 5,000 to 10,000 (HandlerOwner.sol:54), so the launch no-floor compounding drop runs only until the first owner action; `setRate` and `rateCap` can reach 1 wei (corner 17), so a near zero rate is reachable by the owner, not by fills | pause and unpause reach inv 6 only in S1, S2, S3 |
| 7 | no spend above the pot | `invariant_07_noSpendAboveThePot` (code 13); `invariant_v07` | yes | |
| 8 | owner and controllers never gain | `invariant_08_ownerAndControllersNeverGain` (codes 14, 15, 16, 24, 25) | yes: probe calls, hostile listing target, settings corners | |
| 9 | coin supply falls only by burns | `invariant_09_coinSupplyOnlyFallsByBurns` (code 22) | yes: real pool buyback and `swapCredit` burn | real pool used for every buyback (`_afterBuyback` reads the skim events) |
| 10 | receive never reverts for the hook; plain send reverts `UseFund` | `invariant_10_receiveNeverReverts` (code 21) | yes: `donate` modes 0, 2, 3 | |
| 11 | no unexpected reverts | `invariant_11_noUnexpectedReverts` | yes; the per action refusal models decide what is expected | a sell refused `PotTooSmall`/`ZeroAmount` is accepted only when `_hasZeroSpend` reproduces it (HandlerBase.sol:1514-1538) |
| 12 | a statement leaves only by sale or redemption | `invariant_12_aStatementOnlyLeavesByASaleOrARedemption` (codes 7, 8, 26) | yes in S1 to S3; P1 to HO via `buy` and `redeemStatement` | |
| 13 | locks, retirement and handovers never come undone | `invariant_13_locksAndHandoversNeverComeUndone`, `lockCheck`, `formerOwnersCheck`, `test_aRetiredCoreRefusesTheSixDoorActions` | yes: `migrate`, `lockDoor`, `handover` in S1 to S3; `migrate` everywhere | |
| 14 | no call from inside a redemption ever worked | `invariant_14_noCallFromInsideARedemptionEverWorked` | only S2 and S3 (`hostileOwner` arms `setCall`); P2, HC, HO have no armed module (T-09) | |
| 16 | the bid remains open ... | `invariant_16_theBidNeverCloses`, `invariant_v16`, `test_theBidCheckFindsASeller` | yes; skips when retired, paused, or no actor's first four credits are affordable | spend cap refusal is modelled; the return lock is accepted as a non closure |
| 17 | every credit in one place | `invariant_17_everyCreditInExactlyOnePlace` | yes: `adopt`, `swapCredit`, listings, migrate | |
| 18 | eth conservation | `invariant_18_ethConservation` (code 28) | yes | |
| 19 | the read is within its bounds | `invariant_19_bidBounds`, `invariant_v19` | yes | `_ethCap` restates the ceiling independently of the Core |
| 20 | aggregate purchase budget after the first purchase | `invariant_20_purchaseBudgetIsRespected`, `test_purchaseBudgetGhostIsNotVacuous` | yes: `spendCapBps` fuzzed 1 to 10,000, `bucketSeconds` 1 to 3,600, warps cross buckets | |
| 21, 21b | quote equals the next fill (eth, balance) | `invariant_21_ethBidEqualsNextFill`, `invariant_21b_balanceBidEqualsNextFill` | yes | not in SPEC 13's table |

handler reach, the brief's list: value mode on, never in P1 to S3 (T-01), V only with seven selectors and no owner, compose, buyback, pause or module actions; pause and unpause, S1 to S3 only; spend cap, every suite through `setSettings` and `test_purchaseBudgetGhostIsNotVacuous`; quote unusable fallback, V only by chance (`referenceMaxStale` 1 day against warps of 60 s to 3 h with a `refreshReference` selector in the mix; `invariant_v02` compares the payout with `bidOf`, which falls back the same way, so the fallback value itself is not judged); rate near zero, via `setRate`/`rateCap` 1 wei, not via fills after the first owner action; credits across bucket boundaries, yes; real pool buybacks, yes.

invariants with no reachable violating state in a suite that nominally runs them: 14 in P2, HC, HO (T-09). the value mode variants of 4, 5, 6, 8, 9, 12, 13, 14, 17, 18, 20, 21 do not exist.

## skip table

| file | condition | effect | what the candidate run must set |
|---|---|---|---|
| test/UpstreamBalance.t.sol:55-58 | `out/upstream-balance.json` missing | `vm.skip(true)` unless `REQUIRE_UPSTREAM_BALANCE` is true, then `require` fails with "run script/tools/upstream-balance.sh first" | build the artifact (`UPSTREAM_CREDITS_TOKEN=$(gh auth token) script/tools/upstream-balance.sh`) and set `REQUIRE_UPSTREAM_BALANCE=1`, so an absent artifact fails instead of skipping |
| test/LaunchDayPhase2.t.sol:28 | `require(vm.exists("out/upstream-balance.json"))` | fails, never skips | same artifact |
| test/Rehearsal.t.sol:53-59 | `REHEARSAL` empty | `vm.skip(true)`; with it set, forks the latest block and reads `LAUNCH_CONFIG` (default `script/config/rehearsal.json`, whose placeholders are expected to fail the metadata row) | `REHEARSAL=1 LAUNCH_CONFIG=script/config/mainnet.json` for a rehearsal of the real file |
| test/invariant/Invariants.t.sol:1085, 1144; InvariantsPhase2.t.sol:23, 48, 78; InvariantsSale.t.sol:127, 134 | `INVARIANT_DEEP` unset | the seven Deep variants skip; the base variants run with the inline `forge-config` (runs 16 to 24, depth 80) | `INVARIANT_DEEP=1 FOUNDRY_INVARIANT_RUNS=... FOUNDRY_INVARIANT_DEPTH=...` (header of Invariants.t.sol); there is no `InvariantsSalePhase2HostileDeep`, consistent with SPEC 13's "seven" |
| script/tools/guard-forge-test.sh (PreToolUse hook) | a whole-suite or `INVARIANT_DEEP=1` command without `CANDIDATE_RUN=1` | denied | `CANDIDATE_RUN=1` on the command line |
| test/Config.t.sol:861 | `STACK=master` | `test_preflightPinsTheOwnerDelegation` skips (the master fork owner has no 7702 delegation) | run on the default stack for that test |
| test/utils/Fixture.sol:227-229 (and ReviewHarness, V2Stack, Resume) | `FORK_BLOCK` 0 or unset | latest block; `MAINNET_RPC_URL` required | pin `FORK_BLOCK` at or after the stack pin for reproducible numbers |
| test/invariant/HandlerBase.sol:504-513 | `INV_<tag>_<action>_<kind>` | cosmetic cross run tallies through `vm.setEnv` | nothing |

## verified OK

- `BidModel` and `HandlerBase._modelPrice` restate decision 176 (the `unfunded` test uses `BidModel.room`, the royalty-adjusted room, against `lastFillRate`) and decision 178 (`growthNow = paused ? pausedSince : now`), independently of the sim.
- BidRule.t.sol:326-345 pins the launch threshold 0.1050225 eth with `reserveWei` 0.1, royalty 250 and rate 0.0049 set inline; 375-383 pin one wei edges at the minimum rate and at 0.0147 eth with royalty 1,000.
- Reserve.t.sol runs the launch reserve with the launch royalty; `test_spendAboveTheRoomReverts` uses a real score above 100 points.
- ReturnLock.t.sol:43 asserts the six hour launch lock and covers the four intake doors and the secondary holder.
- BalanceFlat.t.sol covers decision 164 (posted rate, no climb, no drop, the royalty, `available()` bound, the view reads 0 when the fill would refuse).
- StatementBalanceModule.t.sol covers the production module's gates, accrual, claim and migration against public doubles, so the module's own rules run in the default suite even when the upstream artifact is absent.
- InvariantsValue checks the round trip in both currencies at the sampled sell price (decision 165) and `test_handlerExercisesTheRoutes` proves each route fills.
- `test_everyActionSucceeds`, `test_saleActionsEverySucceed`, `test_composeChosenComposesAPage` and `test_purchaseBudgetGhostIsNotVacuous` guard the invariant suites against a silent all-revert run.
- The sim models the per point bid (`scoreRatio`, `sellForEth(now, pts)`), the 115 bps per 100 points drop (`dropPerCreditPct = dropPer100PointsBps / 100`, `fall = pct / 100 * ratio`), the flat balance bid of decision 164 (`balanceRate`, `balanceBidOf`, `xBuy` 967-1001), the royalty on top (674-677, 703-708, 999-1001), the reserve (459-467) and the pause of the sale doors and statement age (776-787, 835, 887, 898).
- Invariant 19's `_ethCap` and invariant 18's ledger are independent restatements, not reads of the Core's own view.
- `Fixture._fillEthPile` restates the rate before each fill, so the compose and sale suites do not depend on idle climb.

## stale comments and names

| file:line | text | why stale |
|---|---|---|
| test/PerPoint.t.sol:9-10, 19, 20, 26, 31, 44, 65, 68 | `refScore` in the header, four promise lines, `test_bidOfScalesTheRateByScoreOverRefScore`, assertion messages | decision 145 removed `refScore`; the divisor is `RATE_SCORE` (100 points) |
| test/CoreUnit.t.sol:202, 219, 299, 328, 346-349, 379, 406; test/Seaport.t.sol:68, 263-271; test/Fees.t.sol:236-238, 281; test/Recovery.t.sol:42-43; test/Launch.t.sol:61 | "refScore", `test_buyListing_capAndPaymentAtScoreNotRefScore`, `test_basic_capAndPaymentAtScoreNotRefScore` | same |
| test/CreditSale.t.sol:18, 136 | "`floorRate * score / refScore`"; "refScore is a Core setting now, its bound is covered by test/SetSettings.t.sol" | the setting no longer exists |
| test/BalanceValueFloor.t.sol:16 | "`floorRate * points / refScore`" | same |
| test/Sale.t.sol:929, 1156 | "the launch line runs 150 percent to 75 percent over 12 hours"; "the launch curve runs ... over 12 hours" | launch `decayHours` is 4 (decision 154); the 7,500 suite sets 12 itself (line 168), the cold test asserts 4 hours |
| test/utils/Fixture.sol:801 | "the launch curve falls from 150 percent to 100 percent of the reference over 50 hours" | 4 hours |
| test/utils/Fixture.sol:765-767; test/invariant/InvariantFixture.sol:145-146, 154-155 | "decision 92", "the decision 87 value floor", "prices the statement value floor and the credit sale baseline" | decision 170: with value mode off the pool prices nothing |
| test/utils/Fixture.sol:174 | "budget tests retain launch enforcement explicitly" | launch `spendCapBps` is 10,000 (bypass) since decision 146 |
| test/utils/Fixture.sol:389-394 | "5.90 percent of every buy reaches the pot" then "5.31 percent ... less the 10 percent redeem burn share" | `feeToRedeemBurnBps` is 0 at launch; the two sentences disagree |
| test/utils/Fixture.sol:59 | "the opening bid of the fixture core, wei per credit" | wei per 100 points |
| test/invariant/Invariants.t.sol:250, 288 | "promise: 12 a statement only leaves by asale or aredemption", "14 no call from inside aredemption" | typos in the promise lines that name the invariant |
| test/invariant/Invariants.t.sol:258 | "docs/DECISIONS.md 9.2" | DECISIONS section 9 reads "superseded by section 10 and 11; the text is in git history", so the citation points at removed text; the rule is SPEC 13 item 12 |
| test/invariant/HandlerBase.sol:2714-2745, 2694 | `_availBps`, `_availBpsRaw`, `_balanceBidState`, "PHASE 2" banner | the rising balance instance (decision 122) retired by 164; "phase 2" is "the balance side" (decision 102 vocabulary note in SPEC) |
| test/Redeem.t.sol:89 | "a redemption waits for the curve floor" | correct at launch (`ageEligibilityOn` false); fine, but 142-212 document both rules; no change needed |
| test/ChosenCompose.t.sol:136 | "(decision 89)" | decision 89 predates section 11; harmless |
| sim/engine.js:76-77, 89, 91, 94, 670, 697, 715-716, 850-851, 922, 925 | "refScore is a SETTINGS field above", "score over refScore" | removed by 145; the code uses `RATE_SCORE` |
| sim/engine.js:92, 108, 559 | "every sale adds royaltyBps ... (decision 112)", "royaltyRecipient", "royaltyBps included" | removed by decision 123 |
| sim/engine.js:920-966 | "the balance bid instance (decision 122) ... climbs and drops" | the instance is value mode's shared eth instance only (164); the comment at 967 says so, the block header does not |
| sim/market.mjs:12-13, 275 | `REFSCORE`, `core.s.refScore` | T-03 |
| sim/page.ui1.js:26, 78, 143, 240; sim/page.ui4.js:26, 47; sim/page.ui.test.js:30-31 | `refScore` control, "refScore 350 points" scenario, "or the balance token pool term once the pool key is set", decisions "104, 105, 112" | removed fields and rules |
| sim/grid.mjs:3, 23 | "collapse (exit sellers ...)", "exit sellers:" | decision 102: the vocabulary is "balance", never "exit" |
| sim/README.md:21 | "At launch, `spendCapBps` is 100" | 10,000 since decision 146 |
| sim/engine.test.mjs:16 | `LEGACY` carries `decayHours: 12, anchorMoveBps: 5000, creditStartBps: 30000` | labelled legacy; fine |
