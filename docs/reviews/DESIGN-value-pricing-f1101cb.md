# Design validation: value referenced pricing, against main f1101cb

Reviewed commit: `f1101cb` (main, the merge of PR 44, points unit; decisions 145 and 146 in). Date 2026-10-16. Branch `claude/dreamy-rubin-9w9yyv`. This replaces an earlier draft written against `e5cb263`; every recommendation below is re-derived from the current source and the current launch config, none is carried over. Scope: the owner's proposed design (one value per point from the BALANCE entitlement and a protected ETH price of BALANCE, one shared rising acquisition percentage for both currencies, value priced sales with a sale spread and a four hour 1.5 times premium, age gated conversion, 25 percent of every sale to the buyback, a combined acquisition budget, an operating reserve). Design validation and plan only: no production contract, script, config or deployment changed.

Evidence: the contracts read at `f1101cb`; `node sim/value.mjs docs/reviews/DESIGN-value-pricing-f1101cb.json` (132 runs on the shipped bid instances of `sim/engine.js` at the launch config: rate per 100 points, `dropPer100PointsBps` 115, `dropFloorBps` 1, `spendCapBps` 10,000) and `node sim/value.test.mjs` (97 checks). Forge is not installed in the review container, so nothing in Solidity ran; Solidity claims are read from source. The study is a bounded synthetic model.

## 0. Current behavior at f1101cb

| area | as built | source |
|---|---|---|
| unit | points. the eth rate is wei per 100 points (`RATE_SCORE` 1,000,000 score units); `ethPerPoint()`, `bidForScore(score)`, `bidOf(id)`; the balance side mirrors it with `balanceBidForScore`. opening 5.77e15 wei per 100 points (0.025 eth for a 433 point credit), `rateCap` 3x | decision 145, Core `_rateNow`, Interfaces `RATE_SCORE` |
| eth bid | a wei price state: climbs 200 bps a minute toward `min(ceiling, rateCap, pot)`; the ceiling is 110 percent of `max(last fill, decayed peak)` loosened `600 bps * m` per 10 idle minutes, `m` the pages of `pointsPerPage` (35,200) the pot buys at the last fill rate, capped 4x; a fill drops the rate `115 * score / 1,000,000` bps, no minute floor (`dropFloorBps` 1); the spend cap is off (`spendCapBps` 10,000, an incident tool) | decisions 128, 141, 145, 146; CoreLib `_climb`, `_drop`, `spend` |
| balance bid | the same state machine as a second instance in bps of par, floor and opening `10,000 - balanceBidMarginBps` (9,000), cap `balanceBidCapBps` (10,000, raisable to uint32.max), clamped to the module's `available()`; off at launch, redemptions accumulate | decisions 117, 122, 130; CoreLib `_sellForBalance`, `_balanceRead` |
| value per point | `valueOf(points) = max(floorRate * points / RATE_SCORE, points * unitPerPoint at the pool spot)`; the floor rate is the larger of the climbed price state and the decayed peak; the pool term reads `getSlot0` through the owner's pool key | ControllerV1 `valueOf`, `_poolValue` |
| credit sale | from `floor * 3` down to `floor = max(cost, valueOf(score)) * 1.1` over 14,400 s; the Core takes no payment below `cost`; `creditCostToPotBps` 8,000 of the cost to the pot, the rest after the cuts to the buyback | ControllerV1 `creditPrice`, Core `sellCreditTo` |
| statement sale | reference `max(cost, valueOf(rating))`; ask from 1.5 times the anchor down to `saleFloorBps` (10,000) of the reference over 12 hours; the Core takes no payment below `cost * saleFloorBps / 10,000`; 2.5 and 0.5 percent cuts off the top, 25 percent of the rest to the buyback | ControllerV1 `_ask`, `buy`; Core `sellTo` |
| conversion | a module, `redeemOn`, and the controller's `atFloor(sid)`, which reads the reference (a pool read) and compares the curve price with the floor; in effect true once the age reaches `decayHours`. the module must return `rating * unit * 0.98`; proceeds stay in the module | Core `redeemStatement`, ControllerV1 `atFloor` |
| module | `StatementBalanceModule`: `unitPerPoint` 1e14 base units per score unit, one BALANCE per point, 18 decimals; `available()` 0 until upstream retirement and `transfersOpenBlock`; built, reviewed, not deployed | decision 144 |
| round trip guards | `SameBlockReturn` on every intake door; within a block the credit floor is at least 1.1 times `floorRate`, which is at least the bid | Core, SPEC 6 and 8 |
| reserve, budget | no reserve; acquisitions can take the pot to zero; the spend cap is off | Core `_payCaller`, decision 146 |

## 1. Verdict

The design is sound in shape and most of it exists. The shared percentage bid is the shipped balance bid instance. The points unit of decision 145 is exactly the proposal's unit: one point is one BALANCE, `ethPerPoint` is the bid per point today, and the proposal only changes where the per point price comes from (the engine's own climb and drop history today, the BALANCE conversion value when the switch is on). The windows, the statement curve and the module are built. Five assumptions in the proposal fail against the current code and get a simpler rule each. One finding about the shipped bid stands apart from the proposal (F0). One dependency, the BALANCE price source, is resolved by decision 148 (the controller records its own reference) and now waits only on the pool's existence and depth.

| # | assumption | finding against f1101cb | replacement |
|---|---|---|---|
| F0 | "retain the existing controlled ETH acquisition mechanism" for the temporary phase | the shipped eth bid is a ratchet. the ceiling anchors on the last fill at 110 percent and loosens 24 percent per 10 idle minutes at a 10 eth pot; the state climbs 200 bps a minute toward it; every fill raises the next ceiling. with the spend cap now off nothing but the pot bounds a seller who waits: selling five 433 point credits whenever the bid is within 2 percent of the ceiling it can reach, then waiting, takes 7.68 of 10 eth in six hours at a 0.005 eth market (7.08 over market, 120 credits) and the whole pot in a day; at a market equal to the opening it still overpays 4.68 eth in six hours. decision 146's dump study (0.86 eth) modelled a seller who sells whenever the bid covers the ask, which keeps the bid under the market, not one who waits for the recovery. the same mechanics open a self funded loop through the credit sale: a pile credit bought at `1.1 * floorRate` is worth more at the bid once it climbs past that floor (28 percent after 20 idle minutes) | the launch values stay by the owner's instruction (decision 149); the exposure is recorded as known. measured alternatives, settings only: climb 50 cuts the six hour take to 1.00 eth at `rateCap` 3x and 0.93 at 1.2x; climb 20 to 0.00 and 0.40; `rateCap` 1.2x alone to 3.72. a one day return lock on every intake door (next candidate) closes the self funded loop in both phases. the value design removes the ratchet: its cap is a percentage of an external value, not of the last fill |
| F1 | protected floor = `max(reference, current bid × (1 + spread))` | the bid rises after a sale and the premium decays: an attacker dumps credits to the floor (paid 90 percent), buys aged engine inventory at the reference (the bid term does not bind), waits for the climb, sells back at the cap. gain per cycle is the cap less par: 0 at cap 100, 5 percent at 105, 10 at 110; at the shipped climb a cycle is 10 minutes. small (about 0.07 percent of the capital an hour with 433 point credits at cap 105) but structural, and the cross currency form (buy for eth at the reference, sell back for BALANCE at the cap) pays the same | floor = `points × V_sell × max(1, (1 + spread) × cap)`, the spread on the ceiling of the bid, not its current value. closes both loops by at least the spread at every bid and quote state (section 3). the proposal's own 110.25 percent example already assumed the bid at the cap |
| F2 | initial ceiling 105 percent | with the shipped 200 bps climb the bid is at the cap 88 to 93 percent of the time at 3 sellers an hour and pays 104.9 percent on average, so every converted credit loses 4.9 percent; 9.8 at cap 110. at 20 bps a minute the loss is 2.1 percent at 3 sellers an hour and under 0.1 at 12 an hour. the premium is bought by idle time, not by demand | cap 100 at activation (the study pays at most par there, exactly), climb and recovery climb 20 bps a minute, drop 115 per 100 points unchanged. 105 later by `setSettings` once flow is observed. the two instances share the climb settings, so the retune belongs to the switch, when the eth instance is retired |
| F3 | stop ETH routes at 5 percent spot deviation, resume under 3 | a halt and resume state with a stale quote inside the band and a toggling edge. directional bounds do the same work with no state: pay off `min(spot, ref × 1.05)`, receive off `max(spot, ref × 0.95)`. a flash move only lowers the bid or raises the ask; a held move needs the reference's own rate limit; the bid stays under the ask in every state. halt only when the reference is unusable | `tolBps` 500; halt on an unusable reference (stale beyond `maxStale`, pool liquidity under `minLiquidity`); BALANCE routes, conversion, compose, buyback and booking stay live |
| F4 | a 30 minute time weighted price of the BALANCE pool | the controller reads `getSlot0`; v4 keeps no history without an oracle hook; the pool is Jack's, not ours to change, not yet created. resolved by decision 148: the controller keeps a reference next to the pool key, moved toward spot by at most `min(rate × elapsed, step)` on its own sale doors and a public `observe()`; the Core's bid doors read it through `valuePerPoint`. a permissionless record with a rate limit, not a TWAP: a hold longer than the limit moves the reference the full way | build 148. the rate, the step, the tolerance, `maxStale` and `minLiquidity` are tuned once the pool's depth is known. window thinking changes: the rate limit is the window |
| F5 | one combined budget, 1 percent of usable capital a minute, 5 percent accumulation | decision 146 turned the budget off at launch and relies on the compounding drop; the proposal would bring a budget back, in a unit that needs the quote. against the current rules it is not needed: with cap 100 and `min(spot, ref × 1.05)` the overpay on a pumped reference is at most 5 percent on the first credits, after which the drop (115 bps per 100 points, no floor) takes the bid under true value; a 300 credit dump clears at 90.1 to 91.0 percent of value with or without a budget; the study's two budget rules differ only in absorption time (141 against 105 minutes). the BALANCE route needs no quote and is bounded by `available()` | no new budget. `spendCapBps` stays the incident tool for the eth route; the BALANCE route is bounded by the module. the shared bid state is what stops a currency switch from resetting the offer |
| F6 | 25 percent of net on every sale preserves burns without profit only distributions | true, and the cost must be shown: the pot shrinks on any sale below 1.375 times the bid paid; at the 1.1025 floor it pays 74 percent of the burn from principal (0.198 of the bid per sale). fee income is the only refill; sustainable floor turnover is about five times fee income. the credit split stays as built by decision 149 (`creditCostToPotBps` 8,000, the rest to the buyback), which at the floor drains the pot the same 0.20 and on premium sales burns more than the 25 percent rule would | report the subsidy in the web and the indexer; no change |
| F7 | fixed 0.10 eth operating reserve | at the 3 gwei payment ceiling a page costs 0.0276 eth to compose and redeem, so 0.10 eth processes 3.6 pages; ten queued pages need 0.28 eth, 0.41 at 1.5 times. with the spend cap off, acquisitions can empty the pot in one burst, so a reserve matters more than before | `reserve = max(reserveWei, 15 × queued / 10)`, `queued = (pileSize / 80) × (9,000,000 × callerMaxBaseFee + callerFee) + heldIds.length × (600,000 × callerMaxBaseFee + callerFee)`; both counts are Core storage. bids read `ethPot - reserve`; `_payCaller`, buyback and the pushes keep paying from the whole pot |

Holds, checked against the source: one BALANCE per point (unit 1e14, scores in ten thousandths of a point, `quote(sid) = rating × 1e14` on the real bytecode); the shared percentage bid is the balance `Rate` instance with floor and opening 9,000, cap raisable above par, one `_drop` per credit scaled by `score / RATE_SCORE`, `buyListing` included; four hour credit window and compose waiting for it; `decayHours` a setting; `atFloor` already age only in effect (the fix removes the 400,000 gas reference read and its fail closed path); redemption without cost recovery; accumulate mode by `balanceBidOn` false; the keeper's doors, delay, relay and profit rule as decisions 136 to 139.

## 2. Parameters

| parameter | proposal | recommendation | evidence | setting |
|---|---|---|---|---|
| bid floor and opening | 90 | 90 | a 300 credit dump at the floor pays 90.1 to 91.0 percent at every cap; a 10 percent conversion gain covers a page's processing (0.0276 eth on about 2 eth of value) | `balanceBidMarginBps` 1,000 |
| bid cap | 105 (100, 105, 110 compared) | 100 at activation, 105 by setting later | conversion loss at 3 sellers an hour, reservation at par: cap 100 0.0 at every climb; cap 105 4.9 (climb 200), 2.1 (20); cap 110 9.8, 3.0. at 12 sellers an hour under climb 20 every cap is under 0.1 | `balanceBidCapBps` 10,000, then 10,500 |
| climb and recovery climb in value mode | recheck | 20 bps a minute each | the band is 10 to 15 points wide; at 200 the floor to cap climb is 10 minutes and the bid is pinned at the cap 88 to 93 percent of the time at low flow; at 20 it is 53 minutes to cap 100 and 77 to cap 105, time at cap 37 and 11 percent at 3 sellers an hour | `climbPerMinBps`, `recoveryClimbPerMinBps` 20 |
| drop | recheck | 115 per 100 points, unchanged | about 5 percent per 433 point credit; three such credits span the band; a dump reaches the floor within a block and stays there | `dropPer100PointsBps` 115 |
| sale spread | 5 (2, 5, 10 compared) | 5 on the ceiling | with F1 the spread is the guaranteed loss of any round trip: 2, 5 or 10. 5 covers the 3 percent cuts with margin; 2 does not (a cycle costs the attacker 2 and the engine's cuts 3.3); 10 puts the credit floor at 110 (cap 100) and sells less | controller `floorBps` renamed `spreadBps` 500; the cap multiplier read from `balanceBidCapBps` |
| credit premium | 1.5 times the floor over 4 hours | as proposed | existing semantics `start = floor × startBps / 10,000` over `window` | controller `startBps` 15,000, `window` 14,400 |
| statement premium and window | 1.5 times over 4 hours, anchor off | as proposed, same protected floor multiplier as credits | `markupBps` 15,000 at an anchor of 10,000 is 1.5 times the reference; `anchorMoveBps` 0 disables the anchor; `decayHours` 12 to 4. there is no return route from a statement into the bid, so the spread on statements only prices the ask; one multiplier keeps one rule | controller `decayHours` 4, `anchorMoveBps` 0 |
| reference | 30 minute TWAP | decision 148's rate limited reference, tolerance 5 percent | the rate limit is the holding cost on an attacker; its value and the step wait on the pool's depth | controller `rateBpsPerHour`, `maxStepBps`, `tolBps` 500, `maxStale`, `minLiquidity` |
| budget | 1 percent a minute combined | none new | F5; the drop bounds volume, the directional bound bounds the overpay | `spendCapBps` as the incident tool |
| reserve | 0.10 eth fixed | 0.10 eth floor plus 1.5 times the queued processing cost | F7 | `reserveWei` 1e17 |
| buyback share | 25 percent of net on both | statements as built (25 percent of the rest); credits as built (decision 149) | F6 | unchanged |
| cuts | 2.5 and 0.5 | as built | `saleToArtistBps` 250, `saleToOperatorBps` 50 | unchanged |
| temporary phase eth bid | keep | kept by decision 149 | F0 table below | unchanged |

Study tables (full set in the JSON):

| cap | climb bps/min | sellers/h | fills/h | mean paid % | premium loss % of par bought | time at cap |
|---|---|---|---|---|---|---|
| 100 | 200 | 3 | 1.4 | 99.9 | 0.00 | 0.93 |
| 100 | 20 | 3 | 1.4 | 98.0 | 0.00 | 0.37 |
| 105 | 200 | 3 | 2.0 | 104.9 | 4.90 | 0.90 |
| 105 | 200 | 12 | 8.5 | 103.8 | 3.91 | 0.62 |
| 105 | 20 | 3 | 1.9 | 101.1 | 2.07 | 0.11 |
| 105 | 20 | 12 | 3.3 | 94.0 | 0.00 | 0.00 |
| 110 | 200 | 3 | 2.3 | 109.8 | 9.80 | 0.88 |
| 110 | 20 | 3 | 2.0 | 102.1 | 2.95 | 0.04 |

| patient seller, launch config, 10 eth pot, 0.005 eth market: eth over market in 6 h, in 24 h | climb 200 | climb 50 | climb 20 |
|---|---|---|---|
| rateCap 3x (launch) | 7.08, 9.18 | 0.92, 7.38 | 0.00, 2.46 |
| rateCap 1.5x | 3.78, 8.48 | 0.85, 3.82 | 0.28, 1.41 |
| rateCap 1.2x | 3.02, 8.11 | 0.76, 3.03 | 0.32, 1.19 |
| market 0.025 eth, rateCap 1.2x | 0.22, 0.61 | 0.06, 0.23 | 0.02, 0.09 |

| sale at (times value) | bid paid 0.90, pot change | bid 1.00 | bid 1.05 | burn from principal at bid 1.00 |
|---|---|---|---|---|
| 1.00 | -0.172 | -0.272 | -0.323 | 0.242 |
| 1.1025 | -0.098 | -0.198 | -0.248 | 0.198 |
| 1.50 | +0.191 | +0.091 | +0.041 | 0 |

| reference held k off for | buy loss, % of eth spent | sale loss, % of inventory sold |
|---|---|---|
| 5 percent | at most 4.8, falling to 0 after about three credits as the drop takes the bid under value | 5 |
| 10 percent | 0 with tolerance 5 (the bound clips it) | 5 (clipped) |

## 3. Formulas

Units: `score` in ten thousandths of a point (800,000 to 8,000,000); `RATE_SCORE` 1,000,000 (100 points); `unit` 1e14 base units per score unit; `P` wei per BALANCE base unit scaled by 1e18, from `sqrtPriceX96` with native eth as currency0 (the controller's `_priceBaseUnits`); `bps` the shared bid in bps of par; `cap`, `floorBps`, `s` the settings.

```text
reference  = the controller's stored reference, moved toward spot on each update by at most min(rateBpsPerHour * elapsed / 3600, maxStepBps)
P_buy      = min(spot, reference * (10,000 + tolBps) / 10,000)
P_sell     = max(spot, reference * (10,000 - tolBps) / 10,000)
V_buy      = unit * P_buy / 1e18        wei per score unit, rounded down
V_sell     = unit * P_sell / 1e18       rounded up
usable     = newest update within maxStale, pool liquidity >= minLiquidity, unit read ok
```

Purchase, both currencies, one bid state:

```text
bps_now     = the shared instance climbed to now, at least floorBps, at most cap, not clamped to funds
ethRate()   = bps_now * V_buy * RATE_SCORE / 10,000        wei per 100 points; NoQuote when not usable
bidForScore = ethRate() * score / RATE_SCORE               the per credit eth bid, as today
balance bid = score * unit * bps_now / 10,000              no quote needed, as today
each fill   : bps_now = _drop(bps_now, score) on the balance anchor, at least floorBps
eth route   : revert PotTooSmall above ethPot - reserve; buyListing pays value <= bid and min(refund + keeperFee, bid - value, ethPot - reserve - value)
balance     : revert PotTooSmall above available(), as today
cost record : eth paid, or balance paid * P_buy / 1e18 (accounting only)
SameBlockReturn and, once built, the return lock on every intake door
```

Sale, credits and statements, one rule:

```text
floorMult = max(10,000, (10,000 + s) * cap / 10,000)        10,500 at cap 100 and s 500; 11,025 at cap 105
protected = points * V_sell * floorMult / 10,000
ask(age)  = protected * (start - (start - 10,000) * min(age, window) / window) / 10,000
            credits: start = creditStartBps (15,000), window = creditWindow (14,400), age since acquisition
            statements: start = markupBps * anchorBps / 10,000 (15,000), window = decayHours hours, age = statementAge
Core floor: msg.value >= cost * saleFloorBps / 10,000 on both doors; the value switch lowers saleFloorBps to a sanity level
split     : as built (statements 25 percent of the rest to the buyback; credits creditCostToPotBps of the cost to the pot)
```

Why the floor closes the loops: the most the engine pays for a credit on the eth route is `cap × score × unit × P_buy / 1e22 <= cap × score × unit × spot / 1e22`; on the BALANCE route `cap × score × unit / 10,000` BALANCE, worth at most that many wei at spot. The lowest ask is `(10,000 + s) × cap × score × unit × spot / 1e26` or more. A buy from the engine and a sale back into either bid loses at least `s` of the bid before the drop and gas, at every bid state, because the floor uses the cap and not the bid of the moment. The engine's own loss on a converted credit is `bps_paid - 10,000`, at most `cap - 10,000`, zero at cap 100.

Reserve: `reserve = max(reserveWei, 15 × queued / 10)` with `queued` from `pileSize` and `heldIds.length` as in F7. Conversion: `atFloor(sid)` becomes `startBps() <= 10,000 || statementAge(sid) >= decayHours × 1 hours`, no reference read; eligibility never restarts on a price move and never blocks on a quote.

Where ETH comes from once conversions dominate: the pool skim (9 percent of CC volume), the pot share and the 25 percent buyback share of ETH sales. Conversion produces BALANCE, which only buys credits through the BALANCE bid; it funds neither keeper payments nor buybacks. A regime with no ETH sales burns CC only through `redeemBurnBps` releases of the fee funded reserve.

## 4. Implementation plan

The engine is not deployed, so ABI changes are free; every contract change re-opens the freeze (STATUS section 4) and runs `script/tools/gen-interfaces.sh` with the build identity re-pins. Core has 91 bytes of headroom: additions go to CoreLib or the controller.

Packet A, settings only, any time: `decayHours` 4, `anchorMoveBps` 0, `creditStartBps` 15,000. Files: `script/config/mainnet.json`, `anvil.json`, `rehearsal.json`, `Mainnet.defaultSettings()`, SPEC 3 and 8.

Packet B, next candidate, independent of BALANCE:

| file | change |
|---|---|
| `src/Core.sol` | the return lock: `creditSaleBlock[id]` stores the sale timestamp; the four intake checks compare `block.timestamp < saleAt + returnLockSeconds` (`SameBlockReturn` becomes `ReturnLocked(id, until)`, a lock of 0 keeps the block rule). `sellCreditTo` floor `cost * saleFloorBps / 10,000` (was `cost`) so one knob lowers both doors at the switch. `ethRate()` returns CoreLib's read so the reserve clamp lives in the library |
| `src/lib/CoreLib.sol` | `reserve(c)`; `spend` and `climb` use `ethPot - reserve(c)` |
| `src/ControllerV1.sol` | `atFloor` age only; `floorBps` renamed `spreadBps`, bound 0 to uint16.max, floor `max(cost, valueOf(score)) × max(10,000, (10,000 + spreadBps) × balanceBidCapBps / 10,000) / 10,000` (10,500 at launch values, was 11,000) |
| interfaces, bounds, `script/SettingsFields.sol`, `script/LaunchConfig.sol` | `Settings` gains `uint64 reserveWei` and `uint32 returnLockSeconds` in slot 4; `CreditSale.floorBps` becomes `spreadBps` |
| tests | CreditSale (the lock across blocks, a buy at the floor and a sale back after 20 idle minutes is a loss, the spread at the cap), SameBlockReturn (every door, 0 is the block rule), Redeem (age only, no pool read, true under a halted quote), SpendCap and invariants 1, 7, 16, 19 on `ethPot - reserve`, CoreLayout and Config for the new fields |
| sim, keeper, web, indexer | `engine.js` the lock, the reserve, the spread at the cap, age only redemption; keeper redeem gate by age and a reserve alert; web credit floor input and the pot net of the reserve; INDEXER.md rows for the renamed error |

Packet C, the value switch and the reference (decision 148):

| file | change |
|---|---|
| `src/interfaces/Interfaces.sol` | `IController.valuePerPoint(bool forSale) returns (uint256 v, bool ok)`; `Settings.valueModeOn` |
| `src/ControllerV1.sol` | the reference storage and update (`_observe()` in `buy`, `buyCredit`, `buyCredits`, and public `observe()`), `P_buy`, `P_sell`, the usable conditions, a `Quote` struct setter (`rateBpsPerHour`, `maxStepBps`, `tolBps`, `maxStale`, `minLiquidity`); `valueOf(points, forSale)` with the `floorRate` and cost terms dropped when the switch is on; `creditPrice`, `_reference`, `priceOf` on `V_sell` |
| `src/lib/CoreLib.sol` | with the switch on, `climb` returns `bps_now × unit × P_buy × RATE_SCORE / 1e22` from the balance instance and the controller's bounded `valuePerPoint(false)` (200,000 gas, fail closed to `NoQuote`), bounded by `rateCap`; `spend` checkpoints and drops the balance instance; the instance climbs whenever the switch is on or (`balanceBidOn` and a usable module), with `clampTo = cap`; turning the switch on resets the instance to the floor; the eth instance is left unused |
| `src/Core.sol` | none beyond packet B |
| tests | round trips in both currencies at every quote state; the shared instance drops on an eth fill and a balance fill; a currency switch cannot reset it; a hostile controller quoting a huge or zero value cannot pay above `rateCap`, cannot move the BALANCE bid, cannot block conversion; the reference: spam gains nothing beyond the rate, a long idle gains one step, staleness halts the eth routes only; invariants 2 and 19 in value mode; gas of the eth doors with the extra read |
| keeper, web, indexer | `NoQuote` and halted states as skips; an `observe` tick under the daily budget; one bid display from the shared instance; reference against spot on the web |

The switch, one block: `setSettings` with `valueModeOn` true, `balanceBidOn` true, `balanceBidCapBps` 10,000, `balanceBidMarginBps` 1,000, `climbPerMinBps` and `recoveryClimbPerMinBps` 20, `saleFloorBps` 5,000 (the Core still refuses a sale under half of cost from a broken controller; conversion is never blocked by it); the controller's `Quote` struct and pool key set beforehand; `observe()` called for long enough that the reference is usable.

## 5. What ships when

Now, settings: packet A. Next candidate: packet B, which improves the engine on its own (the return lock, the reserve, the spread at the cap, age only eligibility). Then packet C, which waits on nothing but the pool: it must exist with usable depth before `rateBpsPerHour`, `maxStepBps`, `tolBps` and `minLiquidity` can be set, and the BALANCE bid stays in accumulate mode until the switch because the two instances share the climb settings.

## 6. Tests before deployment

Solidity, each with a `// promise:` line, `--match-path` during work and the whole suite on the frozen candidate: the round trips of section 3 in both currencies at the floor, the cap, after a climb, in the next block, after 20 idle minutes, across a currency switch, at spot above and below the reference, with the reference stale; the shared instance and its single reset; the reserve (acquisitions revert at `ethPot - reserve`, processing still pays, the formula follows the queue, `ethRate()` never above what the pot can pay); eligibility by age under every quote state and a pause; the sale floors on both doors at the new `saleFloorBps`; the hostile controller bounds; the quote states and the halt leaving BALANCE routes, conversion, compose, buyback and book live; the reference's rate limit, step cap, staleness and ring state; gas budgets of INTEGRATION 12; invariants 1, 2, 3, 7, 16, 19 restated and run in the Deep variants. Simulator: `engine.test.mjs` on the new rules and `value.mjs` rerun on the engine model once built. Keeper: boundaries of the age gate, the reserve alert, the halted quote skips, the observe tick.

## 7. TLDR

Against current main the proposal is mostly configuration of what is built, and the points unit of decision 145 is already the proposal's unit; the switch changes the source of the per point price, not its shape. Five pieces fail and have simpler fixes: price the sale floor off the bid's cap, open at cap 100 with a 20 bps climb, use directional bounds on the recorded reference instead of a halt and resume guard, add no budget (the drop and the bound do the work, the cap stays an incident tool), and size the reserve from the queue. The reference is the controller's own rate limited record (decision 148), so nothing waits on Jack. The shipped eth bid is a ratchet a patient seller drains in a day; the owner keeps those settings for now (decision 149) and a one day return lock should go in the next candidate. Statements' 25 percent and the credit split stay as built, and floor sales pay most of each burn from pot principal, which the web should show.
