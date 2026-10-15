# review: intent, legibility, practice at ac8da10

scope: `git diff d9d2077 ac8da10 -- src script test docs web/lib web/app web/components` on `points/v1`. intent sources: docs/DECISIONS.md decisions 116 to 123 and section 11, docs/SPEC.md. method: code reading with file:line references. no forge run: every finding below follows from the source as quoted; the suggested regression tests are listed in lens 3 so each one is proved on the fork before the fix lands.

severity: **must** = fix before freeze. **should** = fix before freeze unless the owner accepts it in DECISIONS. **nit** = cleanup.

---

## lens 1. logic versus intent

### decision by decision

| # | owner intent (one line) | code | verdict |
|---|---|---|---|
| 116 | every eth door prices a credit at `ethRate() * score / refScore`; the fill drop scales the same way; `refScore` is a Core setting | `Core.sol:616-633` (sellForEth), `642-675` (buyListing), `CoreLib.sol:450-466` (adopt), `CoreLib.sol:370-372` (drop), `Core.sol:455-459` (bidOf), `ControllerV1.sol:211-218` (live read), `ControllerV1.sol:280-290` (credit floor without the flat term) | matches the formula. two gaps: L1-3 (buyListing payment above the pot) and L1-6 (the clamp is per refScore credit) |
| 117 | the module holds the balance token; redeem leaves proceeds there; the bid checks `available()` and pays through `pay` | `Core.sol:941-968`, `CoreLib.sol:630-651`, `Core.sol:1322-1336` | matches. `setBalanceModule` also requires `available()` to answer (an uncapped staticcall, `Core.sol:1330`), which the decision text does not state; SPEC 9 does |
| 118 | swap a pile credit for an owned credit of equal or higher score for a burned `swapFeeCc` | `Core.sol:1194-1225` | matches: checks, `score(inId) >= score(outId)`, `burnFrom`, node inheritance, pull in before send out, event fields. the fee burn runs before the node writes (decision silent on order) |
| 119 | launch values | `script/config/mainnet.json`, `Interfaces.sol:303-365` | every number matches (table below). L1-8 asks the owner to confirm the margin number |
| 120 | skim 10 points, 1.0 to artcoins, 9.0 to the engine, `payeePpm` 0 kept for later | `mainnet.json` launch block, `script/deploy.sh:37-39`, `script/Checks.sol:576-583` | matches. the decision text says the owner raises the share "with `setPayee`"; the share is `payeePpm` in `setSettings`, `setPayee` sets the address (doc nit) |
| 121 | one straight line from start to floor over `decayHours` (12), then rest | `ControllerV1.sol:456-466`, `ControllerV1.sol:138-149` | matches. the bps is integer, so the price moves in steps of `reference / 10_000` |
| 122 | balance bid as a second instance of the eth price state, cap par, floor `10_000 - margin`, clamp `available()` as bps of par | `CoreLib.sol:278-300` (`_climb` with `clampTo`, `capMax`), `354-373` (`_drop` with `absFloor`), `630-702` | climb and drop are shared. three gaps: L1-1 (the instance climbs while the bid is off and while `available()` grows unrecorded), L1-2 (batch clamp read once), L1-7 (the eth instance is outside `Rate`, so checkpoint and reset are two bodies) |
| 123 | artist and operator cuts off the top of every statement and credit sale, pushed with a 50,000 gas forced send; royalty and payee claim removed | `Core.sol:880-929`, `Core.sol:1055-1070`, `Core.sol:413-425` | matches. gaps: L1-4 (artist can be zero with a nonzero cut), L1-5 (settings script cannot set the cuts) |

### findings

| id | sev | file:line | issue | fix |
|---|---|---|---|---|
| L1-1 | must | `CoreLib.sol:644`, `CoreLib.sol:654-660`, `Core.sol:941-968`, `CoreLib.sol:204-224` | the balance instance is checkpointed only inside `sellForBalance`. `_climb` runs lazily from `bal.checkpointTime` (the constructor's reset) with the clamp read at the sale. while `balanceBidOn` is false (the launch state, decision 119) the price state climbs and idle loosening raises its ceiling: from the 1,000 bps opening, `ceilBps` 11,000 and `idleLoosenBps` 200 reach the 10,000 cap after about 68 hours idle. `redeemStatement` raises the module's holding with no balance checkpoint, so the decision 44 rule (an empty pot never raises the price) does not hold for this instance. turning the bid on pays the first seller up to par, while decision 122 names `10_000 - balanceBidMarginBps` the opening value. `test/BalanceBid.t.sol:56-65` shows the climb with no fill | reset the instance to its floor when `setSettings` turns `balanceBidOn` from false to true, and checkpoint it (clamp at the current `available()`) in `redeemStatement` before the module's holding rises. owner confirms the rule in DECISIONS |
| L1-2 | must | `CoreLib.sol:641`, `CoreLib.sol:689`, `CoreLib.sol:625-626` | the per-credit clamp `availBps` is computed once from the full `available()` and never lowered by `total`. the eth door re-reads the pot per credit (`Core.sol:624` through `_bid()`), so an eth batch pays the remaining pot while a balance batch reverts `PotTooSmall` as a whole. the comment at 625 states the eth behaviour ("clamped to the available left for the rest of the batch"), the code and the handler oracle (`HandlerBase.sol:2501-2512`) implement the other | compute `_toBps(avail - total, refScore * unit)` per credit, matching the comment and the eth instance |
| L1-3 | must | `Core.sol:653-671`, comment `Core.sol:667` | `bid = min(price, ethPot) * score / refScore` exceeds `ethPot` for a credit with score above `refScore`. `value <= ethPot` passes, then `paid <= bid - value` lets `value + paid` exceed the pot and `_spend` reverts `PotTooSmall`. the comment "`value` is at most the bid for this credit, which is at most `ethPot`" was true for the flat bid and is false per point | `.min(bid - value).min(s.ethPot - value)`; rewrite the comment |
| L1-4 | must | `Core.sol:282-342`, `script/SystemDeployer.sol:137`, `CoreLib.sol:204-224` | `setArtist` refuses zero while `saleToArtistBps` is nonzero, but the reverse path is open: the constructor stores `saleToArtistBps` 250 with `artist` zero until the deployer calls `setArtist`, and `setSettings` accepts a nonzero cut while `artist` is zero. a sale then calls `forceSafeTransferETH(address(0), toArtist, 50_000)`, which sends the cut to the zero address. untested (`test/Sale.t.sol:1016-1028` covers only the `setArtist` direction) | take `artist` as a constructor argument; refuse `saleToArtistBps != 0` in `setSettings` while `artist` is zero |
| L1-5 | must | `script/SettingsFields.sol:6-11`, `script/SetSettings.s.sol:234-300` | `SettingsFields.N` is 26; `Settings` has 28 fields. `saleToArtistBps` and `saleToOperatorBps` are missing, so `SetSettings` reverts `UnknownField` for them, its table hides them, and `_tuple` prints a 26-element tuple for a 28-field struct (a `cast send` built from it fails to encode). `test/Config.t.sol:637-650` sweeps bounds over the same 26 | add both fields (N = 28, lo 0, hi 1,000) and re-run the Config bound sweep |
| L1-6 | should (owner) | `Core.sol:624-625`, `Core.sol:514`, `Core.sol:455-459`, `CoreLib.sol:689-692` | the clamp lowers the rate of a refScore credit to the pot. a credit whose score is above `refScore` is then bid `pot * score / refScore`, above the pot, and `sellForEth` reverts `PotTooSmall`; `bidOf` reports that number. with a thin pot the engine buys only credits at or below `refScore * pot / price`. decision 42 ("never brick as long as there are credits listed") and decision 44 read as a bid lowered to the pot; SPEC row 1 narrows the guarantee to "a credit whose bid the pot covers". the balance bid has the same shape | per-credit clamp: pay `min(price * score / refScore, pot)` and return that from `bidOf`; the owner confirms either reading in DECISIONS |
| L1-7 | should (owner) | `CoreLib.sol:140-148`, `Core.sol:503-506`, `CoreLib.sol:654-660`, `Core.sol:1301-1309`, `CoreLib.sol:228-241` | decision 122 asks for "one reusable `Rate` struct and one set of functions ... run as two instances". the eth fields stay inline in `State`, so checkpoint and reset exist twice with different semantics: `setRate` keeps the minute anchor and the fill clock, the balance reset writes both. pre-launch, the layout can change | store the eth instance as a `Rate` too (one checkpoint, one reset parameterised by cap and floor), re-pin the slot tests |
| L1-8 | should (confirm) | `mainnet.json` `balanceBidMarginBps` 9000 | under decision 122 a 9,000 margin opens the balance bid at 10 percent of par. decision 119 records "9,000, was 2,000" with no owner quote for this number; commit b4fa487 calls it "margin 90 percent" | owner confirms 10 percent opening (9,000) against 90 percent (1,000) |
| L1-9 | should | `SettingsBounds.sol:34-35` | "the balance cycle (bid then redeem) cannot lose more than its margin" held for a flat bid at `10_000 - margin`. the rising bid reaches 10,000, so the coupling `redeemSlippageBps <= balanceBidMarginBps` no longer bounds anything | drop the coupling, or cap the balance bid at `10_000 - redeemSlippageBps`; owner picks |
| L1-10 | should | `SettingsBounds.sol:39` | `refScore` lower bound 1. scores are 800,000 to 8,000,000; a typo of 4,330 multiplies every eth bid by 1,000 and pins every drop at the 10,000 bound | bound to 800,000 to 8,000,000 |
| L1-11 | nit | `Core.sol:886`, `Core.sol:913`, SPEC row 3 | the hard floors (`cost * saleFloorBps`, `cost`) apply to the gross payment; at `saleFloorBps` 10,000 a statement at its floor nets the engine 97 percent of cost before the buyback split. consistent with "off the top"; SPEC row 3 can say "gross" | one word in SPEC row 3 and the `sellTo`/`sellCreditTo` comments |

### launch config, number by number (decisions 119, 120 and the SPEC 3 table)

`script/config/mainnet.json`, `anvil.json` and `rehearsal.json` are identical on every `settings`, `sale`, `credit` and `launch` field and on `artist`.

| field | json | decision | SPEC 3 | ok |
|---|---|---|---|---|
| saleOn | true | 119 true | true | yes |
| saleToBuybackBps | 2500 | 119 2,500 | 2,500 | yes |
| swapFeeCc | 1e22 | 119 10,000e18 | 10,000e18 | yes |
| keeperFee | 3e14 | 119 0.0003 ether | 0.0003 | yes |
| keeperMaxBaseFee | 5e9 | 119 5 gwei | 5 gwei | yes |
| redeemOn | true | 119 true | true | yes |
| balanceBidOn | false | 119 false | false | yes |
| balanceBidMarginBps | 9000 | 119 9,000 | 9,000 | yes (L1-8) |
| costToPotBps | 8000 | 119 8,000 | 8,000 | yes |
| redeemSlippageBps | 200 | 119 200 | 200 | yes |
| buybackSlice | 5e17 | 119 0.5 ether, min 0.0066 | 0.5 ether | yes (2 x (600,000 x 5 gwei + 0.0003) = 0.0066) |
| baselineSkimBps | 1000 | 120 1,000 | 10 points | yes |
| bountyBps | 9000 | 120 9,000 | 90 percent | yes |
| payeePpm | 0 | 120 0 | 0 | yes |
| sniperStartBps / sniperSeconds | 9000 / 1800 | 120 kept | 90 points over 30 min | yes |
| refScore | 4,330,000 | 116 | 4,330,000 | yes |
| decayHours | 12 | 121 | 12 | yes |
| saleToArtistBps / saleToOperatorBps | 250 / 50 | 123 | 250 / 50 | yes |
| artist | 0xc8f8...4c8a | 123 | | yes (lower case in json, same address) |
| payee | owner 0xCB43...17F9 | 120, 123 | | yes |
| rest of `settings`, `sale`, `credit` | unchanged | | match | yes |

verdict, lens 1: the formulas of decisions 116, 118, 120, 121 and 123 are implemented as written, and every launch number matches decisions 119 and 120 and the SPEC table. five defects block the freeze: the balance instance climbs to par while the bid is off and while redemptions fill the module, so the bid opens near par (L1-1); a balance batch reverts where the eth batch pays down to the pot, against its own comment (L1-2); `buyListing` can pay its keeper past the pot for a high score credit (L1-3); the artist can be the zero address with a nonzero cut (L1-4); the settings script cannot set the two cuts (L1-5). the per point clamp (L1-6), the unshared checkpoint and reset (L1-7), the margin number (L1-8) and the stale slippage coupling (L1-9) need an owner ruling recorded in DECISIONS.

---

## lens 2. legibility

### comments that state a false or stale fact

| sev | file:line | issue | rewrite |
|---|---|---|---|
| must | `Core.sol:40-42` | "splits ... into the payee claim, the coin buyback, the redeem burn pot and the pot": the payee is pushed and fee income never reaches the buyback | "every door starts with `_book()`, which pushes `payeePpm` of the eth above the tracked pots to the payee and splits the rest between the redeem burn pot and the pot." |
| must | `Core.sol:667` | see L1-3 | "`value + paid` is at most the bid for this credit and at most `ethPot`" (after the fix) |
| must | `Core.sol:877-879` | "`saleToBuybackBps` of the payment goes to the coin buyback" omits the cuts | "the artist and operator cuts come off the payment; `saleToBuybackBps` of the rest goes to the coin buyback and the remainder to the pot." |
| must | `Core.sol:902-905` | cost share and "the rest of the payment" omit the cuts; "no credit leaves the pot for less than it was bought for" holds for the gross payment only | "the payment is at least the credit's cost. the artist and operator cuts come off the payment; `creditCostToPotBps` of the cost, at most the rest, goes to the pot and the remainder to the coin buyback." |
| must | `ControllerV1.sol:36-38` | states the credit sale floor with the `core.floorRate()` term decision 116 removed | "a pile credit sells at `max(cost, valueOf(score)) * creditFloorBps / 10_000` at the end of its window, from `creditStartBps` of that at its acquisition." |
| must | `ControllerV1.sol:96-98` | "launch value false"; decision 119 sets it true | "launch value true" |
| must | `Interfaces.sol:174-175` | `balanceBidMarginBps` "the balance token bid pays `score * unitPerPoint * (10_000 - balanceBidMarginBps) / 10_000` per credit" | "the floor and opening value of the balance bid rate is `10_000 - balanceBidMarginBps`, bps of par" |
| must | `Interfaces.sol:353-354` | `defaultCredit`: "the whole credit cost funds the pot" | "80 percent of a sold credit's cost funds the pot" |
| must | `CoreLib.sol:625-626` | see L1-2 | follows the fix |
| must | `CoreLib.sol:627-628` | "the Core's eth `floorRate()`, which fills and time only raise": the peak decays with time and fills lower the price state | "the Core's eth `floorRate()`" |
| must | `CoreLib.sol:249-250` | "Never reverts: the Core calls it from `receive()`": `receive()` is a sender compare | delete the sentence |
| should | `CoreLib.sol:248-249`, `Core.sol:484`, `CoreLib.sol:260`, `Interfaces.sol` floorRate doc | "the clamp is `pot`, the price of one credit the pot affords", "wei per credit" | "wei for a credit of score `refScore`" |
| should | `SettingsBounds.sol:7` | "the Core reaches it through the linked `CoreLib.validate`": no such function | "through `CoreLib.setSettings`" |
| should | `SettingsBounds.sol:34` | see L1-9 | follows the owner's ruling |
| should | `Interfaces.sol:140`, `144`, `146-147` | `dropPerCreditBps` "fall of the eth rate per credit bought", `climbPerMinBps` "climb of the eth rate", `ceilBps` "the anchor is the rate of the last fill" | "fall of a bid rate per credit of score `refScore`, scaled by `score / refScore`; shared by the eth and balance bids"; "climb of a bid rate per minute; shared by both bids"; "the anchor is `max(last fill rate, peak now)`" |
| should | `Interfaces.sol:153` | `saleToBuybackBps` "share of sale proceeds" | "share of a statement sale payment after the artist and operator cuts" |
| should | `Interfaces.sol:197-198` | `payeePpm` "credited to the payee" | "pushed to the payee" |
| should | `Core.sol:193`, `Core.sol:1233-1234`, `CoreLib.sol:57-58` | "the rest of the payment to ethToBuyback" omits the cuts | "the rest after the cuts to `ethToBuyback`" |
| should | `Core.sol:112`, `Core.sol:126`, `Core.sol:1253-1255`, `CoreLib.sol:54-55`, `CoreLib.sol:496-497` | `Paused`, `Retired`, `setPaused`, `State.retired` and `migrate` door lists omit `swapCredit` (and `composeChosen` in `migrate`) | add the missing doors |
| should | `CoreLib.sol:760-761` | `READ_GAS` "the bounded module and controller reads": the library makes no controller read | "gas of the bounded `unitPerPoint` reads" |
| should | `docs/SPEC.md:15` row 2 | "bounded by `score * unit * margin`" | "bounded by `score * unit` (par) and the module's `available()`" |
| should | `docs/SPEC.md` section 3 `balanceBidMarginBps` | "a credit is paid at least `score * unit * (10,000 - this) / 10,000`": the `available()` clamp pays less | "the rate floor is `10,000 - this`; the clamp to `available()` can pay below it" |

### history, citations, negation, reviewer-response, metaphor

| sev | file:line | text | rewrite |
|---|---|---|---|
| should | `CoreLib.sol:276-277` | "the body is unchanged from the eth-only version with `clampTo` for the pot and `capMax` for the cap" | delete |
| should | `CoreLib.sol:351-353` | "the body is the eth-only version with an added lower bound ... while the eth rate is unchanged" | "`absFloor` is a lower bound on the result: 0 for the eth bid, `10_000 - balanceBidMarginBps` for the balance bid" |
| should | `Core.sol:422` | "the payee share is pushed, not claimed: a reverting payee cannot block the book" | "forced push: a payee that reverts or exceeds `PUSH_GAS` receives the eth through a self destructing contract" |
| should | `Core.sol:889` | "the existing buyback split is on the rest" | "the buyback split applies to the rest" |
| should | `Core.sol:916-917` | "the cut cannot push the pot share negative (bounded by the rest)" | "the pot share is at most the rest" |
| should | `Core.sol:1153-1154`, `CoreLib.sol:500` | "the balance token is held by the module, not the Core, so there is no balance leg" | delete |
| should | `CoreLib.sol:498`, `CoreLib.sol:500` | "`ethToBuyback` stays for the coin buyback" twice; lines over the column width | keep one |
| should | `Core.sol:193-198`, `1234`, `1241`, `1247` | "(decision 88)", "(decision 89)" | delete the citations |
| should | `CoreLib.sol:24-26` | "test/CoreLayout.t.sol compares the fields with raw storage words" | delete; SPEC section 2 holds it |
| should | `CoreLib.sol:83-84`, `CoreLib.sol:141-142` | "appended after the last slot so the eth instance keeps its slots", "appended" | "the balance bid price state, a `Rate`" (moot after L1-7) |
| nit | `Core.sol:1320-1321` | "a dormant approved adapter flag ... cannot come back to life" | "an adapter approval of the new module is cleared" |
| nit | `CoreLib.sol:29` | "once set, the door never opens again" | "one way: once set, never cleared" |
| nit | `Core.sol:1191-1192` | "which the restricted coin allows without the Core holding or receiving the coin" | "`burnFrom` burns from the caller's balance, which the restricted coin permits" |
| nit | `ControllerV1.sol:452-453` | "the bps is held in units of the asking price in wei" (garbled) | delete |
| nit | `ControllerV1.sol:292-293` | "the same source the balance token bid reads in `sellForBalance`" (every eth door reads it now) | "the score source of every Core door" |
| should | tests | decision numbers in comments and promises: `BalanceBid.t.sol:8`, `CreditSwap.t.sol:9`, `PerPoint.t.sol:7` ("decisions 55 and 80 reversed, 2026-10-14"), `PerPointExact.t.sol:8`, `Sale.t.sol:90,942,986,1016,1030`, GasCap promises "(decision 123)", `HandlerBase.sol:101`, `Invariants.t.sol:654` | drop the numbers; the promise line names the SPEC rule |
| should | tests | test file citations: `PerPointExact.t.sol:9-10`, `PerPointExact.t.sol:108` ("139 in BidRule"), `BidRule.t.sol:37`, `Fixture.sol:211-212` ("test/Config.t.sol pins it") | delete or state the number |
| nit | `HandlerBase.sol:78` | "(was bookBalance)" | delete |
| nit | `PerPoint.t.sol:9` | "these tests prove the eth doors scale with it too" | "the eth doors scale the bid and the drop by `score / refScore`" |
| nit | `CreditSwap.t.sol:10` | "so the score rule is exact, not fork dependent" | "so the score rule is tested at exact values" |

### names, nouns, vocabulary

| sev | where | issue | fix |
|---|---|---|---|
| should | `Core.sol:42,178,1078`, SPEC 3, web keeper "redeem burn pot" against `Core.sol:393,1078-1080`, `CoreLib.sol:40`, SPEC 1 and decision 106 "reserve" | two words for `ethRedeemBurn` | one word everywhere ("redeem burn pot" matches the web and SPEC 3) |
| should | `web/lib/live.ts:119` `balancePot`, `web/app/keeper/page.tsx` | `balancePot` names the module's `available()`, a name decision 117 removed from the Core | `balanceAvailable` |
| should | `ControllerV1.sol:215-224` | `pointRate` returns wei per score unit (one ten thousandth of a point); `valueOf(uint256 points)` takes score units; decision 104 says "eth per point" | rename to score units (`scoreRate`, `valueOf(uint256 score)`) or rescale to points; one unit across contracts, docs and web |
| should | `Settings.balanceBidMarginBps` | the field is now `10_000 - floor` of a rising bid; "margin" describes the removed flat bid | `balanceBidFloorBps` (the floor itself), or define "margin" once in SPEC as the opening discount |
| should | `Core.sol:469` `_bid()` | returns the clamped rate of a refScore credit; the bid of a credit is `bidOf` | `_rateRead()` |
| should | `web/app/keeper/page.tsx` "bid, average credit", feed "average-credit bid" | the rate is for a credit of score `refScore`, the launch average only until the owner changes it | "bid, reference credit" |
| nit | `CoreLib.sol:251`, `CoreLib.sol:347` | `climb` and `drop` are the eth instance only | `ethClimb`, `ethDrop` |
| nit | `saleToOperatorBps` paid to `payee` | two names for one recipient | name the cut `saleToPayeeBps` or the recipient operator |
| nit | `BalanceRateFill(spent, ...)` documented "the balance token paid" | spent vs paid | one word |
| nit | `CreditSwap.t.sol:104-105` `test_feeZeroSkipsTransfer` | the fee is a burn | `test_feeZeroBurnsNothing` |

counts without their noun: none found in the new code. "par" is used consistently in src; "exit" and "royalty" are absent from src and web.

verdict, lens 2: eleven comments in src state facts that are false at ac8da10, mostly lines the per point, cuts and rising bid packets left behind (the Core header, the `buyListing` pot claim, the controller credit floor, `creditSaleOn` launch value, the `balanceBidMarginBps` and `defaultCredit` docs, the balance batch clamp, the `climb` receive claim). history ("unchanged from the eth-only version"), decision citations and reviewer-response lines are concentrated in CoreLib and the sale paths of Core. vocabulary drift is real for reserve against pot, point against score unit, and margin against floor.

---

## lens 3. best practices

### solidity

| sev | file:line | issue | fix |
|---|---|---|---|
| should | `Core.sol:887-898`, `Core.sol:914-927`, `Core.sol:1204-1205` | effects after interactions: `sellTo` and `sellCreditTo` transfer the NFT before writing `ethToBuyback`/`ethPot`; `swapCredit` calls `burnFrom` before the node writes. the callees are the fixed Credits, Statements and coin contracts and every door holds the guard, so this is ordering hygiene | book first, transfer and push last |
| should | `Core.sol:210-211` | `PUSH_GAS` 50,000 carries no rationale; the failure path adds a `create` and a self destruct per push (up to three per sale or book). `test/GasCap.t.sol` rows measure plain recipients only | state the recipient the stipend is sized for (a Safe proxy `receive`), add gas rows with a reverting artist and payee |
| should | `CoreLib.sol:756`, `CoreLib.sol:639`, `Core.sol:1330` | `available()` reads are uncapped staticcalls; the `unitPerPoint` reads use `READ_GAS`. `balanceRate()` and `balanceBidOf()` are web views | cap at `READ_GAS`, require 32 bytes |
| nit | `CoreLib.sol:689`, `CoreLib.sol:722`, `CoreLib.sol:708` | `score * unit * rate` products carry no bound comment. bound: score at most 8e6, unit at most 2^128, rate at most 1e4, product under 2^179 | one line stating it |
| should | events | `FeesAdded` lacks the redeem burn share; `CreditSold` lacks the pot and buyback split; the balance reset inside `setSettings` (`CoreLib.sol:222`) emits no rate event while `setRate` emits `RateSet`; `BalanceRateFill` carries no credit id | add `toRedeemBurn`, `toPot`/`toBuyback`, a `BalanceRateSet(rate)` on reset, the id on `BalanceRateFill` |
| nit | `State` | packing is sound: `artist` shares a slot with `payeeOn`, `Settings` slot 3 holds 16 of 32 bytes. raw slot numbers are hard coded in `test/utils/Fixture.sol` (`ANCHOR_SLOT` 27), `HandlerBase.sol:2470-2472` (31 to 33) and `web/lib/live.ts:328` (27n) | the web reads Core storage by slot; a view of the anchor removes that coupling |
| should | `CoreLib.sol:278-300`, `354-373` | the shared bodies take the instance as parameters (`Anchor`, `clampTo`, `capMax`, `absFloor`), with no mode flag. `CoreLib.climb` takes the eth fields as arguments and the anchor from storage | resolved by L1-7 |
| should | duplicates | score read five times (`Core.sol:463-465`, `CoreLib.sol:461,688,721`, `ControllerV1.sol:295-299`); unit read four times (`Core.sol:1313-1317`, `CoreLib.sol:743-752,765-775`, `ControllerV1.sol:359-368`); owner check twice (`Core.sol:716-720`, `CoreLib.sol:603-607`); `READ_GAS` twice; `floorRate` against `_ethFloorNow` (`CoreLib.sol:264-272`, `664-669`); the retired check twice (`Core.sol:597`, `CoreLib.sol:632`) | one internal score reader and one unit reader in CoreLib (a revert flag), one floor function |
| nit | dead code | `CoreLib.sol:707` zero denominator branch (refScore and unit are at least 1); `CoreLib.sol:632` retired check (the Core checks first); `ControllerV1.sol:60` `ZeroAmount` unused; `web/lib/sell.ts:58` `replayBalance` unused; `web/components/Flywheel.tsx:10` `SHOW_LIVE = false`; `HandlerBase.sol:102` reserved action slot 30 | delete; renumber the action table |
| nit | `script/Checks.sol` | preflight does not check `artist` against the forbidden list; `setArtist` would revert mid deploy | one preflight row |

### tests

| sev | file:line | issue | fix |
|---|---|---|---|
| must | missing | no test for: the balance bid after a period with the bid off (L1-1), a balance batch whose second credit passes the remaining `available()` (L1-2), `buyListing` of a high score credit with a pot just above the quote (L1-3), `setSettings` raising the artist cut with a zero artist (L1-4), a `SetSettings` dry run that changes each cut (L1-5) | one test per finding, each failing at ac8da10 |
| should | `test/utils/Fixture.sol:403-422` | `_fillEthPile` sets `refScore` to each credit's score and sells one credit per call, so every compose, sale and redeem test runs at ratio 1, and each fill also books, checkpoints and runs the balance reset through `setSettings`. per point coverage lives only in PerPoint, PerPointExact and the invariants | fill at the launch `refScore` and assert costs from the scaled formula; keep the ratio 1 helper for BidRule only |
| should | `HandlerBase.sol:2517-2541`, `2497-2512` | `_pickBalanceIds` sizes every batch to fit `available()`, so the `PotTooSmall` path of `sellForBalance` is unreachable in the campaigns; `_balanceExpected` reproduces the once per batch clamp, so the oracle mirrors the code against its comment | pick batches across the limit and model the intended clamp |
| should | `PerPoint.t.sol:40` | `if (...) assertGt(...)` passes silently when the scores are equal | assert the scores differ first |
| should | `test/CreditSwap.t.sol` | node inheritance tested on a one node pile and at the head of 80; the middle and tail relinks, the `CreditSwapped` event, and a fee with too small an allowance are untested | three tests |
| nit | `BalanceBid.t.sol:67-73` | `balanceBidOf` checked against `balanceRate()` from the same contract (a view identity) | compute the rate from the stored state with `BidModel` |
| nit | `BalanceBid.t.sol:76-87` | the drop test asserts direction only | assert `dropPerCreditBps * score / refScore` exactly |
| ok | | every new test carries a `// promise:` line; PerPointExact and the sell handler compute payouts by hand and from `BidModel`, without reading `bidOf` back | |

### scripts

| sev | file:line | issue | fix |
|---|---|---|---|
| must | `script/SettingsFields.sol`, `script/SetSettings.s.sol` | L1-5 | |
| ok | `script/deploy.sh`, `Deploy.s.sol`, `SystemDeployer.sol` | one deploy path, environments as json data, `setMinProtocolSkimShareBps` computed from `bountyBps`, `setArtist` inside the deployer | |
| nit | `Deploy.s.sol:10`, `Resume.s.sol:11` | usage text offers `--private-key $KEY` (the key lands in argv and the process list) | lead with `--account` |

### web

| sev | file:line | issue | fix |
|---|---|---|---|
| must | `web/lib/live.ts:459-467`, `web/app/sell/page.tsx:182-183` | `balanceQuote` sums `balanceBidOf` at the undropped rate and the page sets `minOut` to 99.5 percent of it. each credit drops the rate by `50 * score / refScore` bps, so a batch of about four credits above the floor reverts `Slippage`. the comment "the sell sets minOut under it" is false at 99.5 percent | replay the balance batch with the drop (the eth replay already does) or add a Core batch quote view |
| should | `web/lib/live.ts:409-425`, `web/app/sell/page.tsx:45` | `useBidsOf` adds a 15 s poll of `bidOf` outside the snapshot. the same page derives the balance bid from the snapshot rate and cached scores (`sell/page.tsx:49-52`) | derive `ethRate * score / refScore` from the snapshot and `useScores`, or key `useBidsOf` on the snapshot update with no own interval |
| should | `web/lib/live.ts:381-398` via `sellQuote` | scores are re-read every minute; they are immutable and already cached by `useScores` | pass cached scores into `sellQuote` |
| should | `web/lib/live.ts:119-128` | the module read uses `allowFailure: false`; a module whose `available()` reverts fails the whole snapshot | `allowFailure: true`, default 0 |
| should | `web/lib/sell.ts:26-53` | `replayEth` re-implements the CoreLib clamp, drop and ceiling; per point it lets `left` go negative where the Core reverts `PotTooSmall` | a Core view that quotes a batch replaces both replays; until then stop the replay at `x > left` |

verdict, lens 3: the shared climb and drop are parameterised cleanly, the forced push is used consistently, and the deploy path is single. the freeze blockers here are operational: the settings script cannot set the decision 123 cuts and the web's balance sale reverts for ordinary batches. the code carries five copies of the score read and four of the unit read across Core, CoreLib and the controller, the balance instance's checkpoint and reset are separate bodies from the eth ones, and the test fixture runs every compose and sale test at a score ratio of 1, so the per point cost basis reaches those suites only through the invariants. the invariant handler avoids the balance `PotTooSmall` path by construction and its oracle copies the code's clamp, so it cannot catch L1-2.

## fixes

applied on `points/v1` after ac8da10. commits: `bae9ed7` (shared with security LOW), `22aff79` (logic), `154c3e9` (legibility), and the web/tests commit that follows. build hashes and sizes re-pinned (Core 23,797, CoreLib 17,475).

### lens 1 logic

| id | commit | fix | test |
|---|---|---|---|
| L1-1 | bae9ed7 / 22aff79 | the balance instance does not climb while `balanceBidOn` is false: `balanceRate()` reports the floor, and the instance resets to the floor and checkpoints when the bid turns on. SPEC 3/9 and decision 122 state it | `test/BalanceBid.t.sol` |
| L1-2 | bae9ed7 | ruling: a batch whose running total passes the clamp reverts whole (`PotTooSmall`); the code already does, the stale `CoreLib.sol:625` comment was corrected to match | `test/BalanceFloor.t.sol` |
| L1-3 | 22aff79 | `buyListing` caps the keeper payment with `.min(s.ethPot - value)` so `value + paid` never exceeds the pot; the `Core.sol:667` comment rewritten | existing `test/Adapters.t.sol`, `test/Seaport.t.sol` buyListing paths |
| L1-4 | 22aff79 | the artist is a Core constructor argument (the launch config carries it, `LaunchConfig` refuses zero), and `setSettings`/`setArtist` both refuse a nonzero cut with a zero artist | `test/Sale.t.sol::test_cuts_setSettingsRefusesCutWhileArtistZero` |
| L1-5 | 22aff79 | `SettingsFields` and the `SetSettings` tuple carry all 28 fields (the two cuts added); the Config bound sweep runs 28 | `test/Flow.t.sol::test_settings_fieldListLengthEqualsTheStructFieldCount`, `test/Config.t.sol` |
| L1-7 | 22aff79 (decision 122 amended) | the climb, drop and reset bodies are shared by both instances, parameterised by cap, floor and clamp; the eth instance keeps its inline slots (append-only layout, accepted) | `test/CoreLayout.t.sol`, `test/BuildIdentity.t.sol` |
| L1-8 | 22aff79 | owner ruling: `balanceBidMarginBps` launches at 1,000 (the bid opens at 90 percent of par) | `test/Flow.t.sol`, `test/Config.t.sol` |
| L1-9 | bae9ed7 | the `redeemSlippageBps <= balanceBidMarginBps` coupling dropped | `test/Flow.t.sol` |
| L1-10 | bae9ed7 | `refScore` bounded 800,000..8,000,000 | `test/Config.t.sol`, `test/Flow.t.sol` |
| L1-6, L1-11 | 22aff79 / 154c3e9 | owner rulings: `bidOf` keeps the formula value (the web marks it unpayable when above the pot); SPEC 3 and the sale comments say "gross" | docs |

### lens 2 legibility

commit `154c3e9`: the Core header split, the `buyListing` pot claim, the controller credit floor (`floorRate` term gone), `creditSaleOn` launch value true, the `balanceBidMarginBps` and `defaultCredit` docs, the `climb` `receive()` claim, the shared bid field docs (`dropPerCreditBps`, `climbPerMinBps`, `ceilBps`), `saleToBuybackBps`, `payeePpm`; history lines ("unchanged from the eth-only version"), decision citations and test-file names removed from src and the named tests; reviewer-response lines in the sale paths rewritten; one word per concept ("redeem burn pot", "floor", "score source"). the `_bid()`→`_rateRead()` rename and the `pointRate` rename were left (names used across the web; comments corrected instead).

### lens 3 best practices

| item | commit | fix |
|---|---|---|
| web balance `minOut` | web/tests | `balanceQuote` replays the per-credit drop from the snapshot like the eth quote, with the 0.5 percent guard (`web/lib/live.ts`, `web/lib/sell.ts`, `web/app/sell/page.tsx`) |
| web `balancePot` name | web/tests | renamed `balanceAvailable` across `live.ts`, the sell, keeper and balance pages; the keeper and feed "average credit" label is "reference credit"; the `ANCHOR_SLOT` comment says 27 |
| invariant handler floor | web/tests | `_afterSellBalance` asserts `floorSum <= paid <= parSum` per paid batch; the `PotTooSmall` regime is covered by `test/BalanceFloor.t.sol` and `test/CoreUnit.t.sol` rather than perturbing the live invariant module |
| `available()` uncapped | bae9ed7 | capped at READ_GAS, 32 bytes |
| dead code | web/tests | `ControllerV1.ZeroAmount` removed; interfaces regenerated |
| events | not applied | `FeesAdded`/`CreditSold` full split and the `BalanceRateFill` id would change the event signatures (another bytecode re-pin and handler/test decoder churn); `BalanceRateSet(rateBps)` on the reset was added (needed for the reset). deferred, flagged |
| `useBidsOf` poll fold, fixture ratio-1 rework, duplicated score/unit read collapse | not applied | should-level; deferred, flagged. one internal `scoreOf`/`_liveAvailable` were added in CoreLib |
| sim port (I5) | not applied | standalone JS rewrite, already red at ac8da10; deferred, flagged |
| reserved handler action slot 30 | not applied | removing it renumbers `N_ACTIONS` (42) and the parallel sized counter/name arrays; left as a documented reserved constant to avoid destabilising the invariant action map |
