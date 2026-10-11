# acceptance review of 0c3ecd2

reviewer: independent, read only. clone /private/tmp/accept-0c3ecd2 at 0c3ecd2 (git checkout, lib/ out/ cache/ copied from the origin worktree). fork env MAINNET_RPC_URL tenderly gateway, FORK_BLOCK 26158000. no src, script, test or doc file edited. one scratch test (test/ScratchDrag.t.sol, for R1) was run and deleted. src, test and sim are byte identical to 97c1866 (`git diff 97c1866 0c3ecd2 -- src test script sim` shows only script/tools/check-preflight.sh).

ran, all pass: BuildIdentity 5, Seaport 29, CallerPay 12, FeeRouter 29, PullFees 17, Migrate 35, Redeem 22, BidRule 33, Adopt 21, OwnerPowers 26, Lock 8, Rescue 12, Lens 11, GasCap 33, Lifecycle 20, Phase2Flex 33, Fees 76, Sale 67, Config 32, Resume 22, V2Port 7, FeeShare 14, Econ 7, Flow 46, SetSettings 9 (620 passed, 0 failed, 1 skipped: GasCap `pageVariance_liveStatements`, needs GAS_VARIANCE=1). `REHEARSAL=1` Rehearsal.t.sol passes at block 26171876. Preflight.s.sol on mainnet.json at the pin block: 112 of 116, the 4 failures are the 4 expected rows (metadata empty, deployer balance at the pin, factory min share 1000, simulated launch `BountyBpsTooHigh(9638, 9000)`). `forge build --sizes`: Core 18,462 bytes (6,114 headroom), CoreLib 15,239, FeeRouter 4,446, CoreLens 6,492.

## verdict

ACCEPT the code and script/config/mainnet.json at 0c3ecd2 against owner decisions 1 to 71. Every live decision is built as the owner's recorded words say, except the items marked nv. No critical, high or medium code defect found.

open before launch:
1. R1 (goal risk, new): the 50 percent minute floor of decision 69 lets one dump stall the bid for hours to days (numbers below). Owner confirmation needed that this recovery time is intended.
2. R2 (goal risk, new): credits bought above 1.33 times market become statements whose 75 percent hard floor sits above market, so they stay unsold.
3. Findings of 50cec6f still open: L2, C1, C2, D6 (section dispositions).
4. The deploy gate fails at branch tip 48a2e4e: `python3 script/director.py check --gate deploy` in a clone of the tip prints `ERROR: non-state files changed after candidate: docs/ARCHITECTURE.md` (state only paths are HANDOFF, director-state, evidence). ARCHITECTURE.md was edited after the freeze of 0c3ecd2.
5. Doc mismatches M1 to M7 (below), none changes behaviour.
6. mainnet.json holds empty `image` and `description` (preflight fails by design until filled) and `rateStart` 8.9e15 (launch day input, nv).

## part 1, decisions (ok = owner words, code, mainnet.json and ARCHITECTURE s1 agree; nv = not verifiable from the repo)

| # | verdict | note |
|---|---|---|
| 1 | ok, superseded by 55 | one rate per credit, no score code in src |
| 2 | ok | no inventory gate in Core.sol:496,517; invariant 16 in DEEP-RUN-97c1866.log |
| 3 | ok | 24 Settings fields, all through setSettings; gas caps (BUYBACK_GAS, BUYLISTING_GAS, COMPOSE_GAS 13.7M, EXIT_GAS) and XRATE_START are constants, ARCH s2 lists them |
| 4 | ok, superseded by 9, 68 | no house in src |
| 5 | ok, superseded by NEXT 11, 60 | opening bid at market; value nv |
| 6 | ok | saleToBuybackBps 5000, Core.sol:676 |
| 7 | ok, revoked by 15 | OwnerPowers `queue_noQueueNoDelayNoCancelNoFreezeNoImmutableOwner` |
| 8 | ok | three asset doors (migrate, rescueNft, rescueCoin) plus the documented overpay. FLOW:20 still cites `test_ACCEPTED_ownerPerTransactionAtLaunchSettings` and `PerDayWorstCase`, removed with the window (M5) |
| 9 | ok | ExitTokenChanged, Core.sol:1001; Phase2Flex `replace_differentExitTokenReverts` |
| 10 | ok | unit re-read at every set; `replace_sameAddressUpdatesTheUnit` |
| 11 | ok | exitLaneToBuybackBps 0; Phase2Flex `lane_*` |
| 12 | ok, superseded by 53 | |
| 13 | ok | exitToBuybackBps 5000 |
| 14 | ok | Core.sol:320 splits by feeToBuybackBps (launch 0); skim books to the pot whole; FeeShare 14 |
| 15 | ok | owner setters act at once, no queue |
| 16 | ok | pricing in ControllerV1; Core keeps custody, floor (Core.sol:676) and booking |
| 17 | ok, superseded by 62, 64, 65, 68 | |
| 18 | ok | restricted true, allowed [] in mainnet.json; Core and router off the allowlist; V2PortRestriction (not rerun) |
| 19 | ok | router is the bounty recipient (script/Builder.sol buildConfig); Core books only FEE_SOURCE eth |
| 20 | ok, revoked by 23 | lpFeePips 0, no swapper in script/ |
| 21 | ok, superseded by 23, 24, 26, 31 | locker slot protocolBps 2000 pinned by Checks.sol `rule: protocol bps is 2000` |
| 22 | ok | deployTokenAsOwner (SystemDeployer._launch); `_requireOwner`; preflight factory owner rows |
| 23 | ok | baselineSkimBps 690, lpFeePips 0; preflight simulates the launch |
| 24 | ok | bountyBps 9638; signoff row names the protocol leg a separate business (Checks.sol `_preSignoff`) |
| 25 | ok, superseded by 31, 59 | |
| 26 | ok | FeeRouter.sol:87-109 split off until splitStart, first flush at or after it sends all to the engine; sniperStartBps 9000 over 1800 s |
| 27 | ok | flush() takes no argument; door caller pays the flush gas |
| 28 | ok | CoreLib rescueCoin: owner, guarded, zero address refused, event |
| 29 | ok | allowed []; buyback take through the hook allowance, Fees buyback tests on the live hook |
| 30 | ok | pullFees at sellForEth (both), buyListing, compose, composeExit, and adopt (35); PULL_GAS 1,000,000; PullFees 17 |
| 31 | ok | bountyBps 9638; Checks.sol `_preFees` fails while factory min share exceeds 362 |
| 32 | ok | CoreLib rescueNft; Rescue 12 |
| 33 | ok, amended by 48, 52 | setSuccessor, lockSuccessor, migrate; Migrate 35 |
| 34 | ok | CoreLens; Lens 11; invariant 20 |
| 35 | ok | CoreLib.adopt books `ethPrice()` before the clamp, at least 1 wei; Adopt 21 |
| 36 | ok, superseded by 56 | no window in src |
| 37 | ok, superseded by 55, 56 | |
| 38 | ok | units in mainnet.json: 690, 9000, referral cap 0, lpFeePips 0 |
| 39 | ok | only owner command is setMinProtocolSkimShareBps(362), DEPLOY step 3 |
| 40 | ok | Lock.s.sol sends coin.lockRecipients(); postflight WARNs until locked (Rehearsal log); OD-2 (lockAllowlist, router.lock) open |
| 41 | ok, superseded in part by 66, 67 | |
| 42 | ok, narrower than the words | owner: "we should never get locked anywhere". holds at or below rateCap (invariants 11, 16); R1 is a stall, not a lock; setRate restores at once |
| 43 | ok | owner: "that's the opposite of what we want to do here". no Core function sells a credit; floor effect unproved (simulator only) |
| 44 | ok | owner: "we shouldn't be increasing the price just because we don't have enough eth". CoreLib.sol:208 climbs only while r < min(cap, pot); BidRule `starvedPotDoesNotRaiseThePriceState` |
| 45 | ok | owner: "that's how we get frontrun!". read is min(price state, pot), no window |
| 46 | ok, superseded by 69 | preflight `rateCap is 3 times rateStart`; 2.67e16 = 3 x 8.9e15 |
| 47 | nv | readiness never written; only the burn router code hash pin exists |
| 48 | ok | `retired` set in CoreLib.sol:387; Migrate `REVERT_aRetiredCoreRefuses*` (6), `OK_aRetiredCoreStillSellsAndExitsStatements` |
| 49 | ok | rateCap bounds the climb (CoreLib.sol:208) |
| 50 | ok, superseded by 69 | idleLoosenBps 1 to 2000 in SettingsBounds |
| 51 | ok | buybackSlice 5e17, bound 0.01 to 1 eth; owner: "i'd rather do B" |
| 52 | ok | xToBuyback stays on migrate (CoreLib `_moveExitToken`) |
| 53 | ok | name and symbol CC |
| 54 | ok | image and description go to the factory (Builder.sol:40-41), postflight compares them; tracked file empty so preflight fails until filled; L2 open |
| 55 | ok | owner: "lets remove the score stuff completely". none in src. FLOW:390 says adopt books "at the current bid"; code books the pre-clamp price state (FLOW 35, ARCH s5 state it) |
| 56 | ok | removed names absent from src; buyListing kept |
| 57 | nv | owner keeper is outside the repo |
| 58 | ok | both sellForEth forms; batch of 115 measured (GasCap `LARGEST BATCH under the cap 115`), the contract enforces no count |
| 59 | ok | payeePpm 112778; 6.65022 x 112778 ppm = 0.74999851 points |
| 60 | ok | owner: "100% of market". rateStart is a launch day input; 8.9e15 is the placeholder, market nv |
| 61 | ok | Core.sol:742 buyback; SliceTooSmall; slice bound in SettingsBounds; keeperFee 5e14, 10 gwei; Fees 76 |
| 62 | ok, superseded in part by 64, 65, 68, 70 | start min(1.5 x anchor, 1000 percent), anchor halfway to sale |
| 63 | ok | owner: "no". callerFee 0 pays exactly 0; CallerPay `launchSettingsPayZero` |
| 64 | ok | anchor rises only on sales, halves per 7 days; ControllerV1.sol:213; Sale `anchor_*` |
| 65 | ok | owner: "1%/hr until it hits base, then 1%/4 hr". ControllerV1.sol:244; ask 150 percent, 100 at hour 50, 75 at hour 150 |
| 66 | ok | same rule as buyback, 0 at launch; owner: "set refund to 0" |
| 67 | ok, C1 open | owner: "dont reimburse gas here. make that a user call. same as compose." code keeps the optional payment path, 0 at launch |
| 68 | ok | no house, collectSales, buyOnly in src; exit needs exitAfter since compose; owner: "remove auction house" |
| 69 | ok | mainnet.json holds 200, 11000, 5000, 3x; owner: "yes". the keeper before launch is nv; recovery times after a dump unrecorded (R1) |
| 70 | ok, C2 open | anchorMinCost 1e17, inclusive (ControllerV1.sol:214); the value was the director's |
| 71 | ok | Core.sol:517: pay = min(gas x min(basefee, keeperMaxBaseFee) + keeperFee, ceiling - cost); Seaport 29 incl. `Fuzz_selfDealingNeverBeatsTheSellDoor` |

ARCHITECTURE s1 states every row above accurately except the items below.
- M1 ARCH:64 gives Core 18,424 bytes, 6,152 headroom, CoreLib 15,632. Pinned and built: 18,462, 6,114, 15,239 (BuildIdentity.t.sol:23,25; HANDOFF:37 is right).
- M2 ARCH:111 says a sale batch whose total reaches the pot "pays the pot out and the next credit reverts". The revert undoes the whole call, nothing is paid (Core.sol:496 loop; CoreUnit `test_tinyPotSellsItsWeiAndBuysNothing` shows the single credit case).
- M3 ARCH:319 (s14 item 21) says credits sent outside the doors "are stuck". `adopt` (Core.sol:942) and `rescueNft` move them.
- M4 ARCH:17,19,21 cite deep runs of 1e2c4b3 carried to 14c6306 although DEEP-RUN-97c1866.log is committed. Fixed in 48a2e4e, see item 4 of the verdict.
- M5 FLOW:73 says a dump can fall "20 percent" a minute (50 percent since 69). Unmarked superseded text: FLOW:20 (removed tests), :296 bullet (decision 41), :337 and :356 (`hourlyRoom`, `windowPot`).
- M6 HANDOFF:11 says "decisions 1 to 69".
- M7 project/director-state.json paths still say "hourly window" (:35), "with no paid caller" (:43), "overprint" (:59).

## dispositions of docs/ACCEPTANCE-50cec6f.md

| id | disposition |
|---|---|
| L1 anchor pump | accepted by 68 (owner: "is this just griefing? if so, don't worry about it") and 70. no code change. ARCH s14 item 46 now states the price paid. cumulative 5.87 eth over 11 rounds is not in FLOW |
| L2 metadata marker | still open. Checks.sol:296-308 unchanged: empty or the exact text `PLACEHOLDER` only |
| C1 exit payment path (67) | still open. FLOW:402 unchanged, no owner answer recorded. off at launch |
| C2 anchorMinCost value (70) | still open. FLOW:405 records "yes" only |
| D1 DEPLOY "twelve sites" | fixed 97c1866 (thirteen, DEPLOY:119) |
| D2 FLOW 58, 60 unmarked | fixed 97c1866 (marks in rows 58, 60) |
| D3 FLOW 62, 65 unmarked | fixed 97c1866 (marks in rows 62, 65) |
| D4 FLOW 48 unmarked | fixed 97c1866 (mark in row 48) |
| D5 ARCH item 46 cost wording | fixed 97c1866 (buyer pays the whole price, 0.15 eth at the threshold) |
| D6 stale evidence cites | still open at 0c3ecd2 (M4); text fixed in 48a2e4e, which fails the gate |
| D7 history rows | accepted |
| E1 no run on the candidate | fixed: SUITE-97c1866.log 995 passed, 0 failed, 8 skipped (setUp skips); DEEP-RUN-97c1866.log 7 suites pass; src, test, sim identical at 0c3ecd2 |

## part 2, paths of OBJ-LAUNCH-1

| path | verdict | trace and evidence |
|---|---|---|
| fee-intake | verified | hook pushes the bounty leg to FeeRouter.receive (empty, fits 2,300 gas: FeeRouter `receiveFitsExactly2300Gas`). Door start calls CoreLib.pullFees (CoreLib.sol:595, 1M gas, outcome ignored) -> FeeRouter.flush (:87) -> payees 100k gas each (:111) and engine all gas -> Core.receive (Core.sol:320: Measuring revert, checkpoint, feeToBuybackBps split, FeesAdded). events Flushed, PayeePaid, PayeeOwed, FeesAdded. tests FeeRouter 29, PullFees 17, FeeShare 14, V2Port `exactNumbersAtEachSplit`, Fees `receiveMid*`, GasCap `routerWorstCaseFlush` (compose 8.88M gas with four burning payees). note: eth that reaches the router after splitStart and before the first flush goes whole to the engine (DEPLOY:95, owner accepted by 26) |
| credit-purchase | verified | sellForEth (Core.sol:496): _openDoor, per credit ethRate, _spend (:388: checkpoint, CoreLib.drop :238, lastFillTime, ethPot), pile push, transferFrom, payout last; buyListing (:517) measured balance delta, credit check, payment min(gas + fee, ceiling - cost), one fill; adopt (:942). events CreditBought, EthRateFill, ListingBought, CreditAdopted. tests BidRule 33, CoreUnit, Seaport 29, Adopt 21, GasCap. M2 applies. defect none |
| compose-and-listing | verified | compose and composeExit (:603): _openDoor, nextPage with 500k gas and 82 words, 80 _pull, STATEMENTS.compose, id and owner checks, record held, Composed, _payCaller (0 at launch). no listing exists after 68. tests Sale, CallerPay 12, PullFees, Lifecycle `compose_*`, GasCap (8.88M of 16.78M cap). gap: COMPOSE_GAS 13.7M rests on the opt-in `GAS_VARIANCE` test, skipped in SUITE-97c1866.log |
| statement-sale-and-proceeds | verified | ControllerV1.buy (:188): _quote, _moveAnchor, Core.sellTo (:676: floor, _unhold, transfer, split, checkpoint, pot), refund last. events Bought, AnchorMoved, StatementSoldTo. tests Sale 67 (buy 7, sellTo 10, curve 11, anchor_*), ReviewSale (not rerun), Lifecycle `sale_buyBookBuyback`, Fees buyback. L1 |
| phase2-exit | verified on stand-ins | exitStatement (:696): TooEarly for eth lane, balance delta >= credits x unit, split, payment last; sellForExitToken (CoreLib), buybackExit, _setExitModule (:1001). tests Redeem 22, Phase2Flex 33, ReviewPhase2Flex (not rerun), Lifecycle `phase2_*`. gap: the real exitModule does not exist, MockExitModule and MockExitToken only (FLOW s8) |
| owner-powers-and-locks | verified | setSettings (checkpoint both rates, bounds in CoreLib), setRate, setController, setExitModule, add/removeTarget, three locks, lockSuccessor, two step owner (:825), rescueCoin, rescueNft, router setters and lock. tests OwnerPowers 26, SetSettings 9, Rescue 12, Flow 46, FeeRouter lock and owner tests, invariant 13. open: OD-2 (router.lock, coin.lockAllowlist) |
| migration-and-successor | verified | CoreLib.migrate (:387): owner, successor set, guard, retired once, eth, credits, exit token; ethToBuyback and xToBuyback stay. tests Migrate 35, V2PortMigration (not rerun), Adopt `OK_migrateThenAdoptOnTheSuccessorRestoresThePile` |
| launch-runbook | verified, gaps | Rehearsal pass; Preflight 112 of 116 as expected; Config 32, Resume 22, Lock 8, BuildIdentity 5. gaps: L2; deploy gate error at the tip (verdict 4); metadata and rateStart inputs; the Deploy dry run reads the owner balance too high, cause unknown (REHEARSAL-97c1866.md). the owner is a 7702 account: Deploy and Resume use `--slow`, DEPLOY:24,95,398 |
| participant-economics | gap | arithmetic verified: per 100 eth of volume protocol 0.24978, payee 0.74999851, engine 5.90022149 eth. no demand, price or composer evidence exists in the repo (simulator only). see part 3 |

no code defect found on any path.

## part 3, goal risks at launch settings (P0 = 0.0089 eth, page of 80 = 0.712 eth)

R1 dump then stall (new). The 1, 2 and 3 minute rows come from the scratch test on the real contracts, the 4 minute row from a Python model of CoreLib that matched the three test rows. Each minute a seller can walk the bid down to 50 percent (139 fills at 0.5 percent). The ceiling anchor becomes the price at the last fill, and it loosens only 2 percent of itself per 10 minutes, so the bid cannot return to market quickly. Fixture run, bid after / hours until the bid is back at its opening value / seller loss at P0:
- 1 minute, 140 credits: 0.50 P0, 7 h, 0.35 eth
- 2 minutes, 280 credits: 0.25 P0, 22 h, 1.15 eth
- 3 minutes, 420 credits: 0.125 P0, 52 h, 2.2 eth
- 4 minutes, 560 credits: 0.06 P0, about 113 h, 3.3 eth
A whale dump has the same effect. Decision 69 says "a big sale walks it further down" and the owner said "yes"; the recovery hours are unrecorded. FLOW:73 gives 20 percent. `setRate` restores the bid at once. Ask the owner to confirm or set `dropFloorBps` above 5_000 (bound 5_000 to 10_000).

R2 overpaid credits become unsold statements. A statement cost is the sum of the prices paid. The hard floor is 75 percent of cost (saleFloorBps and floorBps 7_500), so a page sells at market only while average basis is at most 1.33 times market. Average basis of the first 80 credits bought after a quiet spell, in P0 (their 75 percent floor in P0): 2 h 1.13 (0.85), 4 h 1.34 (1.00), 8 h 1.78 (1.34), 24 h 2.48 (1.86). Stale bid during a market fall (average basis over market): 30 percent fall 1.20 (floor 0.90, sells), 45 percent 1.37 (1.03), 60 percent 1.64 (1.23), 90 percent 3.91 (2.94). Pages above the threshold wait for a market recovery or the exitModule. This conflicts with the owner goal "a statement that sells below the cost of its 80 credits is better than one that does not sell" unless the owner lowers saleFloorBps (bound 1_000) and the controller floorBps. FIFO composing spreads the overpaid credits over pages.

R3 blind climb after quiet time (G3 of 50cec6f, reproduced). Bid at last fill P0, market flat, 115 credit batch windfall over market: 1 h 0.04 eth, 2 h 0.10, 4 h 0.25, 8 h 0.66, 12 h 1.07, 24 h 1.32 (first credit 1.23x, 1.36x, 1.63x, 2.16x, 2.68x, 3.0x P0). Credits beyond the batch in the same minute sit on the 50 percent floor: 1.08x P0 after 8 h, 1.5x after 24 h, bounded by credits that can be bought at market and by the pot. Stale bid when the market falls 30, 60, 90 percent: overpay 0.09, 0.42, 1.19 eth. Cause of exposure: a launch with no seller for hours.

R4 coin burn depends on statement sales. feeToBuybackBps is 0, so the burn is 50 percent of sale proceeds. Over 90 days at 1,961 eth of volume the engine receives 115.7 eth (payee 14.7 gross, protocol 4.9). With every page sold at cost the burn equals the fee inflow (115.7 eth); at the 75 percent floor 0.6x of it; at zero sales 0. Compose is unpaid: 162 pages x 8.9M gas = 0.0089 eth a page at 1 gwei (1.2 percent of the page), 0.089 at 10 gwei (12.5 percent), 0.267 at 30 gwei (37.5 percent). Total 1.4, 14.4, 43 eth over the 90 days. Only the owner backstop or a statement buyer who wants the statement pays it.

R5 buyListing refund coverage (decision 71). Payment is gas + 0.0005 eth, cut to the gap between bid and price. Full payment needs the gap at 0.00097 eth (10.9 percent of P0) at 1 gwei, 0.00144 (16 percent) at 2 gwei, 0.0052 (58 percent) at 10 gwei. A caller who meets the gap is paid its gas and 0.0005 eth, so the owner keeper loses gas only on a lost race. Smaller gaps are taken by arbitrageurs through the sell door.

R6 exit against the sale schedule. Once an exitModule is set, an eth statement is exitable at hour 105 where the ask is 86.25 percent of cost (195 percent when the anchor is 2.0). Owner decides exitAfter at setExitModule (65).

R7 anchor pump (L1). First round costs 0.15 eth (0.1 eth statement), 5.87 eth after 11 rounds; afterwards a new statement starts at 1,000 percent and needs 900 h to reach cost, proceeds stall about 37.5 days unless `setAnchorBps`.

R8 rateStart 8.9e15 is a placeholder. DEPLOY's example median is 1.06e16 (+19 percent). Too high pays that excess to the first sellers; too low delays buying about 35 minutes at 0.5 percent a minute.

## not checked

- the full suite and the seven Deep suites were not rerun; the committed SUITE-97c1866.log and DEEP-RUN-97c1866.log were read (src, test, sim unchanged since 97c1866).
- sim/index.html, SIMULATION.md numbers, project/evidence.json records beyond the gate output, script/director.py outside the gate run.
- Statements internals (decompose), the owner keeper, the v2 contracts, sandwich depth of the buyback, real market and seller data behind R1 to R3, the burn router readiness (47).
- Resume.s.sol, Lock.s.sol, SetSettings.s.sol end to end beyond their tests; etherscan verification; a redelegation of the owner account after preflight.
- ReviewMatrix, ReviewSale, ReviewV2Port, Launch, LaunchV2, PostflightSlots and the invariant suites were not run.
