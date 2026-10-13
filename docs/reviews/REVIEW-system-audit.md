# system audit of the seven untraced paths, 2026-10-10

four read only auditor subagents, each in a fresh context, traced the paths of objective OBJ-LAUNCH-1 at eff3051 (source equal to a6f6f6d) with the method of the project-director skill (references/system-audit.md): acceptance cases first, then the tests, then counterexamples. none edited the repository. figures are labelled measured [M], derived [D], assumed [A] or projected [P] where the source is a model.

## 1. fee intake (pool skim, FeeRouter, Core receive, the five door pulls)

no value can be taken or stranded. every acceptance case is covered except a payee that calls a Core door from its callback (safe by reading: the door is `nonReentrant`) and a check that the launch payee accepts eth.

| finding | class | action |
|---|---|---|
| eth received after `splitStart` and before the first flush goes wholly to the engine, because that flush only turns the split on | operational | runbook: call `flush()` at `splitStart` |
| the launch payee 0xCB43 is an EIP 7702 delegated account. it accepts eth with 21,200 gas today. a later delegate that reverts sends the payee share to `owed`, which it cannot claim | operational | preflight row: call the payee with 100,000 gas |

## 2. credit purchase (the bid rule, sellForEth, buyListing, the hourly window, adopt)

decision 44 (an empty pot never raises the price) and 46 (the caller tip never makes `cost + tip` exceed the bid) hold. a colluding listing seller and keeper get at most about 0.85 of the bid.

| finding | class | action |
|---|---|---|
| the bid follows a rising market slower than recorded. minutes to reach a multiple of the last fill at launch settings [D, model of `CoreLib.climb` reproducing the BidRule tests]: 1.25x 46, 1.5x 100, 2x 300, 3x 700, 4x 1,100. the 45 minutes in ARCHITECTURE section 1 and FLOW 49 hold only up to 1.25x | intent, owner | OD-3 reopened |
| a seller can drag the bid: 135 credits in 3 minutes leave the price state at 0.52 of the start, recovery 279 minutes, at a cost of about 0.3 eth of discount | intent, owner | OD-3 |
| `idleLoosenBps` 0 with `ceilBps` 10_000 is a legal setting under which the bid never rises above the last fill (`test_gapUp100Percent_withoutLooseningTheBidParks` asserts it) | intent, owner | OD-3 |
| with no fill the bid climbs blind: 1.35x of the last fill after 1 hour, 4.85x after 24 hours. a market below that bid lets a seller fill a minute of credits above market, bounded by the pot and the minute floor | missing evidence | competing bidder behavior is unmeasured |

## 3. statement sale and proceeds

every wei of a sale traced to its holder: auction proceeds sit in the house until `collectSales` or `buyback`, `_book` splits them by `saleToBuybackBps`, the buyback burns its share. no path sells below the floor in force at listing, books a sale twice or lets a non owner take a statement.

| finding | class | action |
|---|---|---|
| the buyback sandwich bound is measured at launch pool depth only. if depth falls with price, a 2 eth slice turns profitable for an attacker after about a 25 percent fall in the coin price [D, square root depth assumption] | unproved | measure the sandwich at 0.25x and 0.1x depth |
| `auctionDuration` reaches new listings only. `repriceStatement` does not change an old listing's duration, while section 2 says every number applies at once | doc | state it |
| `ethToBuyback` leaves only through a working swap. a pool or hook failure holds half of all sale proceeds | doc | state it |
| `collectSales` and `endAuction` pay no caller. the buyback tip breaks even at about 5 gwei for the average slice | unproved | same class as the unpaid composer |
| at hour 105 the ask reaches the 75 percent floor as `exitAfter` opens, so in phase 2 a paid exit can beat an unpaid bidder | intent | recorded, no owner words on it |

## 4. phase 2 exit

a hostile or dust exitModule can take what the trust note in ARCHITECTURE section 10 admits, plus the `exitStatement` repay of at most `reimburseCapBps` of each statement's cost.

| finding | class | action |
|---|---|---|
| `migrate` moves eth, credits and exit token in one call. an exit token whose `transfer` reverts blocks the whole migration and leaves `retired` false (probe test) | correctness, liveness | fix within FLOW 48: the exit token leg skips on failure and its pots stay |
| the exit token analogue of the owner overpay drain (short `xAuctionHalfLife`, raised unit) is not named in the trust note | doc | state it |

## 5. owner powers and locks

every owner directed outflow is `rescueCoin`, `rescueNft` or `migrate`. the drain figures of section 10 reproduce exactly: 13.04 eth pot, 99.99 percent in one block, credits worth 0.196 eth at the loosest settings and 1.584 eth at launch settings.

| finding | class | action |
|---|---|---|
| the owner 0xCB43 delegates under EIP 7702 to 0x612373d7003d694220f7800eeaf8e3924c0951d3, a 24 KB smart account with `validateUserOp`, `isValidSignature` and multicall. it decides who acts as factory owner, Core owner, router owner and coin admin. its address, code hash and auth model are recorded nowhere | unproved | read the delegate, record address and code hash, add a preflight row |
| after `coin.lockAllowlist()` `rescueCoin` reaches only already listed addresses | doc | add to OD-2 |

## 6. launch runbook

109 preflight rows, two failing before the owner's factory step, 99 postflight rows: confirmed on a fork at block 26163771. live factory minimum skim share 1,000, deploy fee 0.069 eth, owner balance 0.068017 eth.

| finding | class | action |
|---|---|---|
| the successor runbook cannot be followed with the shipped scripts. `Deploy.s.sol` always launches a new coin and router, and migrated eth and exit token reach the successor unbooked until `successor.skim()` | runbook | add the `skim` step. a successor deploy script is work for the first migration, outside the launch |
| `SetSettings` send command has no `--slow`, from a delegated account: `setSettings` can land while `setRate` is rejected | operational | add `--slow` |
| step 6 runs the director gate after builds that rewrite `foundry.lock` and `lib/solady` | operational | restore both before the gate |
| the by hand `setSplitStart` uses the current block time, `SetSettings` gives no warning when a new `rateCap` sits below the live bid, deploy gas is 17,556,516 against 18,137,749 in the docs | doc | fix |

## 7. participant economics (simulator, 3 seeds, 90 days)

measured inputs: 1,944 eth of the comparable coin's volume over 13 days, the 0.0089 eth credit median, 42 statement sales at a median 0.84 of their parts' market value, gas from test/GasCap.t.sol. assumed: the 90 day fit, the seller book, statement demand (8 a day decaying to 2), no competing bidders, free composers and keepers. the simulator's bid rule matches a port of `CoreLib` within 1.7e-7. decision 48 is not modelled.

| 90 days at 1x volume, 0.0089 eth | value |
|---|---|
| credits bought, eth paid to sellers [P] | 32,727, 279 |
| statement sales returned [P] | 94 eth, 34 percent of the spend (51 percent at 0.5x volume, 19 percent at 2x) |
| burned for holders [P] | 46.9 eth, from statement sales only (`feeToBuybackBps` 0) |
| unsold statements, the fallback exposure [P] | 224 at 168 eth of cost, phase 2 price unknown |
| owner payee [D on P] | 12.3 eth, 75 percent of it on launch day, 0.23 eth after day 30 |
| owner compose cost if the owner composes every page, 408 pages [D on P] | 1.8 eth at 0.5 gwei, 7.1 at 2, 35.6 at 10 |
| break even gas for the backstop composer | 2.9 to 5.6 gwei over 90 days, about 0.55 gwei after day 30 |
| steady credits a day | 62, 63, 65 at 0.5x, 1x, 2x volume: set by statement demand, 7.6 a day with no late buyers |

goals: credits flow into statements only while statements sell and someone composes. the engine is too small after day 18 to move the credit floor either way. nobody is overpaid: the peak bid is 0.954 of market and tips total under 0.3 eth.

stale: sim/README.md batches (credits 31,510 in the doc, 32,262 on a 5 seed rerun), its sections 7 to 9 and sensitivity row 20, the 564 check count (563 now), sim/data/notes.md's per point tables, the 394 pages of docs/reviews/REVIEW-decisions.md path A (403 now).

## not examined

the 7702 delegate source, the live v2 contracts beyond the tests, the exitModule (it does not exist), a real broadcast, `--slow` on a real node, the deep invariants.
