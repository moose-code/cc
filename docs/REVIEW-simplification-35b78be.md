# simplification review: credits engine at 35b78be

date 2026-10-13. source reviewed: `main` at 35b78be (equal to origin/main). working tree clean. a proposal for the owner. it changes no runtime behavior. implementation waits for the owner's approval.

method: five bounded investigations (contracts, tests, scripts and tooling, docs, product intent), one independent adversarial challenge of the first draft, and two revisions. revision 1 adopted the challenge findings (section 9). revision 2 follows the owner's instruction of 2026-10-13, recorded as decision 99: the exit side is a core part of the engine, off at launch only until the exit token is live. each figure is marked measured or est. file:line cites point at 35b78be.

## 0. recommendation

**ship option A with an on-chain simplification pass: every feature stays, the same behavior is implemented with less mechanism, and the owner decides a short list of rule simplifications one by one. retire the director tooling, archive the superseded records, delete the generated material, merge the duplicate tests, drop the config-echo rows, rewrite the stale documents. then freeze once and get one full independent review.**

reasoning. the switches that are off at launch (`exitMode`, `creditSaleOn`, `chosenComposeOn`, the exit pool key) are the mechanism by which the engine launches before the exit token exists and turns its exit side on afterwards without a redeploy (decision 99). removing them would remove the product. the on-chain simplification that remains is of two kinds (section 3.5). first, mechanism: the same behavior with fewer copies and less indirection, about 125 to 165 lines (est) and one external call off the hot read path, with no ABI change. the size pressure that justified the indirection is gone (Core has 6,095 bytes of headroom at the last measurement). second, rules: the statement price stacks three independent decay and discovery regimes (the bid's two-stage recovery solver, the controller's up-only anchor, the controller's two-stage decay) that were added separately before decision 96 put one manipulation-proof rate under every floor. predicting a statement price today takes about 30 numbers (est). each regime is an owner decision and section 7 lists them with the outcome change at launch values.

the supporting work holds the rest of the accidental complexity: a 1,782 line process tool whose 71 evidence records are all invalid and whose deploy gate fails at HEAD, 1.2 MB of superseded records at the top of `docs/`, 1.4 MB of regenerable sim output and vendored third-party sources, about 100 duplicate test functions, about 100 preflight and postflight rows that restate the config, a simulator that mirrors the contracts by hand with no parity check, and a handoff document whose state table is wrong in six places. none of that is needed to launch, and some of it blocks the launch as written.

the first draft recommended removing the exit side, the credit sale and chosen composition because they are off at launch. the owner rejected it: "that's a crucial part of the system and a differentiator. the only reason it's toggle off at launch is because the $balance token isn't live yet." the on-chain part of that recommendation is withdrawn in full. its one lasting value is the dependency map in section 3.1, which a reviewer of the exit side needs.

a clean-sheet rewrite (option C) is not recommended: the kept parts are reviewed, pinned and stable, and the named regressions record real bugs in exactly the parts a rewrite would redo.

## 1. baseline (measured)

| item | value |
|---|---|
| branch | `main` 35b78be, equal to origin/main, clean tree. review done in worktree `claude/project-simplification-review-47fce7` |
| frozen candidate | b12ca48 (`project/director-state.json`). two source commits since (c1fed1b, f65c85d, decisions 96 to 98). HANDOFF and ARCHITECTURE still name 6ea44f5 |
| source | 3,134 lines in `src/*.sol` and `src/lib/*.sol`, 1,071 in `src/interfaces/`. Core 1,157, CoreLib 693, ControllerV1 644, CoreLens 272, FeeRouter 202 |
| runtime bytes | Core 18,481 (6,095 headroom), CoreLib 16,484, ControllerV1 15,698, CoreLens 10,866, FeeRouter 4,446, pinned at 3a484a4 (HANDOFF.md:38), stale: five source commits since |
| tests | 35,260 lines, 56 top-level files, 990 `function test*` (the command in section 9) plus 21 invariants in 8 suites and 7 deep variants. all fork mainnet at block 26158000 except FeeRouter and ScriptLint |
| scripts | 5,677 lines: 3,562 in 17 `.sol`, 1,782 in `director.py` and `test_director.py`, the rest config and tools |
| sim | about 3,100 lines of JS plus 612 KB of data. no dependent in src, test, script or foundry.toml |
| docs | 102 files, 3,441,484 bytes. 1,169,340 in 41 top-level records (reviews, acceptances, rehearsals, suite and deep-run logs), 532,259 in 7 live docs, 1,739,885 in archive (1,059,314 of it sim result JSON and CSV) |
| evidence ledger | 71 records, 71 invalid at HEAD. `python3 script/director.py check --gate deploy` fails at HEAD, so DEPLOY.md step 6 cannot run as written |
| reviews | no review record covers b12ca48 or HEAD. the newest record is 267139b, 25 commits behind the candidate. 12 of 17 `src/` files changed since. decisions 88 to 95 were reviewed only in commit messages (3a484a4, 08fa2d7). decisions 96 to 98 have no review |
| branches | `claude/repair-project-director-1366be` merged (delete). `claude/v1-ui-nextjs-web3-1d1637` and `feat/ui-anvil-local` hold an unmerged Next.js UI (+11.6k lines), stale against main, outside this review. `codex/independent-security-audit` one commit, 283 behind |

implemented, documented only, unfinished:

* implemented and tested: the full engine including every switched subsystem of section 3.1, the deploy pipeline, the director tooling.
* documented only: burn router readiness (decision 47, "what readiness requires of the engine is not written down"), the owner keeper (a separate project, launch prerequisite), the exit module contract (source unpublished, HANDOFF section 4).
* unfinished: a freeze and independent review of the current source, the stale HANDOFF (section 3.4), the deploy gate.

## 2. the product (recovered)

the engine is an ERC20 ("CC") whose swap fees buy an external NFT (Credits), bundle 80 into a Statement, sell the statement on a falling price, spend half the proceeds buying and burning CC, and, once the exit token is live, redeem statements for the exit token and buy credits with it. the eth loop has been stable from `docs/archive/SPEC.md` to today; the exit side is the second half of the design and the engine launches before its counterparty exists (decision 99).

| actor | puts in | gets out |
|---|---|---|
| coin trader | swaps in the one CC/eth pool, pays the 6.9 point skim | buy and burn of CC |
| credit seller | credits, via `sellForEth` or a Seaport listing below the bid; later via `sellForExitToken` | eth at the flat bid; later exit token per point |
| statement buyer | eth at the curve price via `ControllerV1.buy`; later a pile credit via `buyCredit` | the Statement NFT; the credit |
| keeper or bot | gas for `buyListing`, `buyback`, `compose`, later `exitStatement` | gas refund plus `keeperFee` on `buyListing` and `buyback`; compose and exit unpaid at launch |
| owner | the launch, every economic setting, the keeper, the key, the exit module | the payee share, control |
| artcoins v2 stack | the coin, pool, hook, locker, escrow, factory (live, pinned by code hash) | the protocol skim |
| exit module and token (not live) | redemption of a held statement for the exit token | the statement |

guarantees, classified:

| guarantee or behavior | decision | class |
|---|---|---|
| the engine never stops buying because statements are unsold | 2 | foundational |
| fees buy credits, 80 compose into one statement, statements sell for eth, half the proceeds burn coin | SPEC, 6 | foundational |
| the exit side: statements redeem for the exit token at the floor, the exit token bid buys credits per point, each redemption burns from the reserve | 82, 84, 86, 99 | foundational, switched on when the token is live |
| eth, credits and exit token leave the Core at the owner's call only through `migrate` to a successor | 8, 48 | foundational (custody) |
| a statement leaves only by a sale at or above `saleFloorBps` of its cost or by an exit | 56, 68 | foundational |
| every economic number is an owner setting, effective at once | 3, 15 | foundational philosophy, also a policy |
| the four Core locks and the router lock are one way | 9.6, 10.2 | foundational (trust) |
| a credit at the bid that the pot covers can always be sold while the market is at or below `rateCap` | 42, 48 | reaction to the owner's "never brick" concern |
| remembered peak, fast recovery climb, `recoveryGapBps` | 74, 75, 77 | reaction to review risk R1 |
| `floorRate` under every price floor; statement reference `max(cost, floorRate * rating / refScore)` | 90, 95, 96 | the manipulation floor under every price, live at launch |
| credit sale window, chosen composition | 88, 89 | built, owner switches, off at launch |
| successor and `migrate` | 33, 48 | failure recovery |
| Core and CoreLib delegatecall split, generated interfaces, via_ir, `--slow` for the 7702 deployer | none | accidental constraints, each forced by a real limit |

ownership and trust: the owner key can set every price, swap the controller and the exit module, move everything to a successor in one transaction and pause sales. a stolen key drains the engine (ARCHITECTURE section 10, accepted at decision 8). mitigations are social: a multisig owner and public events.

costs: callers of `buyback` and `buyListing` are repaid gas at `min(basefee, keeperMaxBaseFee)` plus `keeperFee`. `buyListing` lets the fastest caller take the whole gap between the bid and the listing price (decision 73, accepted). compose is unpaid at launch (decision 63).

failure: a market above `rateCap` stops buying until the owner raises it (about 7 hours to 2x at launch values, accepted at 49 and 69). one large dump stalls buying for 35 to 146 minutes measured (R1, mitigated by 74 to 77). statements bought above about 1.33 times market sit unsold at the floor (R2, accepted at 72). a half-done deploy from the 7702 account is resumed by `Resume.s.sol`. `exitStatement` forwards gas to a module that does not exist yet; its gas is measured when it does (HANDOFF section 8).

compatibility: the live v2 stack (nine code hashes pinned in preflight), the Credits and Statements contracts, Seaport 1.6, the pool manager. a changed stack means a new Core. the exit module must let a contract own and redeem a statement, pay a plain erc-20 at a fixed address, and have a known minimum payout per statement (HANDOFF section 4); a fork test with the real module follows once its source is published.

## 3. complexity findings

### 3.1 on-chain (kept; this map is for the reviewer of the frozen candidate)

| subsystem | where | lines (est) | state at launch | why it exists |
|---|---|---|---|---|
| exit side: `exitStatement`, `sellForExitToken`, `setExitModule`, `lockExitModule`, `refreshUnitPerPoint`, `unitPerPoint`, `xPot`, `exitMode`, `exitSlippageBps`, `exitBidMarginBps`, Core `_atFloor`, controller `atFloor`, lens `exitEligible` and `exitBidOf` | Core.sol:467, 585-600, 781-820, 888-910; CoreLib.sol:582-676; ControllerV1.sol:363; CoreLens.sol:209, 270 | 220 | `exitMode` 0, module unset | the second half of the product (99). turned on with `setExitModule` and `setSettings` once the token is live |
| redeem burn reserve: `ethRedeemBurn`, `feeToRedeemBurnBps`, `redeemBurnBps`, `releaseRedeemBurn` | Core.sol:237-239, 353-356, 803-807, 911-918 | 25 | fed from launch (10 percent of fees), drains on redemption or the owner's call | 86, 98 |
| exit pool value floor: `setExitPoolKey`, `_value`, `_baseline`, FullMath pricing | ControllerV1.sol:271-285, 416-545 | 90 | key unset | 87: a statement asks at least its redemption value once the token trades |
| credit sale window: `buyCredit`, `buyCredits`, `creditPrice`, `pastWindow`, four setters, Core `sellCreditTo`, `creditCostToPotBps`, Core `_pastWindow`, the `InWindow` revert and the window checks in compose | ControllerV1.sol:291-315, 440-500, 632-637; Core.sol:474, 634-652, 755-770, 1023 | 180 | off | 88: the preferred buy and burn source |
| chosen composition: `composeChosen`, `chosenComposeOn`, `minCcToChoose`, lens `choosable` | Core.sol:638-654, 1030-1039 | 40 | off | 89 |
| rating-scaled reference: `ratingOf`, the `rating` field read from `Statements.creditScoreOf` at compose, `refScore`, `_reference` | Core.sol:676-678, 1131; ControllerV1.sol:333-366 | 40 | on | 90, 95, 96 |
| pause with frozen price age: `PauseWindow[]`, `_pausedUntil` binary search | ControllerV1.sol:80-85, 252-269, 538-570 | 50 | built, unpaused | 97 |
| recovery climb closed form: `_recover`, `_climbTo`, lnWad and expWad | CoreLib.sol:269-299 | 45 | on | R1, 74 to 77 |
| successor and migrate: `setSuccessor`, `lockSuccessor`, `migrate`, `retired` | CoreLib.sol:414-526; Core.sol:964-1013 | 150 | dormant | failure recovery and upgrade path |
| `buyListing` with target allowlist | Core.sol:548-611, 921-945, 1016 | 130 | on | 57: bots are the primary fill path |
| defensive: `skim`, `adopt`, `rescueCoin`, `rescueNft` | Core.sol:371-384, 952-962, 1010; CoreLib.sol:359-412 | 90 | dormant | stray assets |
| CoreLib delegatecall split, `CoreState` mirror of Core storage, `_toLib` selector rewrite | CoreLib.sol:29-58; Core.sol:223-272, 990 | 120 | structural | Core runtime bytes. Core plus CoreLib is 34,965 bytes, so the split stays |

owner surface: 23 fields in `setSettings`, 4 Core value setters, 16 controller setters, plus addresses and locks. about 43 knobs (measured count of setters and fields). every one is an owner decision (3, 15).

duplicated representations (measured): Core storage declared twice (Core.sol:223-272 and the `CoreState` struct, guarded by `test/CoreLayout.t.sol`); the `Settings` struct in four forms (Interfaces.sol, packed read and write in CoreLib, `script/SettingsFields.sol`, `mainnet.json`); the settings bounds in `SettingsBounds`, `SettingsFields`, `sim/engine.js` and DEPLOY.md; the five stack addresses in `mainnet.json`, `rehearsal.json`, `v2-mainnet.json` and DEPLOY.md; the bounded staticcall for `unitPerPoint` and `refScore` in four places; interfaces generated from the contracts. the on-chain copies are each guarded by a test or forced by the size limit. the script-side copies (`SettingsFields`, `defaultConfig`, `rehearsal.json`) are the ones section 6 removes.

coupling a reviewer of the exit side must hold: `atFloor` is read by `exitStatement` and the lens; `ethRedeemBurn` is in `receive`, `skim` and invariant 05; invariants 12 and 13 enumerate the exit doors; `ratingOf` feeds the reference, the redemption check (Core.sol:790) and the lens; `creditSaleOn` gates compose through `_pastWindow` and `nextPage`.

### 3.2 tests

* 990 test functions. about 100 (est, range 80 to 130) repeat an assertion on the same path in a second file, mostly the ten `Review*.t.sol` files (155 functions, each the proof file of an archived review), `SaleSmoke`, `LaunchV2`, `Econ`, and owner-door tests spread over `CoreUnit`, `OwnerPowers` and `Lifecycle`.
* about 100 (est by regex) touch the exit side, against `MockExitModule` and `MockExitToken`. they stay. they prove the engine's side of the contract; the real module gets a fork test when its source is published.
* invariant 03 is a strict subset of 12 (Invariants.t.sol:89-99 against 238-251), repeated in every suite. 07 restates 19.
* named bug regressions to keep whatever else moves: `SecFixes55307c4` (24), `audit/PostflightInputs` (2), `PostflightSlots` (8), `invariant/ComposeHostileNotReady`, the `FIXED_` and `ACCEPTED_` tests of `ReviewFlowCore`, `ReviewV2Port` (V2R-1 mid-call flush), `ReviewPort`, `ReviewSale` (S-1, S-9), `Config`, `Resume`, `FeeRouter`, and `Fees::test_countedGasIsCappedAtTheBuybackGasConstant`.
* build and measurement files, not behavior: `BuildIdentity`, `CoreLayout`, `ScriptLint`, `GasCap`, `Rehearsal`, `V2Stack`.
* no test imports `src/Core.sol` (the HANDOFF rule holds).

### 3.3 scripts and process

* the deploy pipeline (Deploy, Resume, Preflight, Postflight, Lock, SystemDeployer, SystemResumer, Builder, NewProd, LaunchConfig) is sound and needed. about 45 of 120 preflight rows guard something that can fail at launch (code at the stack addresses, cross links, code hashes, factory owner and flags, 7702 delegate, balance, predicted addresses empty, metadata placeholders, build hashes). about 65 restate config values (`rule:` rows, `_preConfig`, `_preSettingsRows`, most of `_preSignoff`). about 40 postflight rows echo the config the same struct wrote.
* `director.py` (943 lines), `test_director.py` (839), `project/*.json` (124 KB) and about 30 record documents exist to feed a gate graph nobody in code or CI reads. all 71 records are invalid. the deploy gate fails at HEAD and DEPLOY step 6 depends on it. the only functional coupling outside the director is `check-preflight.sh`, which requires the state file's candidate to be an ancestor of HEAD (`script/Checks.sol:74` is a comment).
* `script/tools/guard-forge-test.sh` and `.claude/settings.json` guard agent sessions against whole-suite runs.
* `sim/engine.js` mirrors the bid rule, the curve, the credit sale, compose and the exit bid by hand ("ported from src/Core.sol"). 1,704 assertions pass. nothing cross-checks it against Solidity. FLOW cites it at decisions 37, 41, 63, 69. nothing depends on it today.

### 3.4 docs

* no doc is pinned to the candidate. stale rows in HANDOFF (decisions "1 to 93", candidate 6ea44f5, "gates are green", 116 preflight rows, A-OWNER-DECISIONS v9 at "1 to 78", the director repair "not pushed" though merged), ARCHITECTURE line 13, NEXT line 3, SIMULATION lines 3 and 11, `script/SetSettings.s.sol:21` ("DEPLOY section 7", there is no section 7).
* FLOW: 99 decisions, 25 marked superseded in place, 10 more superseded without a marker (12, 69, 75, 76, 88, 90, 91, 92, 93, 94). churn chains: scores (1, 55, 80, 84, 90, 94, 95, 96), the statement sale (4, 16, 17, 62, 64, 65, 68, 70, 85, 87, 90, 95, 96), the credit baseline (88, 91, 92, 93, 94, 96 in two days), the exit token auction (9 to 13, 52, 86, 82).
* 16 record files (607,559 bytes) are named by no evidence record. every suite, deep run and rehearsal record except 267139b is superseded by a later one of its type.
* code cites `docs/FLOW.md` sections 2, 9, 10.1, 10.4, 10.6 and decisions 88, 89 (Core.sol, FeeRouter.sol, Interfaces.sol, scripts), and record files (`test/PostflightSlots.t.sol:10`, `test/SecFixes55307c4.t.sol:25`, `script/LaunchConfig.sol:29`, eight Review tests, `test/V2Stack.t.sol:239`, `sim/*`).
* `project/evidence.json:192-209` points at `docs/AUDIT-codex.md`, which does not exist.

### 3.5 on-chain simplification (every feature stays)

measured on 35b78be: Core has 52 errors, 34 events, 46 external functions, 263 comment lines against about 787 code lines. CoreLib declares 22 errors and 10 events that duplicate Core's so delegatecall reverts decode against the Core ABI (CoreLib.sol:97-135). the same bounded staticcall pattern is written in 15 places (CoreLib.sol:644, 659; ControllerV1.sol:507; ten inline sites in CoreLens). `min(stored unit, live unit)` is written in 4 places (CoreLib.sol:607-609, ControllerV1.sol:422, 527, CoreLens.sol:245). `floorRate * score / refScore` is written in 3 places (ControllerV1.sol:346, 433-437, CoreLib.sol:628), which is the decision 96 invariant "the exit bid cost basis equals the controller backstop" held by three copies staying in sync. the constant `DEAD` (Core.sol:199) has no reader.

**tier 1, mechanism: same behavior, same ABI, fewer copies.** no owner decision beyond approval.

| item | today | simpler | saves (est) | risk |
|---|---|---|---|---|
| `settings()` getter | assembly loads three slots and staticcalls `CoreLib.unpack`, which bit-extracts them (Core.sol:1137-1151, CoreLib.sol:184-210). built for size | `return SettingsStore.load();` the compiler emits the same loads inline. delete `unpack` | about 45 lines, one external call on every `settings()` read, which `CoreLens.snapshot` and every controller quote hit | about 300 bytes more in Core, within headroom. repin `BuildIdentity` |
| bounded staticcall | 15 copies of "staticcall with a gas cap, require 32 bytes, else fail or zero" | one internal library `readWord(target, gas, data) returns (bool ok, uint256 word)`, inlined by CoreLib, ControllerV1 and CoreLens. each caller keeps its own policy (CoreLib reverts `BadModule`, controller and lens treat 0 as unpriced). Core's own `_ask` stays | 60 to 90 lines; one bounded read for an auditor to verify instead of 15 | each site's gas cap must be preserved exactly (`READ_GAS`, `ASK_GAS` 200k, `PRICE_GAS` 600k, `NEXT_PAGE_GAS` 500k). Lens and Phase2Flex tests pin it |
| shared arithmetic | 4 copies of the effective unit, 3 copies of the score scaling | two pure helpers, `effectiveUnit(stored, live)` and `scaleByScore(rate, score, ref)`; zero handling stays at the call site | 20 to 30 lines; the decision 96 invariant has one definition | BidRule, Redeem, Phase2Flex pin the numbers |
| dead constant | `DEAD` at Core.sol:199, no reader | delete | 1 line | none |

**tier 2, structural: owner decision.** the linked library and the `CoreState` mirror (CoreLib.sol:29-58, byte-matched to Core's storage, guarded by `test/CoreLayout.t.sol`) and the `_toLib` selector rewrite (Core.sol:990-1000) exist to fit 24,576 bytes. with 6,095 bytes of headroom (stale, re-measure first) the cheap library doors (`rescueCoin`, `rescueNft`, `setSuccessor`, `lockSuccessor`) can return to Core, deleting their stubs and part of the duplicated error and event declarations. `migrate` with its movers and `sellForExitToken` with its helpers are too large to return, so the library stays; this is a trim. `_toLib` itself is already the smallest way to forward a call.

rejected after examination, with the reason: the settings write path (compiler-packed storage struct, CoreLib.sol:155-177, nothing hand-packed); the recovery closed form (a loop would be larger and make the curve depend on when it is evaluated, CoreLib.sol:262-268); the pause window array with its binary search (the controller learns a statement's compose time from the Core record and has no hook at compose to snapshot an accumulator, so paused seconds before `composedAt` need the window array); FeeRouter's `claim` pull path and `splitOn` latch (a reverting payee cannot block `flush`; the flush that crosses `splitStart` pays payees nothing); `pullFees` at every door with `receive` reverting `Measuring` (the V2R-1 fix, a mid-measurement flush would understate a caller's cost); the forbidden target list (a security complement of the allowlist, no simpler rule gives the same set); the three rate getters (`ethRate`, `ethPrice`, `floorRate` are three values with distinct consumers); the no-`minOut` overloads (an ABI change); the per-door gas constants (real gas profiles and grief caps, `_payment` is already the one shared formula).

**tier 3, rules: each reverses an owner decision; outcome change at launch values stated.** ranked by concepts removed per outcome changed. the statement price today depends on about 30 numbers (est): the whole eth bid machine through `floorRate` (9 state words, 9 settings), then cost, rating, `refScore`, the anchor (3 settings, 2 state words), 6 curve settings, `saleFloorBps`, the pause history and the value floor.

| rank | rule today | simpler rule | outcome change at launch values | reverses | removes |
|---|---|---|---|---|---|
| 1 | the statement anchor: up only, halves over `anchorHalfLife`, a sale above it moves it halfway to the sale bps when cost is at least `anchorMinCost` (ControllerV1.sol:318-331, 576-601) | start price = `markupBps` of the reference, no anchor | a hot market no longer lifts later start prices above 150 percent (today up to `startCapBps`). the reference already tracks the engine's realized credit price through `floorRate` (95, 96), so the credit-level discovery stays | 62, 64, 70. decisions 64 (M1, a buy at the floor lowered every open listing) and 70 (F1, 80 wei statements raised the anchor to the cap) were security patches to the anchor itself | 3 settings, 2 state words, 3 setters, `_moveAnchor`, `_setAnchor`, `_setAnchorStored`, `anchorBps`, 2 events (about 60 lines) |
| 2 | `buybackDelay` blocks plus `lastBuybackBlock` and `TooSoon` (Core.sol:247, 828) on top of the slice bound | the slice bound alone (`buybackSlice` at most 1 eth, at least twice the keeper pay, decision 51) | buybacks may run every block in smaller slices; the sandwich bound of decision 51 still holds | none recorded | 1 setting, 1 state word, 1 error |
| 3 | `exitSlippageBps` and `exitBidMarginBps`, bound-coupled (slippage at most margin, SettingsBounds.sol:40) | one exit margin for both the redemption tolerance and the bid discount | the redemption tolerance equals the bid discount (20 percent at launch instead of 2 and 20) | 84 | 1 setting, 1 cross bound |
| 4 | `creditCostToPotBps`, an owner split of credit sale proceeds, 10_000 at launch | cost share to the pot, the rest to the buyback, fixed | none at launch | 88 | 1 setting, 1 setter |
| 5 | the two-stage bid recovery: `recoveryClimbPerMinBps` below the gap, `climbPerMinBps` above, the crossing solved in closed form (CoreLib.sol:269-299) | one climb rate toward the ceiling | a 140 credit dump recovers in about 139 minutes at 0.5 percent a minute instead of 59 measured (FLOW 77); a single 2 percent rate gives about 35 minutes but brings back the lone-seller leak of decision 74 (1.67 against 0.53 eth an hour) | 74, 75, 77 | 2 settings, `_recover`, the lnWad crossing (about 45 lines) |
| 6 | the credit sale `creditStartBps` and `creditFloorBps` | one start multiple of the floor | none at launch | 88 | 1 setting |
| 7 | `addTarget`, `removeTarget`, `lockTargets`, `targetsLocked` for `buyListing` | two fixed targets (Seaport, CreditStrategy) with the forbidden list kept | a future marketplace needs a redeploy | 57 | 3 functions, 1 lock, 2 events |

kept on purpose after examination: the two-stage statement decay (`kneeBps`, `slowDecayBpsPerHour`; inert at launch because knee equals floor, but decision 85 plans the slow stage for after the exit token is live); the minute-bucket drop floor (`dropFloorBps`; caps a multi-transaction walk-down within one minute, part of the decision 95 manipulation story); `idleLoosenBps` (the only way the bid rises with no sellers); the remembered peak and `floorRate`; `exitMode` as a tri-state (86 designed hold as its own state); the stored `unitPerPoint` with `refreshUnitPerPoint` and the lower-of read (84: a module cannot lower what a redemption owes on its own); the four separate locks; `migrate` batching by `maxCredits`; the separate keeper and caller fee pairs (66, 67 made compose pay independent of keeper pay).

## 4. the three options

### A. conservative pruning with the on-chain simplification pass (recommended)

every feature stays. tier 1 of section 3.5 (mechanism, behavior and ABI preserved), tier 2 if the re-measured headroom allows, the tier 3 rules the owner approves one by one, and the supporting work of section 6.

* user outcome: unchanged by tiers 1 and 2. tier 3 changes are listed per item with their outcome at launch values; none removes a feature.
* understanding burden: tier 1 collapses 15 bounded reads and 7 arithmetic copies to 4 definitions and removes one hot-path external call. tier 3 rank 1 alone (the anchor) removes 3 settings, 2 state words, 3 setters and 2 events, and takes the statement price prediction set from about 30 numbers to about 25 (est); ranks 1 and 5 together to about 22. knobs from 43 to 37 with ranks 1 to 4 (est). supporting work: docs from 3.44 MB to under 1 MB (est), test functions from 990 to about 890, preflight and postflight rows from 218 to about 120, the process tool and its ledger gone, one document (HANDOFF) that is correct.
* risk: low. tier 1 is pinned by existing tests. every option needs the one fresh full review that HEAD lacks; tier 3 items add review scope only where a formula changes.
* what it leaves: every switched subsystem in the audited surface, which is the product.

### B. launch-posture v1 (withdrawn)

the first draft proposed removing the exit side, the redeem burn reserve, the exit pool value floor, the credit sale window and chosen composition because they are off at launch. the owner's instruction of 2026-10-13 (decision 99) rejects it: the switches are the launch mechanism, and the exit side is the differentiator. withdrawn. the dependency map of section 3.1 and the challenge findings of section 9 stay as review input.

### C. clean sheet

one Core without a library, one controller, FeeRouter reused, CoreLens dropped, a new test suite.

* what it would save: the accidental structure (CoreLib split, `CoreState`, generated interfaces, the `Settings` packing) and the naming residue of removed designs. the split is forced by bytes (34,965 for Core plus CoreLib) and would return in any rewrite of the same feature set.
* what it costs: the bid rule, the Seaport fill with its forbidden-target logic, the v4 unlock swap with the sandwich bound, the router pull inside measured calls (V2R-1), the 7702 resume path, the slot-masked postflight and the exit side's reentrancy proofs would be rewritten to the same requirements. the named regressions in section 3.2 record real bugs in exactly these parts. the 0c3ecd2 review and the acceptances become history.
* judgment: C is the right call only if the kept parts were themselves wrong. the investigations found them reviewed, pinned and stable. not recommended.

## 5. what stays, what goes (summary table)

| area | stays | removed or simplified |
|---|---|---|
| src | every feature, every door, every switch, the full bid rule, the exit side, the credit sale, chosen composition, pause, migrate, locks, FeeRouter unchanged | tier 1: `CoreLib.unpack` and the assembly `settings()` getter, 14 of 15 bounded staticcall copies, 5 of 7 arithmetic copies, `DEAD`. tier 2 (owner, after re-measuring bytes): the four cheap library doors back in Core with their stubs and duplicate declarations. tier 3 (owner, per item): the statement anchor, `buybackDelay`, the second exit margin, `creditCostToPotBps`, the two-stage recovery, the second credit sale knob, the target setters |
| scripts | Deploy, Resume, Preflight, Postflight, Lock, SetSettings, LaunchConfig parser and pins, the about 45 failure rows, build pins (re-measured at the freeze), slot readbacks, lock rows | about 100 config-echo rows, `defaultConfig` in LaunchConfig (JSON is the one source), `rehearsal.json` as a 2-field override, `director.py`, `test_director.py`, `project/`, the director coupling in `check-preflight.sh`, `guard-forge-test.sh` and `.claude/settings.json` |
| tests | every behavior file, every file of section 3.2's regression list, `BuildIdentity`, `CoreLayout`, `ScriptLint`, `GasCap`, `Rehearsal`, `V2Stack`, `ReviewMatrix` and `ReviewDeploy` (cited by DEPLOY), all invariant suites | `SaleSmoke`, `LaunchV2`, `Econ`, `Gate` merged into `Sale`, `Launch`, `BidRule`, `RateFuzz`; the duplicate halves of `ReviewSale`, `ReviewCore`, `ReviewStatements`, `ReviewEcon`, `ReviewFlowCore` moved into the base files and the shells deleted; `ReviewPort`, `ReviewV2Port`, `ReviewDeploy`, `Lifecycle`, `CoreUnit` trimmed of their copies; invariant 03 |
| sim | `docs/SIMULATION.md` conclusions, shortened | `sim/` to `docs/archive/sim/` with SIMULATION.md. the owner may restore it for a retune; it mirrors rules by hand and has no parity check |
| docs | README, AGENTS, FLOW (all 99 rows, markers fixed, sections code cites kept), ARCHITECTURE (section 1 without record cites, 2, 10, 14), DEPLOY (0 to 3, 5, 6, owner commands of 4, plus a checklist replacing the director gate), INTEGRATION refreshed, HANDOFF rewritten to about 60 lines, the baseline records until the next review (REVIEW-security-0c3ecd2, ACCEPTANCE-0c3ecd2, REVIEW-security-55307c4, REVIEW-external-contracts, REVIEW-sandwich-delegate, REHEARSAL-267139b, SUITE-267139b, DEEP-RUN-267139b) | 31 superseded records to `docs/archive/` with their citing paths edited, `archive/sim/results` and `archive/reference` deleted (git keeps them, the archive README keeps the MIT attribution), NEXT folded into HANDOFF |
| branches | main, the UI branches (outside this review) | `claude/repair-project-director-1366be` (merged) |

## 6. supporting work

1. archive the 31 superseded records and fix the citing paths in `test/PostflightSlots.t.sol:10`, `test/SecFixes55307c4.t.sol:25`, `script/LaunchConfig.sol:29`, `test/V2Stack.t.sol:239` and the eight Review tests in the same commit.
2. delete `docs/archive/sim/results` (1,059,314 bytes) and `docs/archive/reference` (332,319 bytes). `sim/run.mjs` regenerates the results and git history keeps the sources.
3. retire `script/director.py`, `script/test_director.py`, `project/`, `script/tools/guard-forge-test.sh`, `.claude/settings.json`. replace the deploy gate with a checklist in DEPLOY.md: clean tree, HEAD equals the reviewed commit, `forge build --sizes` matches the pinned bytes, preflight passes at the latest block with the expected rows, the dry run passes.
4. merge the duplicate tests per section 3.2, delete invariant 03, fix the `InvariantsSale.t.sol` header.
5. drop the config-echo rows from Checks and Postflight, remove `defaultConfig`, make `rehearsal.json` an override.
6. move `sim/` to `docs/archive/sim/`, shorten SIMULATION.md to its conclusions.
7. rewrite HANDOFF, shrink ARCHITECTURE, FLOW, DEPLOY, fold NEXT, fix the ten unmarked superseded rows and `script/SetSettings.s.sol:21`.
8. delete the merged branch.

## 7. unresolved decisions (owner)

1. **approve option A** with tier 1 of section 3.5.
2. **tier 2.** fold the four cheap library doors back into Core if the re-measured headroom allows. yes or no.
3. **tier 3, one answer per rank.** the recommended set is ranks 1 to 4: the anchor (the largest concept removal, two past security patches, the reference now carries discovery), `buybackDelay`, the second exit margin, `creditCostToPotBps`. rank 5 (the recovery solver) triples the dump recovery time at launch values and stays unless the owner accepts that. ranks 6 and 7 are small and optional.
4. **the sim.** archive it (section 6 item 6) or keep it live. it has no dependents and no parity check; keeping it means porting every rule change by hand, including any tier 3 change.
5. **the director tooling.** retire it (section 6 item 3) or repair it. repair means a new freeze, re-recording every carrier, and keeping the gate in the runbook; retire means a checklist plus the Solidity preflight and postflight carry the launch checks.
6. **the next freeze and review.** no record covers HEAD. one full independent review of the source replaces the delta chain. the exit side is in scope against the stand-ins; a fork test against the real module follows when its source is published.
7. open from before and unchanged by this review: decision 47 (burn router readiness), OD-2 (`lockAllowlist`, `router.lock`), the owner keeper, launch-day `rateStart`, image and description.

## 8. implementation plan (after approval)

each step is one reviewable change, verified by `forge build` and `forge test --match-path` on the files it touches, committed separately. the full suite, the deep invariants and the rehearsal run once, on the frozen candidate at the end.

1. **measure.** `forge build --sizes` at HEAD, recorded in this file. decides tier 2.
2. **tier 1, one commit per item.** `settings()` getter and `unpack`; the bounded read library; the two arithmetic helpers; `DEAD`. regenerate interfaces, repin `BuildIdentity` after each. verify: `Flow`, `SetSettings`, `Config`, `Lens`, `Phase2Flex`, `BidRule`, `Redeem`, `RatingReference`, `CreditSale` test files.
3. **tier 2 if approved.** the four doors back into Core. verify: `Rescue`, `Migrate`, `OwnerPowers`, `CoreLayout`, `BuildIdentity`.
4. **tier 3, one commit per approved rank**, each with its FLOW row (decision 100 onward), its ARCHITECTURE section 1 row, its config field removed from `mainnet.json`, `SettingsFields`, Checks and Postflight, and its tests rewritten. verify: `Sale` and `RatingReference` (anchor), `Fees` buyback tests (delay), `Redeem` and `OnePile` (margin), `CreditSale` (cost split).
5. **records and branches.** section 6 items 1, 2, 8. cites fixed in the same commit. verify: `forge build`, grep for the old paths returns nothing.
6. **tests merged.** section 6 item 4. verify: the merged files pass, the named regressions are present by grep.
7. **scripts and director.** section 6 items 3 and 5. verify: `Config`, `PostflightSlots`, `Resume`, `Lock`, `SetSettings` test files, `check-preflight.sh` on a fork.
8. **sim.** section 6 item 6, with the tier 3 rules ported if the sim stays live. verify: `node sim/engine.test.mjs`, README updated.
9. **docs.** section 6 item 7. verify: every path a doc or a comment cites exists (a grep script run once).
10. **freeze.** `CANDIDATE_RUN=1` full suite, the 7 deep suites, the rehearsal on a fork. one independent security review of the whole source. the owner's sign-off.

a local commit authorizes nothing further. pushing, merging, deploying and every mainnet transaction wait for the owner's explicit instruction.

## 9. evidence and challenge

the five investigation reports and the challenge report are in this session's transcript. their measured figures are reproduced above; the file:line cites are theirs and point at 35b78be.

challenge findings on the first draft and their disposition:

| finding | disposition |
|---|---|
| the first draft attributed the `floorRate` reference term to the exit side; decision 96 makes it the launch-time manipulation floor | adopted in revision 1 |
| `migrate` moving held statements adds a bounded loop and an `adoptStatement` on an unwritten successor | adopted in revision 1, dropped |
| `atFloor`, Core `_atFloor`, lens `exitEligible`, Core `_pastWindow`, `InWindow`, the compose window checks, the `rating` compose read were missing from the dependency map | adopted: section 3.1 lists them as coupling |
| invariants 12 and 13 enumerate exit doors | noted in section 3.1 coupling |
| the CoreLib merge is unlikely to fit (34,965 bytes before cuts, about 10,400 to shed) | adopted: the split stays in every option |
| the test count by the draft's own command is 990, not 973 | adopted |
| the pause age windows and the rating reference are same-cycle owner decisions, not dormant code | adopted |
| removing `ethRedeemBurn` would be consistent with `receive`, `skim` and invariant 05 | moot after decision 99 |

owner instruction on the first draft, 2026-10-13 (decision 99): the exit side is core and a differentiator; `exitMode` is 0 at launch only because the exit token is not live and the engine launches before it. disposition: option B withdrawn, recommendation moved to A, FLOW and ARCHITECTURE section 1 updated in the same turn.

commands that reproduce the headline numbers:

```
git ls-files docs | xargs wc -c | tail -1
wc -l src/*.sol src/lib/*.sol src/interfaces/*.sol
grep -h "function test" test/*.t.sol test/*/*.t.sol | wc -l
python3 script/director.py status
python3 script/director.py check --gate deploy
```
