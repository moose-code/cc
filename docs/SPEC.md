# spec: the credits engine as built

the current reading of the owner's intent and of the system that implements it. docs/DECISIONS.md is the dated decision log and the authority on intent; this file cites its numbers. docs/STATUS.md holds the plan, the freeze table and the state of the branch. precedence between sources: AGENTS.md. the vocabulary is "balance", never "exit".

## 1. the product

CC is a coin whose trading fees fund a permanent public bid for Credits. anyone sells Credits to the engine at that bid, and the engine sweeps cheaper listings on approved venues, keeping the discount. the engine composes 80 Credits into a Statement, holds it, and sells it at a price that starts above cost and falls to a floor the owner sets. a quarter of every sale burns CC and three quarters buys more Credits. when the balance token is live, Statements at their floor redeem into it by rating, the engine buys Credits with it by score at a bid that rises like the eth bid (decision 122), and every redemption burns CC from a reserve. the owner sets every number at once, with no delay; holders trust the owner key, and one way locks and a successor migration are the owner's ways to narrow or move that power. the engine launches before the balance token; the balance bid and chosen composition ship built and switched off; the credit sale window and the redeem switch are on at launch, and redemptions revert `NoBalanceModule` until the module is set. the balance token is held by its module, not the Core. (decisions 99 to 117, DECISIONS.md section 11.)

### intent at a glance

kind: guarantee (holds under every setting and actor), behavior (approved, the owner may change it), parameter (an owner setting), risk (accepted by the owner). every row is built at the candidate named in docs/STATUS.md.

| kind | intent | decisions |
|---|---|---|
| guarantee | while the engine has not migrated and the market price is at or below `rateCap`, a credit whose bid (`ethRate() * score / refScore`) the pot covers can always be sold to it | 42, 48, 116 |
| guarantee | eth and credits leave the Core only through its doors at their rules or through `migrate` to the successor; the balance token is held by the module, not the Core, and the Core moves it only at a seller's call bounded by `score * unit * margin` and the module's `available()`; coin leaves through `rescueCoin`, untracked NFTs other than Credits through `rescueNft`; no function sends them to the owner | 8, 28, 32, 33, 117 |
| guarantee | a statement leaves the Core by a `sellTo` sale at or above `saleFloorBps` of its cost, read at the sale, or by a redemption that returns at least its rating times the module's unit less `redeemSlippageBps` | 56, 68, 84, 105 |
| guarantee | the four locks (controller, balance module, adapters, successor) are one way | 9.6, 10.2 |
| guarantee | the engine pays at most `ethRate() * score / refScore` for a credit, keeper payment included | 71, 100, 116 |
| guarantee | fees reach the pot at the next door with no keeper; the payee is paid its share of fee income only, and nothing during the anti sniper window | 26, 109 |
| behavior | the engine never stops buying because statements are unsold | 2 |
| behavior | the eth bid is per point: a credit is paid `ethRate() * score / refScore` and a fill drops the rate by `dropPerCreditBps * score / refScore`; the bid rule and its settings are as built | 103, 116 |
| behavior | `buyListing` buys only a listing an approved adapter priced; the gap between the listing and the bid stays in the pot | 100 |
| behavior | statements sell on a falling curve from `markupBps` of the anchor down to `saleFloorBps` of the reference; the anchor moves up with sales and down with time | 62, 64, 65, 70, 105 |
| behavior | the price reference of a statement is `max(cost, valueOf(rating))`; a credit's sale floor is `max(cost, valueOf(score)) * creditFloorBps`; a balance bought credit costs `score * pointRate` | 104, 116 |
| behavior | a statement or credit sale takes `saleToArtistBps` to the artist and `saleToOperatorBps` to the payee off the top of the payment, both pushed, the rest split as before | 123 |
| behavior | the balance side: redeem at the floor by rating, buy by score at a rising bid, burn from the reserve; the module holds the token and redemptions keep filling it, so the bid off is the accumulate mode; `redeemOn` is on at launch and `balanceBidOn` is off until the module is set | 82, 84, 86, 107, 117, 122 |
| behavior | the credit sale window is on at launch and chosen composition is off; both are owner switches | 88, 89, 119 |
| behavior | a holder swaps a pile credit for one it owns of equal or higher score through `swapCredit`, for a `swapFeeCc` coin fee it burns | 118 |
| behavior | system compose picks a random format or takes one; holders of `minCcToChoose` CC restyle held statements | 113 |
| behavior | the composer of every statement is recorded | 111 |
| behavior | the owner pauses sales; a pause holds every statement's age | 81, 97 |
| behavior | the first `migrate` retires the engine, which keeps selling and redeeming its statements and burning its buyback pot | 33, 48, 52 |
| parameter | every economic number is an owner setting, effective at once, no timelock | 3, 15 |
| parameter | `rateCap` 3 times the opening bid; the opening bid is the market price on launch day of a credit of score `refScore`; `refScore` is a Core setting (the launch average credit score) | 46, 60, 69, 116 |
| parameter | payee 0 at launch (`payeePpm` 0, the setting stays for the owner to raise later), protocol 1.0 point of volume, engine 9.0 points | 31, 112, 120 |
| parameter | buyback slice 0.5 eth, at most 1 eth | 51 |
| risk | a market above `rateCap` stops buying until the owner raises it | 49 |
| risk | holders trust the owner key fully: the owner can overpay a seller it controls, set a module that returns dust, and move everything to a successor at once | 8, 9.4 |
| risk | the engine launches on AI run reviews with no human audit | 78 |

## 2. contracts

| contract | role |
|---|---|
| Core | custody and every rule: pots, the bid, the pile, compose, the sale booking, fee booking, the pause clock, buyback, the balance side, owner powers, locks, migrate, rescue |
| CoreLib | the Core's linked library, run by delegatecall in the Core's storage: the settings write, the bid math, the swap, the balance bid, `adopt`, `rescueCoin`, `rescueNft`, the successor and `migrate`. it exists because the Core's runtime is near the 24,576 byte limit |
| ControllerV1 | pricing policy: the statement curve and anchor, the credit sale prices, `pointRate` and `valueOf`, the pool key. swappable and lockable by the owner |
| SeaportBasicAdapter, CreditStrategyAdapter | read only pricers for `buyListing`, one per venue, approved by the owner |

storage: the Core declares one variable, `State internal s`, at slot 0, and the library reads the same struct type at slot 0. test/CoreLayout.t.sol compares every field with raw storage words. a new state variable is appended at the end of `State`.

live and external, used as deployed: the artcoins v2 stack (factory 0x9b17bf6f97F5429368E11028BC637479b4667f7b, skim hook, locker, fee escrow, mev module), the uniswap v4 pool manager, Credits, Statements, CreditScore, CreditStrategy, Seaport 1.6. the stack addresses are config inputs (script/config/mainnet.json); nothing in src/ hardcodes one except the mainnet constants of Credits, Statements, CreditScore, CreditStrategy, Seaport, Permit2, the position manager and the universal router.

## 3. settings

one `Settings` struct in Core storage, `setSettings(Settings)` owner only and effective at once, bounded by `SettingsBounds`. launch values from script/config/mainnet.json.

| setting | launch | bounds | meaning |
|---|---|---|---|
| `dropPerCreditBps` | 50 | 1 to 1,000 | fall of the rate per credit bought, bps of the rate before it |
| `dropFloorBps` | 5,000 | 5,000 to 10,000 | within one minute the rate stays at or above this share of the price state at the minute's first fill |
| `climbPerMinBps` | 50 | 1 to 1,000 | climb per minute at or above the recovery level, compounded |
| `ceilBps` | 11,000 | 10,000 to 30,000 | the rate stays at or below this share of the ceiling anchor |
| `idleLoosenBps` | 200 | 1 to 2,000 | growth of the ceiling anchor per full 10 minutes since the last fill |
| `saleFloorBps` | 10,000 | 1,000 to 40,000 | the one sale floor: the Core takes no statement payment below this share of its cost, and the controller's curve floors at this share of the reference |
| `saleToBuybackBps` | 2,500 | 0 to 10,000 | share of the statement sale rest to the coin buyback, the rest to the pot |
| `saleToArtistBps` | 250 | 0 to 1,000 | share of a statement or credit sale payment pushed to the artist, taken off the top before the other splits |
| `saleToOperatorBps` | 50 | 0 to 1,000 | share of a statement or credit sale payment pushed to the payee as the operator cut, taken off the top before the other splits |
| `recoveryClimbPerMinBps` | 200 | `climbPerMinBps` to 1,000 | climb per minute while the price state is below the recovery level |
| `recoveryGapBps` | 1,000 | 0 to 5,000 | the recovery level is the remembered peak less this share |
| `peakHalfLife` | 21,600 | 600 to 604,800 s | seconds in which the remembered peak halves |
| `buybackDelay` | 25 | 1 to 7,200 blocks | blocks between buybacks |
| `redeemOn` | true | | redemptions run; `redeemStatement` reverts `NoBalanceModule` until a module is set |
| `balanceBidOn` | false | | the balance token bid runs |
| `redeemSlippageBps` | 200 | 0 to 1,000, at most `balanceBidMarginBps` | a redemption must return at least `rating * unit * (10,000 - this) / 10,000` |
| `balanceBidMarginBps` | 9,000 | 0 to 9,000 | the floor and opening value of the balance bid, bps of par: the rate starts at `10,000 - this` and never drops below it, so a credit is paid at least `score * unit * (10,000 - this) / 10,000` and at most `score * unit` (par) |
| `redeemBurnBps` | 2,000 | 0 to 10,000 | share of the redeem burn pot moved to the buyback on each redemption |
| `buybackSlice` | 0.5 ether | 0.01 to 1 ether, at least twice the largest buyback payment | eth per buyback |
| `keeperFee` | 0.0003 ether | 0 to 0.005 ether | fee to the caller of `buyback` and `buyListing` on top of the gas |
| `keeperMaxBaseFee` | 5 gwei | 1 to 100 gwei | base fee ceiling of those gas refunds |
| `rateCap` | 2.67e16 (3 times `rateStart`) | 1e13 to 1e18 | the most the bid can be, wei per credit |
| `callerFee` | 0 | 0 to 0.005 ether | fee to the caller of `compose`, `composeChosen` and `redeemStatement`, from the pot |
| `callerMaxBaseFee` | 0 | 0 to 100 gwei | base fee ceiling of those refunds; 0 pays no gas |
| `feeToRedeemBurnBps` | 1,000 | 0 to 10,000 | share of fee income to the redeem burn pot, the rest to the pot |
| `payeePpm` | 0 | 0 to 200,000 | share of fee income pushed to the payee, parts per million |
| `refScore` | 4,330,000 | 1 to 8,000,000 | the per-credit score the eth bid divides by: a credit of score `s` is paid `ethRate() * s / refScore`. the controller reads it for the point rate and the statement reference |
| `swapFeeCc` | 10,000e18 | 0 to 1e24 | coin the caller of `swapCredit` burns to swap a pile credit for one of equal or higher score. base units, ten thousand coins at launch |

four standalone Core settings, each with its own setter and event: `creditCostToPotBps` (8,000; 0 to 10,000; share of a sold credit's cost booked to the pot, the rest of the sale rest to the buyback), `chosenComposeOn` (false), `minCcToChoose` (1e18 base units, one coin; the least CC balance of a caller of `composeChosen` and `setHeldFormat`, read at the call), `artist` (the address the artist cut of nft sales is pushed to, `setArtist`, owner only, event `ArtistSet`; the zero address is refused while `saleToArtistBps` is nonzero and a forbidden target is always refused).

the controller's settings, each struct set at once by the Core's owner: `Sale` (`markupBps` 15,000, 10,000 to 40,000 and at most `startCapBps`; `startCapBps` 100,000, at least `markupBps`, at most 200,000; `decayHours` 12, 1 to 720; `anchorHalfLife` 7 days, 1 to 90 days; `anchorMinCost` 0.1 ether, 0 to 10 ether) through `setSale`, and `CreditSale` (`saleOn` true; `window` 14,400 s, 1 minute to 30 days; `floorBps` 11,000, 10,000 to 40,000; `startBps` 30,000, 10,000 to 200,000) through `setCredit`. `setAnchorBps` (10,000 to `startCapBps`) and `setBalancePoolKey` are actions.

fixed inside the pool at launch and not adjustable: skim 10 points of volume, 90 percent of it to the engine as bounty recipient and 10 percent to the protocol, anti sniper skim 90 points falling to the baseline over 30 minutes, lp fee 0.

## 4. the bid

the rate is wei for a credit of score `refScore`. `ethRate()` is the read: the price state lowered to the pot, where the pot is `ethPot` plus the pot share of unbooked fee income. a credit of score `s` is paid `ethRate() * s / refScore`; `bidOf(id)` is that number for one credit. the eth doors read the score from the CreditScore contract (`scoreOf(seedOf, timestampOf)`, the same source the balance side reads), 800,000 to 8,000,000, never 0. `refScore` is a Core setting, 1 to 8,000,000, 4,330,000 at launch (the mean score over the first 2,000 credits within 0.015 percent). the doors book first, then read the bid of the booked pot.

| rule | as built |
|---|---|
| opening | `rateStart`, the market price on launch day of a credit of score `refScore` in wei (8.9e15 at the pin), in [1e13, 1e18] and at most `rateCap` |
| per credit | a credit of score `s` is paid `ethRate() * s / refScore` (`bidOf(id)`); `buyListing` caps the quote at it; `adopt` records `ethPrice() * s / refScore`, at least 1 wei |
| price state | the stored rate climbed per minute since its checkpoint: `recoveryClimbPerMinBps` below the recovery level, `climbPerMinBps` at or above it, compounded, continuous at the crossing, up to `min(ceiling, rateCap, pot)`; a price state above that bound holds its value |
| peak | the highest recent fill rate, halved every `peakHalfLife` since the last fill or `setRate`; every fill sets it to `max(fill rate, peak now)` |
| ceiling | `ceilBps` of `max(last fill rate, peak now)` grown by `idleLoosenBps` per full 10 minutes since the last fill |
| clamp | the read is at most the pot. a sale whose running total passes the pot reverts whole |
| drop | a credit of score `s` bought at price state `p` sets it to `p * (10,000 - dropPerCreditBps * s / refScore) / 10,000` (the fall bounded at 10,000), at least `dropFloorBps` of the price state at the minute's first fill. the drop tracks the eth spent |
| floor rate | `max(price state, peak now)`: the rate under every price floor of the engine (`floorRate()`) |
| reset | `setRate(rate)` restates the stored rate, the last fill rate and the peak |

the same price state machine runs as two instances, sharing every climb and drop setting above (`climbPerMinBps`, `recoveryClimbPerMinBps`, `recoveryGapBps`, `dropPerCreditBps`, `dropFloorBps`, `ceilBps`, `idleLoosenBps`, `peakHalfLife`). the eth bid is the instance above: the unit is wei, the cap is `rateCap`, the clamp is the pot, the opening value is `rateStart`, and `setRate` resets it. the balance bid is the second instance (section 9): the unit is the module's `unitPerPoint`, the rate is bps of par where par for a credit is `score * unitPerPoint`, the cap is 10,000 so the payout never exceeds par, the floor and opening value is `10,000 - balanceBidMarginBps`, and the clamp is the module's `available()` expressed as bps of par for a credit of score `refScore`, `available() * 10,000 / (refScore * unitPerPoint)`. `balanceRate()` is the read, the balance price state lowered to that clamp, and `balanceBidOf(id)` is `score * unitPerPoint * balanceRate() / 10,000`. a change of `balanceBidMarginBps` that raises the floor above the stored rate resets the instance to the new floor.

the pile: one insertion ordered doubly linked list of credit ids, oldest first, with cost basis and acquisition time per credit. every credit enters the pile through `sellForEth` (cost the per-credit bid paid), `buyListing` (cost the quote plus the keeper payment, at most the per-credit bid), `sellForBalance` (cost `floorRate * score / refScore`) or `adopt` (cost `ethPrice * score / refScore`).

## 5. fee intake

the Core is the pool's bounty recipient. `receive()` accepts eth from the hook and the fee escrow only and does nothing else; a plain send from anyone else reverts `UseFund`. every door starts with `_book()`: the eth above `ethPot + ethToBuyback + ethRedeemBurn`, with the door's own `msg.value` excluded, is fee income. the rate is checkpointed first; `payeePpm` of the income is pushed to the payee once `payeeOn`; `feeToRedeemBurnBps` of the rest goes to the redeem burn pot; the remainder goes to the pot. `payeeOn` latches at the first book with income at or after the launch time recorded by the factory plus `SNIPER_SECONDS` (1,800), and that book shares nothing, so the anti sniper window's income is never shared (decision 26). the owner or a keeper calls `book()` when the window ends so the latch does not wait for the next door.

other eth enters through doors that book it to the pot whole: `fund()` (payable, anyone, also the predecessor engine on `migrate`) and `collectEscrow()` (claims the Core's escrow credit, the refund of a partial buyback fill). the payee share is pushed by the book with `SafeTransferLib.forceSafeTransferETH(payee, amount, 50,000)`, so a payee that reverts or runs out of gas never blocks the book. the balance token is held by the module, not the Core, so there is no balance booking door. a stray external `escrow.claim(core, 0)` lands as fee income at the next book.

per 100 eth of volume at launch values: 1.0 eth to the protocol, 9.0 eth to the Core, of which 0 to the payee (payeePpm 0 at launch), 0.9 eth to the reserve, 8.1 eth to the pot.

## 6. doors

| door | rule |
|---|---|
| `sellForEth(ids)`, `(ids, minOut)` | pays `bidOf(id)` = `ethRate() * score / refScore` per credit from the pot, one checkpoint and one score-scaled drop per credit, the credit into the pile at that cost. `minOut` floors the total. up to about 91 credits fit under the transaction gas cap |
| `buyListing(adapter, id, params)` | the adapter must be approved; its `price(id, params)` is read by staticcall (300,000 gas, 8,192 bytes); the target passes the forbidden list; `value` is at most `bidOf(id)` and the pot; the Core must not own `id` before and must own it after with its balance up one; the balance may fall by at most `value`. the caller is paid `min(counted gas, 1,500,000) * min(basefee, keeperMaxBaseFee) + keeperFee`, at most `bidOf(id) - value`. cost basis `value + payment` |
| `sellForBalance(ids)`, `(ids, minOut)` | requires `balanceBidOn` and a module; pays `score * unit * balanceRate() / 10,000` in balance token per credit (the rising balance bid, section 4), the unit read from the module in the call, the rate dropped per credit; the running total must not exceed the module's `available()` (`PotTooSmall`), the module pays the seller with one `pay(seller, total)` and the seller's holding must rise by at least the total (`BadModule`); cost basis `floorRate * score / refScore`, at least 1 wei |
| `adopt(ids)` | puts credits the Core holds without a record into the pile at `ethPrice * score / refScore`, at least 1 wei |
| `swapCredit(inId, outId)` | not paused, not retired; `outId` in the pile (`NotInPile`), `inId` owned by the caller and not in a pile (`InPile`), `score(inId) >= score(outId)` (`ScoreTooLow`). the caller burns `swapFeeCc` coin through `burnFrom(caller, fee)` (approve the Core first, a zero fee burns nothing); `inId` takes `outId`'s pile node (position, cost basis, acquisition time) and `outId` returns to the caller. `CreditSwapped(inId, outId, caller, fee)` |

the first `migrate` retires the engine: these four doors and both composes revert `Retired`. `swapCredit` reverts `Retired` as well. forbidden targets, checked for adapters and their targets: Credits, Statements, the Core, the coin, the hook, the pool manager, the factory, the locker, the escrow, Permit2, the position manager, the universal router, the balance module and token.

the adapters: `SeaportBasicAdapter` prices a Seaport 1.6 basic order of one credit for native eth on an open route (the zone is ignored), with every additional recipient the offerer or an address on the adapter's allowlist (the OpenSea fee collector at launch; `setAllowedRecipient` by the Core's owner, additions refused after `lockAdapters`); `value` is the sum of every payout, so Seaport refunds nothing. `CreditStrategyAdapter` prices `nftForSale(id)` and calls `sellTargetNFT(id)`. a tip to the offerer or an allowlisted recipient can raise `value` up to the bid, which is what `sellForEth` pays.

## 7. compose

`compose()` composes the controller's page, the 80 oldest pile credits, with a format `keccak256(prevrandao, first id) % 8`; `compose(format)` with the given format, 0 to 7. `composeChosen(ids, format)` composes 80 pile credits the caller names: requires `chosenComposeOn`, a CC balance of at least `minCcToChoose`, and the newest named credit past its window. all three run one path: every credit is pulled from the pile (a missing or repeated id reverts), Statements mints to the Core, the record stores the cost (the sum of the credits' costs), the compose time, the rating (the sum of the credits' scores read from Statements) and the pause mark; `composerOf(sid)` stores the caller; `Composed(sid, ids, format, cost, price, caller)`, where `price` is the controller's `priceOf(sid)` read after the record is written with at most 400,000 gas, 0 when the read reverts, runs out of gas or answers short. the caller is paid `min(counted gas, 13,700,000) * min(basefee, callerMaxBaseFee) + callerFee` from the pot, 0 at launch. while the credit sale is on, the page is ready only once its newest credit is past `window`.

`setHeldFormat(sid, format)`: anyone with at least `minCcToChoose` CC sets the format of a held statement through `Statements.setFormat`; works while paused and after `migrate`. the balance gate is read at the call. a buyer sets its own format after the sale.

## 8. the sale

the Core sells through two doors the controller alone calls. `sellTo(sid, buyer)` requires a held statement and `msg.value >= cost * saleFloorBps / 10,000`, sends the statement, takes `saleToArtistBps` and `saleToOperatorBps` off the payment and pushes them to the artist and the payee, books `saleToBuybackBps` of the rest to the buyback and the remainder to the pot. `sellCreditTo(id, buyer)` requires a pile credit and `msg.value >= cost`, sends the credit, takes the two cuts off the payment, books `creditCostToPotBps` of the cost (bounded by the rest) to the pot and the remainder of the rest to the buyback. both push the cuts with `forceSafeTransferETH` at 50,000 gas and both revert `Paused` while paused.

the controller prices. `pointRate = floorRate / refScore` (wei per score unit; `refScore` is the per credit score in ten thousandths of a point). `valueOf(points) = max(floorRate * points / refScore, pool value of points * unit)`, where the pool term prices `points * unit` balance token base units at the balance pool's sqrt price and is 0 when the pool key or the module is unset, the unit read fails or exceeds `uint128.max`, the pool reads zero or a product exceeds 256 bits. the reference of a statement is `max(cost, valueOf(rating))`. the asking price is the reference times a bps curve: start `min(anchorBps * markupBps / 10,000, startCapBps)`, falling in a straight line to `saleFloorBps` of the reference over `decayHours` hours and resting there, computed at each call from the statement's age (`statementAge`, which excludes paused seconds) and the current settings. `atFloor(sid)` is true once the curve has reached that floor. the anchor is 10,000 plus an excess that halves every `anchorHalfLife`; a `buy` of a statement costing at least `anchorMinCost` at a price above the anchor (in bps of the reference) moves it to the mean, at most `startCapBps`.

`buy(sid)` takes `price`, forwards it to `sellTo`, refunds the excess last. the artist and operator cuts come off the payment inside `sellTo`.

the credit sale window (`saleOn`): every pile credit is for sale from its acquisition: `creditPrice(id)` falls in a straight line from `floor * startBps / 10,000` to `floor = max(cost, valueOf(score)) * floorBps / 10,000` over `window` and rests there. `valueOf(score)` is at least `floorRate * score / refScore`, which is at least the per-credit eth bid `ethRate() * score / refScore`, so with `floorBps` at or above 10,000 a buy followed by `sellForEth` cannot profit. `buyCredit(id)` and `buyCredits(ids)` take the price each and forward it to `sellCreditTo`, which takes the two cuts off the top. `pastWindow(acquiredAt)` is true while the sale is off or `window` has passed; compose takes only credits past their window.

the pause: `setPaused(bool)` on the Core, owner only. `pausedTotal` accumulates closed pauses and `pausedSince` marks the open one; a statement's record stores the paused seconds at its compose, so its age `(now - composedAt) - (paused seconds since compose)` holds through a pause. the credit window and the anchor run on wall time.

## 9. the balance side

the module holds the balance token; the Core holds none (decision 117). the module's interface adds `available()`, the token it commits to the bid (it may hold more and keep the rest for other uses), and `pay(to, amount)`, the Core only, which moves `amount` to `to` and reverts above `available()`. a redemption's proceeds stay in the module. the bid off (`balanceBidOn` false) is the accumulate mode: redemptions keep filling the module while `redeemOn`, and nothing leaves the module through the Core until the owner turns the bid on. a module that spends its holding elsewhere halts the bid at `PotTooSmall`; the balance side is optional by design.

the balance bid is the second instance of the eth bid's price state (section 4): it climbs in bps of par toward the 10,000 cap, floors at `10,000 - balanceBidMarginBps` (its opening value), and clamps to the module's `available()` as bps of par. `balanceRate()` reads the rate now and `balanceBidOf(id)` the balance token payout for one credit. `sellForBalance` climbs the instance to now, pays each credit `score * unit * balanceRate() / 10,000`, drops the rate per credit by `dropPerCreditBps * score / refScore` (floored at the opening value), and books the running total against `available()` in base units. the credit enters the eth pile at cost basis `floorRate * score / refScore`, at least 1 wei. `BalanceRateFill` logs each credit's spend, the rate after its drop, and the available left.

`redeemStatement(sid)`: requires a module and `redeemOn`, a held statement, and `atFloor(sid)` from the controller (a bounded read of 400,000 gas; a failure reads as not eligible). the Core forgets the statement, hands it to the module, calls `redeem(sid)`, and requires the module's balance token holding to rise by at least `rating * unit * (10,000 - redeemSlippageBps) / 10,000`, with `unit` the module's `unitPerPoint()` read in the call. a failed, zero or oversized unit read, or a holding that rises by less than that, reverts `BadModule`. the proceeds stay in the module. `redeemBurnBps` of the redeem burn pot moves to the buyback. the caller is paid like a composer, 0 at launch.

`setBalanceModule(module)`, owner only, any number of times until `lockBalanceModule`: the module must have code, report a `balanceToken` with code that never changes once set, pass the forbidden list, report a valid unit at the set, and answer `available()`. `lockBalanceModule` reverts while no module is set. `releaseRedeemBurn(amount)` moves reserve eth to the buyback at any time.

## 10. buyback

`buyback()`, anyone, at most once per `buybackDelay` blocks: takes `min(buybackSlice, ethToBuyback)`, swaps exact eth in for coin on the canonical pool through the pool manager's unlock, burns the coin on the token, and pays the caller `min(counted gas, 600,000) * min(basefee, keeperMaxBaseFee) + keeperFee * spent / largest budget`. a slice under twice the largest payment reverts. the hook's skim on this swap reaches the Core during the swap and is fee income at the next book. there is no minimum output; the slice bound and the pool depth limit a sandwich (decision 51; lower the slice after a large price fall, RUNBOOK section 4).

## 11. owner powers and the hard rule

| power | effect |
|---|---|
| `setSettings`, `setRate`, `setCreditCostToPotBps`, `setChosenComposeOn`, `setMinCcToChoose`, `setPaused`, `setPayee` | at once, no timelock, bounded by `SettingsBounds` and `CreditBounds` |
| `setController` | at once, never zero; closed by `lockController` |
| `setBalanceModule` | at once; closed by `lockBalanceModule`, which needs a module set |
| `addAdapter`, `removeAdapter` | at once; `addAdapter` refuses zero and forbidden addresses; closed by `lockAdapters` (removing stays open; the Seaport adapter refuses new recipients after the lock) |
| `setSuccessor`, `lockSuccessor`, `migrate(maxCredits)` | the successor must have code and pass the forbidden list; `migrate` moves `ethPot` (through `fund()`, or a plain send when that fails) and up to `maxCredits` credits, and retires the engine on the first call; the balance token is held by the module, not the Core, so there is no balance leg; `lockSuccessor` with the successor zero disables migration |
| `rescueCoin(to, amount)`, `rescueNft(token, id, to)` | coin the Core holds, and an ERC721 the Core holds that is not a Credit and not a held statement; a Credit is refused in every state (`NoCreditRescue`), credits leave at the owner's call only through `migrate` |
| `releaseRedeemBurn` | reserve eth to the buyback |
| `transferOwnership`, `acceptOwnership` | two step, no renounce |
| on the controller: `setSale`, `setCredit`, `setAnchorBps`, `setBalancePoolKey` | at once, by the Core's live owner |
| as coin admin: `setBountyRecipient`, `lockRecipients`, `setAllowed`, `lockAllowlist`, `unrestrict`, `renounceAdmin` | the fee stream migration switch is the bounty recipient; `lockRecipients` seals it and is taken with `lockSuccessor` (decision 109) |

the hard rule: eth and credits leave the Core at the owner's call only through `migrate`, to the successor. the balance token is held by the module and leaves it only through the module's own rules; the Core moves it only at a seller's call, bounded by `score * unit * margin` per credit and by the module's `available()`. every other outflow is capped by a bound: the bid for a credit, `keeperFee` and `keeperMaxBaseFee` times the gas caps for the keeper doors, `callerFee` and `callerMaxBaseFee` times the gas caps for compose and redeem, the floors for the sale doors, and the three forced pushes bounded by their share of the payment or the income (the artist cut `saleToArtistBps`, the operator cut `saleToOperatorBps`, each at most 1,000 of 10,000, and the payee fee share `payeePpm`, at most 200,000 of 1,000,000), each sent with a 50,000 gas forced transfer so a reverting recipient never blocks a sale or a book. `setPayee` redirects the payee push and the operator cut, `setArtist` redirects the artist cut.

what the rule does not cover, accepted by the owner (decisions 8, 9.4): the owner sets the price the engine pays, so a dishonest owner or a stolen key can sell credits to the engine at an inflated rate and drain the pot, set a module that returns dust for statements or a unit that overpays the balance bid, swap the controller and sell every statement at the floor, and move everything to a successor at once. holders trust the owner key fully. mitigations: a multisig owner, the events on every setter, the locks.

## 12. launch

nine transactions, all but the launch through the deterministic deployer (CREATE2) at addresses that depend on the config and the salts, never on the deployer's nonce: the library, the Core (its constructor computes the coin address through the factory's `predictToken` with itself as bounty recipient), the controller (built with the Core address), the Seaport adapter, the CreditStrategy adapter, `setController`, `addAdapter` twice, and `deployTokenAsOwner` with the deploy fee (0.069 eth at the pin). measured on a fork of block 26186912: 16,120,826 gas in all, the Core creation 5,242,833, the launch 3,627,708; every transaction under the 16,777,216 cap. the factory owner key signs every transaction and is the Core's owner, the config owner and the payee. before the launch the factory owner lowers `minProtocolSkimShareBps` to 100. after the launch: `book()` at the end of the anti sniper window. `lockRecipients` is a later owner decision. the runbook is docs/RUNBOOK.md.

## 13. tests

real contracts only, on a mainnet fork pinned to block 26158000 against the live v2 stack; the two stand ins are the balance module and the balance token. every kept test names the promise it protects in a `// promise:` line. during work: `forge build` and `forge test --match-path` on the touched files. the full suite, the deep invariant runs and the rehearsal run once, on the frozen candidate (docs/STATUS.md). the simulator (sim/) models the same rules.

the invariants, in test/invariant/Invariants.t.sol, run against the real system in nine suites (phase 1 after and inside the sniper window, the balance side, a hostile controller, a hostile owner, and three with the sale and owner actions) with seven Deep variants:

| # | invariant |
|---|---|
| 1 | eth leaves the Core only as a credit purchase within the bid, a keeper or caller payment within its cap, a buyback slice, a refund or a migration |
| 2 | no credit is bought above the read |
| 3 | no statement is sold below the hard floor |
| 4 | every statement is in exactly one place |
| 5 | the pots never exceed the balances |
| 6 | the rate follows the model |
| 7 | no spend above the pot |
| 8 | the owner and the controllers never gain |
| 9 | the coin supply falls only by burns |
| 10 | `receive` never reverts for the hook; a plain send reverts `UseFund` |
| 11 | no unexpected reverts; every refusal carries the expected selector |
| 12 | a statement leaves only by a sale or a redemption |
| 13 | locks, retirement and handovers never come undone |
| 14 | no call from inside a redemption into a door ever worked |
| 16 | the bid never closes while the engine has not migrated |
| 17 | every credit is in exactly one place |
| 18 | eth conservation across the pots |
| 19 | the read is within its bounds |

invariants 15 (the fee router) and 20 (the lens) are retired with their subjects.

## 14. accepted properties and risks

| # | item |
|---|---|
| 1 | the owner changes every economic number at once; the bounds are the only limit; holders trust the owner |
| 2 | `saleFloorBps` can be set as low as 1,000; a change reaches every held statement at once |
| 3 | `redeemStatement` is permissionless: with `redeemOn` anyone redeems a statement at its floor at whatever the balance token is worth |
| 4 | the skim rates are fixed in the pool; the bounty recipient is the coin admin's switch until `lockRecipients` |
| 5 | the coin is restricted: trading works only through the canonical pool; the owner can `unrestrict` |
| 6 | the buyback has no minimum output; the slice and the pool depth bound a sandwich |
| 7 | a fee on transfer or rebasing balance token is unsupported |
| 8 | credits sent to the Core outside the doors sit in no pile until `adopt`, and `rescueNft` does not return them; eth from a non hook sender must come through `fund` |
| 9 | the stack and the coin are deploy inputs; a new stack is a new Core; a new Core on the same coin takes the fee stream through the coin admin's `setBountyRecipient` |
| 10 | the module door stays open until `lockBalanceModule`; a dishonest module takes every statement for dust |
| 11 | a pool price pushed down lowers `valueOf` to the rate term and never below cost; pushed up, it raises asks and a buyer pays the quote or waits; the cost basis of a balance bought credit reads no pool |
| 12 | raising the anchor can delay a redemption until the curve falls back |
| 13 | a restyle can front run a purchase; the buyer restyles after the sale. the `minCcToChoose` gate is a balance read at the call |
| 14 | the payee latch: fees that arrive between the end of the sniper window and the first `book()` are not shared; the owner calls `book()` at the window's end |
| 15 | a tip in a Seaport order to the offerer or an allowlisted recipient raises the engine's payment up to the bid, the price `sellForEth` pays |
| 16 | mainnet caps a transaction at 16,777,216 gas; `compose` uses about 8.5 million after refunds and a `sellForEth` batch stops at about 91 credits (per point, each credit reads its score) |
| 17 | the engine launches on AI run reviews (docs/reviews/) with no human audit |
| 18 | `swapCredit` treats a higher score as more desirable: it takes an incoming credit of equal or higher score and holds the pile's total score. a holder who values a lower score credit more cannot swap for it; the `swapFeeCc` burn and the score floor are the only gates |
