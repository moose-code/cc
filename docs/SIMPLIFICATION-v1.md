# simplification review: the agreed product, built today

date 2026-10-13. basis: docs/DECISIONS.md section 11 (the product agreement, decisions 99 to 108). method: four read-only measurement sweeps of src, script, test, sim and docs, a clean sheet design, an independent adversarial challenge of that design against the code, and this report with the challenge's fixes folded in. nothing is changed yet. "measured" means read from the tree today; "projected" means an estimate for the design.

## 0. summary

the on chain feature set is fixed by the agreement. the complexity that multiplies across paths is in the mechanics around it: a fee router with its own owner and split clock, a read only lens, balance measuring around marketplace calls, a pause implemented as a window array, two storage conventions, nonce based address prediction, and a deploy, preflight, postflight, evidence and documentation apparatus sized for all of that.

recommendation: one coherent design (section 2), delivered by pruning the current code to it in a fixed order (section 7), tests and docs rewritten to the result, one freeze at the end. a rebuild from an empty file would re-derive the bid and the fork fixtures and discard the current evidence for no feature gain.

| measured today | projected after |
|---|---|
| 5 contracts (Core, CoreLib, ControllerV1, FeeRouter, CoreLens) | 3 (Engine, EngineLib, Controller) plus one small adapter per venue (2 at launch) |
| src 4,205 LOC, 23 settings | about 3,400 LOC, 24 settings (two balance switches and the payee share replace `balanceMode` and `feeToBuybackBps`) |
| deploy 8 transactions, a Resume run, a Lock run, nonce pinning | 5 transactions, no Resume, no nonce pinning, Lock later |
| preflight 95 rows, postflight 67, 15 env vars | about 70, 45, 8 |
| tests 62 files, 27,414 LOC, 990 tests, 21 invariants | about 50 files, 22,000 LOC, 18 invariants |
| docs 102 files, 3.46 MB (0.85 MB of logs, 1.08 MB archived sim) | about 30 files, under 1 MB; logs and the archived sim leave the tree |
| director ledger 71 evidence records, 0 valid at the tip, 1,782 LOC of python | owner decision (section 6) |

## 1. the agreed product

docs/DECISIONS.md section 11. in one line: fees fund a permanent public bid for Credits; cheaper listings are swept through priced adapters with the gap kept; 80 Credits become a Statement sold from above cost down to an owner floor; half of every sale burns CC; the balance side redeems by rating, buys by score and burns from a reserve, built and off until the balance token is live; the owner sets every number at once; one way locks and a successor migration; the bid as built; one `pointValue` pricing rule; one Statement floor; pause; the anchor; the credit sale window and chosen composition off; the paid compose path off.

## 2. the design

### 2.1 contracts

| contract | role |
|---|---|
| Engine, with EngineLib by delegatecall | custody, pots, the bid, the pile, compose and composeChosen, sale booking, the pause clock, buyback, the balance side, owner powers, four locks, migrate, rescue, `releaseRedeemBurn` |
| Controller | pricing policy: Statement curve and anchor, credit sale prices, `pointRate` and `pointValue`, the pool key. swappable, lockable |
| ListingAdapter, one per venue | read only: price a listing from the venue's own data, refuse eth to anyone but the seller and allowlisted fee recipients, return `(target, value, calldata)`. launch: Seaport 1.6 basic orders, CreditStrategy |

the library stays: Core plus CoreLib hold 35,315 bytes of runtime today (measured), the limit is 24,576, and the removals below take out less than the difference (projected).

### 2.2 fee intake without a router

the Engine is the pool's bounty recipient. `receive()` accepts eth from the hook only (one address compare, inside the hook's 2,300 gas push; a reverting recipient makes the hook credit the escrow, so the hook path cannot break). a plain send from anyone else reverts, so everything that arrives through `receive` is fee income by construction. every door and a permissionless `book()` (reentrancy guarded) start with `_book()`:

```
income = balance - msg.value - (ethPot + ethToBuyback + ethRedeemBurn) - payeeOwed
payee share: payeePpm of income, as a pull claim (payeeOwed, claim()), only once payeeOn
reserve:     feeToRedeemBurnBps of the rest
pot:         the remainder
balance token: balance - balancePot booked to balancePot (what skim does today)
```

the anti sniper window rule of decision 26 is kept exactly: before `factory.deploymentInfo(coin).launchedAt + sniperSeconds` nothing is shared; the first book at or after it shares nothing and latches `payeeOn`. no Resume run, no `splitStart`. the payee share is in ppm (75,185 at launch for 0.5 points of volume, decision 112; cap 200,000), one payee address, a splitter contract for more.

eth that is not fee income enters through a door that books it itself, to the pot whole: `fund()` (payable, anyone, any amount; a donor, or a predecessor engine on `migrate`) and `collectEscrow()` (claims the Engine's escrow credit, the refund of a partial buyback fill, not expected in practice, and books the delta). a plain send from anyone but the hook reverts with an error that names `fund()`. a Seaport surplus during `buyListing` would come from Seaport, which `receive` refuses, so that listing fails and nothing is misbooked; a hook push that lands mid call (a zone or seller swapping) is fee income and is booked by the next `_book`. `skim()` and the plain send path disappear.

the coin address: the Engine constructor takes the launch config and computes `COIN` as an immutable through `factory.predictToken(owner, config with bountyRecipient = address(this))`, a view whose caller does not matter (Builder.sol:101-103, verified). the circularity the router breaks today is broken the same way.

### 2.3 buyListing without measuring

`buyListing(adapter, id, params)`: the adapter must be approved; the Engine reads it by staticcall, runs the forbidden target check on the returned target, requires `value <= bid` and `value <= ethPot`, requires it does not already own the credit, calls the target with `value`, requires its credit balance rose by exactly one and it owns `id`, requires `balance >= before - value` (a surplus is booked as income by the next `_book`, a shortfall reverts). the caller is paid `min(countedGas, BUYLISTING_GAS) * min(basefee, keeperMaxBaseFee) + keeperFee` from the pot, capped at `bid - value`, and the cost basis is `value + payment` as today. the eth measuring flag, the `Measuring` revert in `receive`, `BadCost` and the mid call booking rules disappear. the redeem door keeps its balance token delta check (a different measurement, kept).

the Seaport adapter sums every consideration item and the additional recipients, checks each recipient against the seller and an owner allowlist on the adapter (OpenSea fee collector, the Credits royalty recipient), and refuses anything else, which closes the self payment hole (section 14 item 51). the CreditStrategy adapter returns `nftForSale(id)` as the exact value. adapters are approved with `addAdapter`, removed with `removeAdapter`, closed with `lockAdapters` (the target functions renamed).

### 2.4 pause in O(1), in the Engine

the Engine keeps `paused`, `pausedTotal` and `pausedSince`. a Statement record stores `pauseMark = pausedTotal + (paused ? composedAt - pausedSince : 0)` at compose (a uint40 fits the record's free bits). age = `(now - composedAt) - (P(now) - pauseMark)` with `P(now) = pausedTotal + (paused ? now - pausedSince : 0)`. a Statement composed inside a pause has age zero at resume. `setPaused` on the Engine; `sellTo` and `sellCreditTo` revert `Paused`, so a controller swap cannot reset the clock and the credit sale stops in a pause (decision 97). replaces 55 lines, an append only window array and a binary search (83,205 gas cold at 1,000 windows, measured) with three words and one subtraction.

### 2.5 pricing on one rule, the royalty, the composer

decisions 104 and 105 as recorded: `pointRate = floorRate / refScore`, `pointValue = max(pointRate, unit * poolPrice)` in the Controller; Statement reference `max(cost, rating * pointValue)`; credit floor `max(cost, score * pointValue) * creditFloorBps / 10_000`; a balance bought credit costs `score * pointRate`; the unit read live from the module; one floor, `saleFloorBps` on the Engine, the curve falls to it, the knee stays.

the royalty (decision 112) sits after the curve and the floors: the controller's `buy` and `buyCredit` take `p * royaltyBps / 10_000` on top of the engine price `p`, forward `p` to the Engine and credit `royaltyRecipient` a pull claim. `royaltyBps` 250 and the recipient are controller settings, effective at once. a gross price view serves frontends. the Statement record stores its composer at compose (decision 111); no payout in v1, a later controller pays composer and referral cuts out of the price above the floor the same way.

### 2.6 settings and storage

`Settings`, 24 fields: the nine bid fields with `rateCap`, `saleFloorBps`, `saleToBuybackBps`, `feeToRedeemBurnBps`, `redeemSlippageBps`, `balanceBidMarginBps`, `redeemBurnBps`, `buybackSlice`, `buybackDelay`, `keeperFee`, `keeperMaxBaseFee`, `callerFee`, `callerMaxBaseFee`, `redeemOn`, `balanceBidOn`, `payeePpm`. bounds: `payeePpm` at most 200,000; the rest as today. the count does not fall: `balanceMode` becomes two flags and the payee share moves in from the router. the knobs removed by the agreement (`floorBps`, the stored unit) were on the controller or were functions.

one `State` struct at slot 0 holds every Engine variable, used by the Engine and the library through the same type. `CoreState`, `SettingsStore` and `RateStore` go; only tests read those fixed slots today (verified). the packed settings decode stays in the library.

### 2.7 deploy

five transactions: EngineLib (CREATE2), Engine (CREATE2, constructor without the controller), Controller (CREATE2, constructor with the Engine address), `engine.setController`, the launch through the factory. the controller and engine addresses depend on bytecode and config, the coin on `predictToken`. `CONTROLLER_NONCE` and the "send nothing between steps" rule disappear. preflight keeps the v2 code hash pins, the config bounds, the balance, the metadata rows and the launch simulation; the config echo rows go (the config hash covers them), the lens, router and nonce rows go. postflight reads the Engine, the Controller, the pool and the coin. `lockRecipients` is a later owner call (section 6, decision A).

### 2.8 operations

permissionless, paid by rule: `buyback`, `buyListing`, `compose`, `composeChosen`, `redeemStatement`, `book`. compose and redeem pay 0 until the owner switches them on. the owner keeper is a bounty bot, post launch. manual duties stay the same: compose when nobody does, lower the floor to clear Statements, raise `rateCap` when the market passes it, set the balance module and the pool key when the token ships, `releaseRedeemBurn` to move reserve eth to the buyback.

### 2.9 recovery and shutdown

unchanged in meaning: `rescueCoin`, `rescueNft`, `setSuccessor`, `lockSuccessor`, `migrate(maxCredits)` with retirement (the pot moves through `successor.fund`), `adopt` on the successor. a retired Engine sells out and redeems its Statements, burns its buyback pot, and books fees that still reach it until the coin admin repoints the bounty recipient.

## 3. where the complexity comes from

| source | promise that needs it | simpler mechanism | relax a promise? | who pays |
|---|---|---|---|---|
| FeeRouter: own owner, lock, payee list with `owed`, split start, Resume run, flush inside every door | fees reach the pot by themselves; the payee share; no share in the sniper window; only fees are shared | the Engine as recipient with `receive` open to the hook only, `_book` on every door, a ppm claim, a latch read from the factory record | none | a holder loses the launch time seal on the pool side while migration stays open (section 6, A) |
| eth measuring around `buyListing` | the engine never pays above its bid for a swept listing | adapters price the order, the Engine checks exact arrival | none (decision 100 already chose adapters) | a new venue needs an adapter before the engine sweeps it; bots cover it through `sellForEth` meanwhile |
| CoreLens | a frontend and a keeper read the state in one call | Multicall3 over Engine and Controller views, plus one Engine view that quotes the bid after pending income | none | the UI branch replaces one `snapshot` read with a multicall |
| pause window array and binary search | a pause holds each Statement's age | three words in the Engine and one mark per Statement | none | nothing |
| stored unit, min rule, `refreshUnitPerPoint` | the module cannot lower what a redemption owes without an owner call | the module is ours; read live | relaxes a guard against our own contract | nothing |
| separate value floor, baseline, backstop | a Statement or credit is never sold for eth below its balance value | `pointValue` once | none | nothing |
| two Statement floors, knee | the curve shape and the custody floor | one floor on the Engine; the knee stays | none | nothing |
| `balanceMode` tri state | redeem and bid switches | two flags | none | nothing |
| `feeToBuybackBps` | fees can burn | the reserve and `releaseRedeemBurn` | none | the owner releases by hand |
| two storage conventions, 15 assembly blocks | the library shares the Engine's storage safely | one struct type at slot 0 | none | nothing; the layout test shrinks to one |
| nonce based predictions, `CONTROLLER_NONCE`, Resume | addresses known before the launch | CREATE2 for every contract of ours | none | nothing |
| the bid: ten knobs, peak, recovery, minute floor | decisions 44, 45, 49, 69, 74, 103 | none that keeps all of them | decision 103 says keep | kept as built |
| migration: successor, retire, `adopt`, `fund` | the agreement names the successor migration | a plain owner withdrawal would be simpler and breaks the hard rule | no | kept |
| caller and keeper payments, four knobs | permissionless doors that pay their caller, compose off at launch | one pair would make compose and buyListing share a switch | decision 108 keeps the compose pair | kept |
| preflight 95 rows, postflight 67 | launch against a live, unaudited v2 stack | the pins and bounds stay; the echo, router, lens and nonce rows go | none | nothing |
| director ledger: 71 records, invalidation by scope, 1,782 LOC | evidence pinned to the commit it examined | one freeze table in HANDOFF: candidate commit, suite, deep, rehearsal, review, each a commit and a file | a process choice, section 6, B | the director re-reads instead of re-running a checker |
| docs: 3.46 MB, logs and an archived sim in the tree, ARCHITECTURE 127 KB | the current reading of intent and the evidence | ARCHITECTURE rewritten to this design, logs referenced by commit, archive/sim deleted | none | nothing |

## 4. pruning or rebuild

| | prune to the design | rebuild from scratch |
|---|---|---|
| the bid | kept as built with its measured numbers (decision 103) | re-derived, re-measured, re-reviewed |
| the v2 fee path | the fork fixtures and the live stack pins stay | rewritten from the v2 interfaces |
| evidence | 990 tests and 21 invariants stay as the regression net while each removal lands | discarded |
| the result | the same contracts as the rebuild (section 2), reached in packets | the same contracts |
| risk | each packet is reviewed against a green suite | one big review at the end |

recommendation: prune to the design. the end state is the clean sheet; the path keeps the evidence.

## 5. what disappears

measured, by name:

- contracts: FeeRouter (202 LOC), CoreLens (272 LOC), their interfaces (112 LOC).
- states: the eth measuring flag, `splitOn`, `splitStart`, `owed` per payee, the lens pointers, the pause window array, the stored `unitPerPoint`, `balanceMode`, the controller `floorBps`, `feeToBuybackBps`, `CoreState`, `SettingsStore`, `RateStore`.
- workflows: the Resume run, `setSplitStart` by hand, `flush()` at split start, `CONTROLLER_NONCE`, the "no transaction between steps" rule, escrow claim then `skim` (one `collectEscrow`), `skim` itself, `router.lock` (OD-2 half), `refreshUnitPerPoint`.
- failure paths: a flush reverting inside a measured call (V2R-1), a payee that burns gas blocking a flush, a router with no engine stranding eth, `Measuring`, `BadCost`, a claim inside a measurement, a lens short answer, the `Underpaid` race after a unit change (section 14 item 31), a controller swap resetting the pause clock.
- tests that exist only for the removed mechanics: FeeRouter.t 537, PullFees.t 391, FeeShare.t 301, Resume.t 513, Lens.t 286, PostflightSlots.t 252, most of ReviewV2Port.t 582 and V2PortMigration.t 170 (3,032 LOC whole files, measured) plus the measuring and flush cases inside Fees.t, CoreUnit.t, Seaport.t and GasCap.t (projected 2,000 LOC). invariants 15 (router) and 20 (lens) go; 10 (`receive` never reverts) becomes "book never reverts".
- docs: 5 SUITE logs (665 KB), 6 DEEP-RUN logs (187 KB) and RERUN leave the tree (the freeze record cites the commit and the run); docs/archive/sim (1.08 MB) is deleted; the 21 REVIEW, 6 REHEARSAL and 2 ACCEPTANCE files move to docs/archive; ARCHITECTURE, DEPLOY, INTEGRATION and README are rewritten to the design; FLOW stays as the log.

projected: Engine runtime near today's Core (measuring and lens views out, `_book`, the pause clock and the adapter call in); the Controller smaller (pause, `floorBps`, the value floor and the baseline out); EngineLib smaller (`pullFees`, the stored unit out). every contract stays under 24,576 bytes.

## 6. owner decisions this design needed, both taken 2026-10-13

**A. the pool side seal (decision 109: the Engine as recipient, seal later).** today `coin.lockRecipients()` at launch seals the hook's bounty recipient to the router, and `router.setEngine` stays open for a later engine. in the design the Engine is the recipient and the coin admin's `setBountyRecipient` is the migration switch, so `lockRecipients` waits until no migration is wanted, like `lockSuccessor` today. a holder loses the launch time seal on the pool side while migration stays open; the owner key's reach is the same either way (one switch instead of two). alternative: keep a 60 line forwarder (empty receive, `setEngine`, `lock`) and seal the pool at launch. recommendation: the Engine as recipient, `lockRecipients` with `lockSuccessor`.

**B. the director ledger (decision 110: the table).** keep `project/evidence.json`, the scope invalidation checker and 1,782 LOC of python, or replace them with one freeze table in HANDOFF (candidate commit, full suite run, deep run, rehearsal, security review, each a commit and a file). recommendation: the table. the checker says "structural only" by its own words and 0 of 71 records are valid at the tip.

## 7. ordered plan

each packet: one builder on sonnet, bounded to the files named, `forge build` and `--match-path` on the tests it touches, one independent review of the commit, nothing else. the full suite, the deep runs and the rehearsal run once, at the freeze.

| # | packet | removes | depends on |
|---|---|---|---|
| 1 | rename exit to balance (NEXT 38) | the old vocabulary | none |
| 2 | pause clock into the Engine, O(1) | the window array, the controller pause | 1 |
| 3 | listing adapters, measuring out (NEXT 37) | the measuring flag, `BadCost`, raw calldata, `Measuring` in receive | 1 |
| 4 | the Engine as bounty recipient: `receive` open to the hook only, `_book`, payee ppm claim, sniper latch from the factory record, `COIN` from `predictToken` in the constructor, `fund`, `collectEscrow`, `skim` and FeeRouter deleted | FeeRouter, flush, pullFees, skim, Resume, split start, V2R-1 | 3 |
| 5 | `pointValue`, unit live, one floor, `feeToBuybackBps` out, two balance switches (NEXT 39 to 42), the royalty on the controller and the composer on the record (NEXT 44), settings recount and bounds | the value floor, baseline, backstop, stored unit, refresh, `floorBps`, `balanceMode` | 1 |
| 6 | one `State` struct; CoreLens deleted; the bid quote view after pending income | CoreState, fixed slots, the lens, 8 postflight rows | 4, 5 |
| 7 | CREATE2 deploy, `setController` before launch, preflight and postflight trimmed, env vars trimmed, Lock run becomes a later owner command | nonce pinning, Resume, config echo rows | 6 |
| 8 | tests follow: delete the files of section 5, rewrite fixtures to the five transaction deploy, invariants 15 and 20 out, 10 restated, gas rows re-measured | about 5,000 LOC | 7 |
| 9 | sim follows: the fee fraction without a router, `pointValue`, the pause clock; the page kept | nothing | 5 |
| 10 | docs follow: ARCHITECTURE, DEPLOY, INTEGRATION, README, HANDOFF rewritten; logs out; archive/sim deleted; reviews archived; the UI branch's one lens read replaced by a multicall | about 2.5 MB | 8 |
| 11 | decision B: the ledger replaced by the freeze table, director.py reduced to `handoff` and `status` or deleted | 1,782 LOC | owner |
| 12 | freeze: full suite, the deep runs, the rehearsal on the latest block, a security review of the candidate, the acceptance of decisions 99 to 108 | | all |

## 8. risks of the design, and what bounds them

- `_book` on every door costs one balance read and a few writes per call instead of a 62,400 gas flush (measured today). projected cheaper.
- the Seaport adapter understands one order shape. bundles, offers and other shapes stay with `sellForEth`. measured: 74,832 of 118,316 historical sales were single listing fills.
- a plain send to the Engine reverts and names `fund()`. a donor who guesses loses nothing.
- `predictToken` is stale if factory state changes before launch. same exposure as today, caught by the same postflight row.
- the pause mark adds one word per Statement record; the record has room (168 of 256 bits used, measured).
- the bid stays as built, so the leak and recovery figures of decisions 69 and 77 stand without a re-measure.
