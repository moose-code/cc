# integration

for integrators and keepers: the contracts, the call sequences of each door, the events, the reverts and the measured gas. the rules behind the numbers are in docs/SPEC.md (the bid, the doors, the settings) and docs/DECISIONS.md (the decisions). the owner commands are in docs/RUNBOOK.md.

units. a rate is wei per credit. every credit has the same price, the rate. every credit sits in one pile and carries a cost basis in eth. bps is out of 10,000, ppm out of 1,000,000. settings values quoted below are the launch values of `script/config/mainnet.json`; `core.settings()` returns the live ones.

## 1. contracts and addresses

| contract | address | where to read it |
|---|---|---|
| Credits | 0x97630aA70AB14ed9883B41dAfccBc11349723043 | constant `Mainnet.CREDITS` |
| Statements | 0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b | constant `Mainnet.STATEMENTS` |
| CreditStrategy | 0x8e607209899b5d12Bd3167a6CD0E8E11FEB053d6 | venue of `CreditStrategyAdapter` |
| Seaport 1.6 | 0x0000000000000068F116a894984e2DB1123eB395 | venue of `SeaportBasicAdapter` |
| pool manager | 0x000000000004444c5dc75cB358380D2e3dE08A90 | uniswap v4, holds the coin pool |
| Core | the `core` line of the `Deploy` output | custody and every rule |
| coin | `core.COIN()` | launched through the artcoins v2 factory |
| controller | `core.controller()` | ControllerV1 at launch. the owner can replace it until `lockController` |
| fee recipient | `core.COIN()`, `core.payee()` | the Core is the bounty recipient of the pool. `payee` is the address `claimPayee()` pays |
| balanceModule, balanceToken | `core.balanceModule()`, `core.balanceToken()` | zero until the owner sets them (unset at launch, decision 82) |

the record of a launch is the output of `script/Deploy.s.sol` (core, coin, controller), the broadcast file `broadcast/Deploy.s.sol/1/run-latest.json`, and the table that `script/Postflight.s.sol` prints after reading every address back (docs/RUNBOOK.md steps 6 and 8). a keeper needs the Core address and reads the rest from it.

## 2. quoting a credit

| question | call |
|---|---|
| the eth a seller receives now for a credit | `core.ethRate()` (the snapshot field `ethRate`) |
| the price state before the clamp of a thin pot | `core.ethPrice()` |
| the floor rate under the price floors, the larger of the climbed eth bid rate and the remembered peak | `core.floorRate()` |

a batch sold through `sellForEth` is paid credit by credit. after each credit the rate falls by `dropPerCreditBps` (50, which is 0.5 percent) and stays at or above `dropFloorBps` (5,000) of the price state at the first fill of the current minute, so the total of a batch of `n` credits is below `n * ethRate`. the quote of the first credit is exact for the state of the block the transaction runs in. the pull of fees (section 7) runs first and can raise the pot, which can only raise the read, so the first credit is paid `ethRate` or more. `minOut` is the floor on the total.

between fills the price state climbs toward the ceiling. the ceiling anchors on the higher of the last fill rate and a remembered peak (`peakHalfLife` 6 hours), so after a large sale it stays near the pre sale price and the bid climbs back at `recoveryClimbPerMinBps` (2 percent a minute) while below the recovery level (`recoveryGapBps` 1_000, 10 percent under the peak), then `climbPerMinBps` (0.5 percent) at or above it. a one minute dump of 140 credits halves the bid and it is back at the pre dump price in 59 minutes and a three minute dump of 420 credits in 146 minutes (2.4 hours); a sale within the gap climbs at the 0.5 percent rate (a lone seller of one credit sells 60 credits an hour at the opening price, batches of 10 sell 60, batches of 19 sell 76). the remembered peak decays between fills, so the read can fall over a quiet period (at most about 0.19 percent a minute at the launch half life): a seller reads the live bid with `ethRate()` each block and sets `minOut` on `sellForEth(ids, minOut)` rather than assuming the bid holds or recovers on a fixed schedule. the owner can also restore the bid at once with `setRate`.

## 3. door 1: sell credits for eth

`sellForEth(uint256[] ids)` and `sellForEth(uint256[] ids, uint256 minOut)`. the first form is the second with `minOut` 0.

sequence for a seller:

1. approve the Core once: `Credits.setApprovalForAll(core, true)`, or `Credits.approve(core, id)` per credit.
2. quote with `core.ethRate()` and set `minOut` below the expected total.
3. call `core.sellForEth(ids, minOut)` from the owner of every credit in `ids`.

what the call does, in order:

1. the Core books the eth above its tracked pots (`_book`). fee eth reaches `ethPot` before any price is read.
2. reverts `Empty` for an empty list.
3. for each id: the caller must own the credit (`ZeroId`, `NotOwner`). the price is the rate now. the spend is checked against the pot (`PotTooSmall`, `ZeroAmount`). the rate falls. the credit enters the pile with the price as its cost basis. `Credits.transferFrom(caller, core, id)`. event `CreditBought(id, caller, price)`.
4. `Slippage` when the total is below `minOut`.
5. the total goes to the caller in one eth transfer, last. a contract caller needs a `receive()` that accepts eth.

what the caller receives: the total payout.

the batch size is bounded by the transaction gas cap: the largest batch under 16,777,216 gas is 115 credits at the launch settings (section 13).

`sellForBalance(ids)` and `(ids, minOut)` are the balance side door (docs/SPEC.md section 9). they run while `balanceBidOn` is true and pay each credit `score * unit * (10_000 - balanceBidMarginBps) / 10_000` in balance token from `balancePot`, with `unit` the module's `unitPerPoint()` read in the call. the credit enters the pile with an eth cost basis of the floor rate times `score / refScore`, at least 1 wei, and `CreditBought(id, caller, cost)` carries that basis. the basis reads no pool, so the bid needs no pool key and records the same basis whatever the pool price. they revert `BalanceBidOff` while `balanceBidOn` is false and `Retired` after `migrate`; `lens.balanceBidOf(id)` quotes the payout.

## 4. door 2: buy a listed credit through an approved adapter

`buyListing(address adapter, uint256 id, bytes params)`. the adapter prices the listing from the venue's own data and answers the one call the Core makes. the caller is paid from `ethPot` for the gas of the call. the Core pays with its own eth and the credit arrives at the Core.

an adapter implements `IListingAdapter.price(id, params)` and returns `(target, value, data)`. the owner approves adapters (`addAdapter`, `removeAdapter`, `lockAdapters`). the launch adapters are in `core.allowedAdapter(adapter)`.

sequence for a keeper:

1. find a listing of credit `id` and the adapter of its venue: `SeaportBasicAdapter` for a Seaport 1.6 basic order, `CreditStrategyAdapter` for the CreditStrategy.
2. read `adapter.price(id, params)` and check the room: `value <= core.ethRate()` and `value <= core.ethPot()`.
3. call `core.buyListing(adapter, id, params)`.

`SeaportBasicAdapter`: `params = abi.encode(BasicOrderParameters)`, the struct of `fulfillBasicOrder_efficient_6GL6yc` (`src/interfaces/ISeaport.sol`). the order must offer exactly credit `id` (`offerToken` Credits, `offerIdentifier` `id`, `offerAmount` 1), pay native eth (`considerationToken` 0, `considerationAmount` above 0), use an open route (`ETH_TO_ERC721_FULL_OPEN` or `ETH_TO_ERC721_PARTIAL_OPEN`), and every additional recipient must be on the allowlist of the adapter (`allowedRecipient`, the OpenSea fee collector at launch). `value` is `considerationAmount` plus every additional amount, the target is Seaport and the Core is the buyer. a restricted route, a recipient off the allowlist, a wrong token or a wrong id makes `price` revert, and the Core answers `BadQuote`.

```solidity
bytes memory params = abi.encode(order); // order: BasicOrderParameters signed by the seller
core.buyListing(seaportAdapter, id, params);
```

`CreditStrategyAdapter`: `params` is empty. `value` is `nftForSale(id)` of the CreditStrategy and the call is `sellTargetNFT(id)`. `price` reverts `NotForSale` when `nftForSale(id)` is 0.

```solidity
core.buyListing(strategyAdapter, id, "");
```

what the call does, in order:

1. the fee pull of section 7, before the listing is priced.
2. `AdapterNotAllowed` when the adapter is not approved. `ZeroId`. `AlreadyOwned` when the Core owns the credit.
3. the Core reads `adapter.price(id, params)` by a static call capped at 300,000 gas and 8,192 bytes of answer. a revert, a gas overrun, an answer of fewer than three words or an answer of more than 8,192 bytes reverts `BadQuote`.
4. `ForbiddenTarget` when the target is a forbidden contract. `ZeroAmount` when `value` is 0. `PotTooSmall` when `value` is above `ethPot`, `AboveBid` when it is above `ethRate()`.
5. the Core calls `target` with exactly `value` and `data`. `CallFailed` when it reverts.
6. the Core checks that exactly one credit arrived and that it is `id` (`NoCredit`) and that the eth balance fell by at most `value` (`BadCost`). a plain send of eth to the Core during the call reverts `UseFund`, so the listing target pays out through the adapter.
7. the payment is `min(min(counted gas, BUYLISTING_GAS) * min(block.basefee, keeperMaxBaseFee) + keeperFee, bid - value)`, paid to the caller last. counted gas is the gas measured from the first line of `buyListing` (the fee pull and the quote included) plus 250,000 for the work after the count, the transaction base cost and calldata. `BUYLISTING_GAS` is 1,500,000. `keeperFee` is paid whole. the base fee is used and the priority fee is not refunded. the cap `bid - value` is the bid less the listing price, and the bid is at most `ethPot`, so value plus payment never exceeds the bid.
8. `value + payment` is spent from the pot and is the cost basis of the credit. event `ListingBought(id, adapter, caller, cost, paid, rate)` with `cost` equal to `value`.

keeper economics: the adapter refuses a payout to the caller, so the payment of step 7 is the caller's whole income and the engine keeps the gap between the bid and the listing price. a gap above the full payment pays counted gas plus `keeperFee`. counted gas exceeds the gas of the transaction by 19,000 to 31,000 on the measured paths, so the caller earns `keeperFee` plus that margin at the base fee, less its priority fee. a smaller gap pays the whole gap, so the caller profits when the gap exceeds its gas cost. at 2 gwei and no priority fee a basic Seaport order costs the caller about 0.00086 eth, so the payment alone breaks even at a gap of that size (10 percent under the opening bid of 0.0089 eth) and a gap above 0.0014 eth pays about 0.00054 eth net (`test/Seaport.t.sol` `SeaportCallerPayTest`).

## 5. compose

`compose()`, `compose(uint8 format)` and `composeChosen(ids, format)`. anyone may call `compose()` and `compose(format)`. the controller decides the page: `ControllerV1.nextPage()` is ready when the pile holds 80 credits and returns the 80 oldest; the Core ignores the format it returns. `compose()` sets the format to `keccak256(abi.encode(block.prevrandao, first page id)) % 8`; `compose(format)` sets the given format (0 to 7). while the credit sale window is on (section 6) it is ready only once the newest of the 80 has been in the pile for `creditWindow`. `controller.nextPage()` reports it. `composeChosen(uint256[80] ids, uint8 format)` composes the 80 credits and the format (0 to 7) that the caller names. it needs `chosenComposeOn` (off at launch), a caller coin balance of at least `minCcToChoose` (1 coin at launch) and every named credit past its window. a credit may be named when `core.creditInfo(id)` reports it in the pile and `controller.pastWindow(acquiredAt)` is true.

what the call does:

1. the fee pull of section 7.
2. `compose` and `compose(format)`: `NotReady` when the controller reports no page. `composeChosen`: `ChosenComposeOff` while the door is off, `BelowMinCc` when the caller holds less than `minCcToChoose` coin at the call, `InWindow(id)` when the newest named credit is inside its window. all three: `BadFormat` for a format above 7.
3. the 80 credits leave the pile (`NotInPile` for a credit that is absent or named twice, `NotHeld`) and go to `Statements.compose`. `BadStatement` when the result is not the next statement id held by the Core with 80 credits.
4. the statement is booked with the sum of the cost bases of its 80 credits and its rating, the sum of the credits' scores that `Statements.creditScoreOf` reports at compose (`BadStatement` when it exceeds a uint32). holders of the coin and people in the project compose, and the owner composes when nobody does.
5. event `Composed(sid, ids, format, cost, caller)` with `ids` the 80 credit ids. the statement stays in the Core with its compose time (`statementInfo(sid)`).
6. the caller payment, last. `min(counted gas, 13,700,000) * min(block.basefee, callerMaxBaseFee) + callerFee`, from `ethPot`, at most `ethPot`. counted gas is the gas measured from the first line of the body, which includes the fee pull, plus 50,000 for the transaction base cost and the work after the measured part. `compose` and `composeChosen` pay by the same rule. `callerFee` and `callerMaxBaseFee` are 0 at launch, so the payment is 0 and no eth moves. the owner turns it on with `setSettings`. the payment goes to `msg.sender`, so a contract caller needs a `receive()` that accepts eth. `redeemStatement` pays its caller by the same rule and the same two settings, with a gas bound of 1,500,000 and 50,000 of overhead. the transfer is the last action of the door and the Core is locked against re entry while it runs.

send at least 12,000,000 gas: the live Statements contract needs about 8.7 million for 80 credits, and the gas the transaction needs is the gas before the refund of the cleared credit records, 10.6 million (section 13).

`setHeldFormat(uint256 sid, uint8 format)` sets the format of a statement the Core holds for sale, through `Statements.setFormat`. anyone may call. reverts: `NotForSale` when the Core does not hold `sid`, `BadFormat` for a format above 7, `BelowMinCc` when the caller holds less than `minCcToChoose` coin (1 coin at launch). emits `HeldFormatSet(uint256 indexed sid, uint8 format, address indexed caller)`. the coin minimum is a balance read at the call, so a flash balance passes it, and the call works while paused and after `migrate` (a retired engine keeps its held statements and sells them). a restyle can land before a purchase of that statement. a buyer sets the format of an owned statement on Statements itself. the current format reads from `Statements.formatOf(sid)`.

## 6. statements and credits: buying

a statement stays in the Core after compose and sells only through `ControllerV1.buy`. `core.heldStatements()` lists the held statements and `core.statementInfo(sid)` gives each cost and compose time. the price reference of a statement is `controller.referenceOf(sid)`: `max(cost, floorRate * rating / refScore)`, the larger of its cost and the floor rate (`core.floorRate()`) times its rating over `refScore` (`controller.refScore()`, 4,330,000 at launch, in ten-thousandths of a point per credit), computed at each call. the floor rate is the larger of the climbed eth bid rate and the remembered peak, so a sale within the block, which lowers only the rate, cannot push the reference down. the rate term prices the rating at the engine's average credit price, so two statements of the same rating reference the same amount once it binds, whatever each credit cost. the asking price at `age` seconds since its compose is `reference * price / 10,000`, with `price` in bps of the reference falling at a fixed rate and changing every second: `start` less `fastDecayBpsPerHour` (100) per hour while above `kneeBps` (10,000), then `kneeBps` less `slowDecayBpsPerHour` (25) per hour from the second the knee is reached, never below `floorBps` (10,000 at launch). a `start` at or below `kneeBps` falls at the slow rate from compose. at the launch anchor the price is 15,000 at compose, 12,500 at hour 25 and 10,000 at hour 50, where it stays (the launch knee and floor are both 10,000, so an unsold statement sits at its reference). `start` is `controller.startBps()`, which is `min(anchorBps * markupBps / 10,000, startCapBps)`, 15,000 at the launch anchor of 10,000. `anchorBps` is the running level of sale prices in bps of the reference. a `buy` of a statement whose cost is at least `controller.anchorMinCost()` (0.1 eth at launch, an owner setting from 0 to 10 eth) and whose sale price in bps of the reference is above the anchor sets it to the mean of the anchor now and the sale price, at most `startCapBps` (100,000). every other `buy` completes and leaves the anchor and `anchorTime` unchanged. the part of the anchor above 10,000 halves every `anchorHalfLife` (604,800 seconds, 7 days at launch), continuously, so the anchor falls with time and `controller.anchorBps()` returns the value now. the price is computed from the age, the anchor now and the current settings at every call, so the price of a held statement rises when another statement sells above the anchor, falls as the anchor decays, and changes at once when the owner changes `markupBps`, `startCapBps`, `anchorHalfLife`, `anchorMinCost`, `refScore`, either rate, `kneeBps`, `floorBps` or `saleFloorBps`. the owner sets the seven sale numbers (`markupBps`, `startCapBps`, `fastDecayBpsPerHour`, `kneeBps`, `slowDecayBpsPerHour`, `anchorHalfLife`, `anchorMinCost`) with `controller.setSale(Sale)` and the credit sale, `refScore` and the royalty with `controller.setCredit(CreditSale)`. each call sets all its fields at once, checks every field against the bounds of the others and emits the whole struct (`SaleSet`, `CreditSaleSet`). `sellTo` takes at least `saleFloorBps` (10,000 at launch) of the cost. `controller.priceOf(sid)` returns the asking price now, never below that floor and, once the owner sets the balance token pool (`setBalancePoolKey`), never below the statement's redeemable value in eth: `rating * unit` balance token base units priced at the pool's sqrt price, with `unit` the lower of the stored and the live `unitPerPoint()`. `controller.atFloor(sid)` is true when the curve price, without the value floor, has reached its floor (`floorBps` of the reference); the Core reads it to gate `redeemStatement`.

the owner can pause sales on the Core (`core.setPaused(bool)`, effective at once, unpaused at launch). `core.paused()` reports the state. while paused `core.sellTo` and `core.sellCreditTo` revert `Paused()`, so `buy` reverts, and `priceOf` keeps answering. the age a price falls with, `core.statementAge(sid)`, excludes every paused second, so a pause holds the age of each held statement and the fall continues from the same age at the resume. a statement composed during a pause starts aging at the resume. the anchor decays with wall time in a pause, so the start price of a held statement follows it. composing, the eth bid, redemptions, buybacks and fees run in a pause.

1. `controller.priceOf(sid)` returns the price in wei, and `controller.grossPriceOf(sid)` the amount `buy` takes (the price plus the royalty). `NotForSale` for a statement that is not held. the price falls with time and rises when the anchor rises, so a price read in an earlier block can be too low by the time the transaction lands. an indexer reads the anchor now from `controller.anchorBps()`. `storedAnchorBps()` and `anchorTime()` are the anchor at its last change.
2. `controller.buy{value: v}(sid)` with `v` at least `grossPriceOf(sid)`, the quote from `priceOf` plus the royalty (`royaltyBps` of it, 250 at launch). a buy earlier in the same block can raise the price, and the call then reverts `Underpaid`. the controller records the sale at the asking price, forwards the asking price to the Core, owes the royalty to `royaltyRecipient` (`claimRoyalty()` pays it, anyone may call) and refunds any excess of `v` to the caller last. the controller calls `core.sellTo(sid, buyer)`, which sends the statement to the buyer and books the payment at once: `saleToBuybackBps` to the coin buyback pot, the rest to `ethPot`.
3. events `StatementSoldTo(sid, buyer, price, toBuyback)` on the Core, `AnchorMoved(sid, saleBps, anchorBps)` and `Bought(sid, buyer, price)` on the controller. read `controller.anchorBps()` and `controller.startBps()` for the level the next statement starts from. `AnchorMoved` is emitted only by a buy above the anchor.
4. buyers read `core.paused()` before a `buy`. a paused Core reverts every `sellTo` with `Paused()`, as the first check after the controller check, so the `buy` reverts with it. `PausedSet(bool paused)` is emitted by the Core on each change of the state, and a call that repeats the current state emits nothing.

### credit sale window

`controller.creditSaleOn()` is false at launch. while it is true every pile credit is for sale from its acquisition time (`core.creditInfo(id)`: `inPile`, cost, `acquiredAt`).

1. `controller.creditPrice(id)` returns the price in wei. `floor = max(cost, baseline, backstop) * creditFloorBps / 10,000` (11,000 at launch) and `start = floor * creditStartBps / 10,000` (30,000 at launch). the price falls in a straight line from `start` at `acquiredAt` to `floor` at `acquiredAt + creditWindow` (14,400 seconds at launch) and rests at `floor` after. `baseline` is the credit's score times the lower of the stored and the live `unitPerPoint` priced at the balance token pool key and only lifts the floor: it is 0 while no balance module is set, no pool key is set, the pool price reads zero or the live `unitPerPoint` read fails, so the price never reverts for a missing or failed pool read. `backstop` is `core.floorRate()` (the larger of the climbed eth bid rate and the remembered peak) times `max(1, score / refScore)`, so a credit scored above `refScore` floors proportionally higher and a credit at or below it floors at the unscaled floor rate. `NotForSale` is the only revert, for a credit that is not in the pile. the price changes with the floor rate, so a quote read in an earlier block can move by the time the transaction lands.
2. `controller.buyCredit{value: v}(id)` and `controller.buyCredits{value: v}(ids)` with `v` at least `grossCreditPrice(id)`, the price plus the royalty (the sum of the gross prices for a batch, each credit priced after the previous sale). they revert `CreditSaleOff` while the sale is off, `Paused` while sales are paused, `Underpaid` for a short `v`, and refund the excess last. the controller calls `core.sellCreditTo(id, buyer)`, which requires the payment to be at least the credit's cost (`BelowFloor`), sends the credit to the buyer, books `creditCostToPotBps` of the cost (10,000 at launch) to `ethPot` and the rest of the payment to the coin buyback pot, and emits `CreditSold(id, buyer, price)`.
3. a credit that sits past its window is composed by `compose` or `composeChosen`. with the sale off, a credit composes at once.

## 7. booking, fund and collectEscrow

the pool pushes the bounty leg of its fees to the Core with the 2,300 gas stipend. `receive()` accepts eth from the hook and the fee escrow and reverts `UseFund` for any other sender.

* income is the Core balance above `ethPot + ethToBuyback + ethRedeemBurn + payeeOwed`. `book()` (anyone) and the start of every eth pot door book it (`sellForEth` in both forms, `buyListing`, `compose`, `composeChosen`, `adopt`, `redeemStatement`, `buyback`, `sellTo`, `sellCreditTo`): the payee share (`payeePpm`, from the first book at or after the launch time of the factory record plus the anti sniper window) to `payeeOwed`, `feeToRedeemBurnBps` of the rest to the redeem burn reserve (`ethRedeemBurn`), the remainder to `ethPot`. event `FeesAdded`.
* `fund()` (payable, anyone) books the pending income, then adds `msg.value` to `ethPot`. event `Funded`.
* `collectEscrow()` (anyone) books, then claims the eth credit of the Core in the fee escrow into `ethPot`. it reverts with the escrow's error when nothing is owed. event `EscrowCollected`.
* `claimPayee()` (anyone) sends `payeeOwed` to `payee`. `ZeroAmount` when nothing is owed, `CallFailed` when the payee refuses.
* the gas of the book is part of the gas counted for the caller payment of `compose`, `composeChosen` (section 5) and `buyListing` (section 4). `sellForBalance` and `bookBalance` read no eth price. `core.payee()`, `core.payeeOwed()` and `core.payeeOn()` report the payee state, and the eth above the booked pots and the payee claim is the pending income that `book()` books.

## 8. adopt

`adopt(uint256[] ids)`, callable by anyone. it records credits that were sent to the Core with a plain transfer (`Credits.transferFrom(owner, core, id)` or a safe transfer) so they enter the pile.

sequence:

1. transfer the credits to the Core. a transferred credit has no record and is not in the pile. compose pages draw from the pile, so the credit joins a page once it is adopted. the owner can send it out with `rescueNft`.
2. call `core.adopt(ids)`.

the call, in order: the booking of section 7, so pending fee eth is booked before the price is read. `Empty` for an empty list. for each id: `ZeroId`, `InPile` when the credit is in the pile (the same id twice in a call included), `NotHolder` when another address holds it (an id that does not exist reverts inside Credits). the credit enters the pile with the arrival time of the block. event `CreditAdopted(id, cost)`.

the cost basis is `core.ethPrice()`, at least 1 wei: the price state per credit at that moment before the clamp. the price state is what the engine pays with a funded pot, so a statement built from adopted credits is priced at that level. the read after the clamp of a thin pot would book a basis of 1 wei and the statement price would collapse with it. a donor who inflates the basis of a statement only loses the credits.

the basis is booked and the pile grows. eth, the rate state and the pots keep their values apart from the fee pull. the order of the pile is the order of the ids. a statement composed from adopted credits costs the sum of their bases.

a successor Core (section 9) receives credits without records and adopts them the same way. `adopt` reverts `Retired` on a Core that has run `migrate`, so a credit that left through `migrate` is adopted by the successor.

## 9. migrate and rescue (owner only)

| call | what it does | reverts |
|---|---|---|
| `setSuccessor(address)` | names the contract that `migrate` sends to. zero or an address with code other than the Core, the balance module, the balance token, the fee source, the coin, Credits or Statements | `OnlyOwner`, `Locked("successor")`, `NoCode`, `BadSuccessor` |
| `lockSuccessor()` | closes `setSuccessor` permanently. allowed while the successor is zero, which disables `migrate` | `OnlyOwner` |
| `migrate(maxCredits)` | the first call sets `retired` (view `retired()`, event `EngineRetired`). moves in batches: `ethPot` by one plain call, `balancePot` by `transfer`, up to `maxCredits` from the head of the pile by `transferFrom`. `ethToBuyback` and `ethRedeemBurn` stay in the Core. a balance token `transfer` that reverts or returns false leaves `balancePot` in the Core, logs `BalanceTokenMigrationSkipped(successor, amount)` and the other legs go on (`Migrated` shows 0 balance tokens). the held statements and their records stay in the Core | `OnlyOwner`, `NoSuccessor`, `Reentrancy`, `CallFailed` |
| `rescueCoin(to, amount)` | sends coin the Core holds to `to`. coin an allowlisted holder sent to the Core is the only coin it holds | `OnlyOwner`, `ZeroAddress` |
| `rescueNft(token, id, to)` | sends an ERC721 the Core holds to `to`: a credit only while it is outside the pile, a statement only while the Core has no record of it, any other ERC721 freely | `OnlyOwner`, `ZeroAddress`, `InPile`, `Held`, `NotHolder` |

what a successor has to implement: a `fund()` that accepts eth, and a balance token and Credits that it accepts by `transfer` and `transferFrom`, so the `onERC721Received` of the successor is skipped. `migrate` transfers eth, balance token and credits. the old Core is retired by the first `migrate`; an integrator that sells credits to a Core reads `core.retired()` first. `sellForEth`, `buyListing`, `sellForBalance`, `adopt`, `compose` and `composeChosen` revert `Retired`, and `retired()` reads true. it keeps its statements and sells them out itself, so `buy` and `redeemStatement` still work there, and call `migrate` again to move the proceeds, until it moves nothing. it keeps `sellTo`, `sellCreditTo`, `book` and `buyback`, and books the fees that still arrive. `buyback` there burns the `ethToBuyback` that stayed at the migration and whatever later fees and redemptions add. `redeemStatement` there repays its caller from what is left in `ethPot`, capped at the pot, so the repayment is often 0 after a `migrate`. move the pool's bounty recipient to the successor with `setBountyRecipient` on the hook (as the coin admin) before the first `migrate`: a Core that stays the recipient books every later fee. `maxCredits` bounds the credits moved per call, and 0 moves the pots only. the successor builds its pile with `adopt`.

## 10. reading the engine

a frontend multicalls these views. the Core, and the controller at `core.controller()`.

| view | returns |
|---|---|
| `core.ethRate()` | the bid per credit (wei) a `sellForEth` pays now: the price state lowered to the booked pot plus the pot share of the unbooked fee income |
| `core.ethPrice()` | the price state before the pot clamp |
| `core.floorRate()` | the larger of the price state and the remembered peak |
| `core.pileSize()`, `core.pilePage(startAfter, n)` | size of the pile and its credit ids, oldest first |
| `core.creditInfo(id)` | `inPile`, cost basis and `acquiredAt` of a credit |
| `core.statementInfo(sid)`, `core.statementAge(sid)`, `core.ratingOf(sid)` | held flag, cost and compose time of a statement, its age outside pauses, its stored rating |
| `core.composerOf(sid)`, `core.heldStatements()` | the caller that composed a statement, every statement the Core holds |
| `core.settings()` | every economic setting |
| `controller.priceOf(sid)`, `grossPriceOf(sid)`, `referenceOf(sid)` | asking price of a held statement, the price plus the royalty, and the price reference |
| `controller.creditPrice(id)`, `grossCreditPrice(id)` | the credit sale price and the price plus the royalty |
| `controller.atFloor(sid)`, `pastWindow(acquiredAt)`, `nextPage()` | the redemption gate, the compose window gate, and the next page of 80 credits |
| `controller.pointRate()`, `valueOf(points)` | the eth value per point and of a score |

the pots, the locks, the payee state and the other scalars are the public getters of the Core (`ethPot`, `ethToBuyback`, `ethRedeemBurn`, `balancePot`, `payee`, `payeeOwed`, `payeeOn`, `controller`, `successor`, `retired`, `paused` and the four locks).

## 11. events

the Core (`src/interfaces/ICore.sol`):

| event | fields | emitted when |
|---|---|---|
| `Buyback` | `address indexed caller, uint256 amountIn, uint256 paid` | `buyback`: `amountIn` eth swapped for coin and the coin burned, `paid` to `caller`: counted gas at the base fee plus the keeper fee |
| `Composed` | `uint256 indexed sid, uint256[80] ids, uint8 format, uint256 cost, address indexed caller` | `compose` or `composeChosen`. `ids` the 80 credits, `format` the Statements format, `cost` the cost basis of the statement (the sum of the bases of the 80 credits) |
| `ControllerLocked` | (empty) | `lockController` |
| `ControllerSet` | `address controller` | `setController` (also at construction) |
| `CreditAdopted` | `uint256 indexed id, uint256 cost` | `adopt`, one per credit. `cost` is the cost basis written |
| `CreditBought` | `uint256 indexed id, address indexed from, uint256 cost` | one per credit of `sellForEth` or `sellForBalance`. `cost` is the cost basis in eth: the payout for `sellForEth`, and for `sellForBalance` the floor rate times `score / refScore`, read from no pool (section 3) |
| `CreditSold` | `uint256 indexed id, address indexed buyer, uint256 price` | `sellCreditTo` (the controller `buyCredit` path): the credit went to `buyer` for `price` |
| `CreditCostToPotBpsSet` | `uint16 bps` | the owner set the share of a sold credit's cost booked to `ethPot` |
| `ChosenComposeOnSet` | `bool on` | the owner switched chosen composition |
| `MinCcToChooseSet` | `uint96 min` | the owner set the least coin balance of a chosen compose and a held format change |
| `HeldFormatSet` | `uint256 indexed sid, uint8 format, address indexed caller` | a holder of `minCcToChoose` coin set the format of a held statement |
| `EthRateFill` | `uint256 spent, uint256 rate, uint256 pot` | every spend from `ethPot`: `spent`, the price state after the drop (`rate`) and the pot after the spend |
| `BalanceModuleLocked` | (empty) | `lockBalanceModule` |
| `BalanceModuleSet` | `address balanceModule, address balanceToken, uint256 unitPerPoint` | `setBalanceModule` |
| `RedeemBurnReleased` | `uint256 amount` | `releaseRedeemBurn`: `amount` moved from the redeem burn reserve (`ethRedeemBurn`) into the coin buyback pot (`ethToBuyback`) |
| `FeesAdded` | `uint256 amount` | `_book` booked fee income: the payee share to `payeeOwed`, `feeToRedeemBurnBps` of the rest to the redeem burn reserve, the remainder to `ethPot`. `amount` is the income less the payee share |
| `Funded` | `address indexed from, uint256 amount` | `fund` added eth to the pot |
| `EscrowCollected` | `uint256 amount` | `collectEscrow` claimed the escrow credit of the Core into the pot |
| `PayeeSet` | `address indexed payee` | the owner set the payee |
| `PayeeClaimed` | `address indexed payee, uint256 amount` | `claimPayee` paid the payee |
| `ListingBought` | `uint256 indexed id, address indexed adapter, address indexed caller, uint256 cost, uint256 paid, uint256 rate` | `buyListing`. `cost` is the eth the adapter quoted and the Core sent, `paid` the payment to the caller, `rate` the price state after the fill. the cost basis of the credit is `cost + paid` |
| `EngineRetired` | `address indexed successor` | the first `migrate`, once. the Core refuses the six doors from then on |
| `Migrated` | `address indexed successor, uint256 eth, uint256 balanceTokens, uint256 credits` | `migrate`: eth moved (`ethPot`), balance token moved (`balancePot`), credits moved |
| `BalanceTokenMigrationSkipped` | `address indexed successor, uint256 amount` | `migrate`: the balance token `transfer` of `amount` (`balancePot`) reverted or returned false. `balancePot` stays in the Core, the other legs went through |
| `CoinRescued` | `address indexed to, uint256 amount` | `rescueCoin` |
| `NftRescued` | `address indexed token, uint256 indexed id, address indexed to` | `rescueNft` |
| `OwnershipTransferStarted` | `address indexed owner, address indexed pending` | the owner named `pending` |
| `OwnershipTransferred` | `address indexed from, address indexed to` | `acceptOwnership` completed (also at construction, from the zero address) |
| `RateSet` | `uint256 rate` | the owner restated the eth rate (wei per credit) |
| `SettingsSet` | `Settings settings` | the owner set every setting |
| `BalanceBooked` | `uint256 amount` | `bookBalance` added balance token held above `balancePot` to `balancePot` |
| `StatementRedeemed` | `uint256 indexed sid, uint256 received` | `redeemStatement` handed the statement on (the balance side). `received` is the balanceToken that came back |
| `StatementSoldTo` | `uint256 indexed sid, address indexed buyer, uint256 price, uint256 toBuyback` | `sellTo` (the controller `buy` path): the statement went to `buyer` for `price`, booked at once: `toBuyback` to the coin buyback pot, the rest to `ethPot` |
| `SuccessorLocked` | (empty) | `lockSuccessor` |
| `SuccessorSet` | `address successor` | `setSuccessor` |
| `AdapterSet` | `address indexed adapter, bool allowed` | `addAdapter`, `removeAdapter` and the constructor (the launch adapters) |
| `AdaptersLocked` | (empty) | `lockAdapters` |

the controller (`src/interfaces/IControllerV1.sol`):

| event | fields | emitted when |
|---|---|---|
| `Bought` | `uint256 indexed sid, address indexed buyer, uint256 price` | `buy`: `buyer` paid `price` and received statement `sid` |
| `AnchorMoved` | `uint256 indexed sid, uint256 saleBps, uint32 anchorBps` | `buy`: the sale price in bps of the reference and the new anchor |
| `AnchorBpsSet` | `uint32 anchorBps` | the owner set the anchor, or a lower `startCapBps` lowered it |
| `RoyaltyClaimed` | `address indexed to, uint256 amount` | `claimRoyalty` paid the royalty owed |
| `SaleSet` | `Sale sale` | `setSale`: the owner set the seven sale settings at once |
| `CreditSaleSet` | `CreditSale credit` | `setCredit`: the owner set the credit sale, `refScore` and the royalty at once |
| `PausedSet` (Core) | `bool paused` | the owner paused or resumed sales. not emitted by a call that repeats the state |
| `BalancePoolKeySet` | `address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks` | `setBalancePoolKey`: the owner set the balance token pool that prices the redeemable value floor |

## 12. reverts

the Core. an error named here is declared in `ICore`, and the ones raised inside `CoreLib` carry the same selectors.

| error | raised by | meaning |
|---|---|---|
| `AboveBid()` | `buyListing` | the quoted `value` is above `ethRate()` |
| `AlreadyOwned()` | `buyListing` | the Core already owns the credit |
| `BadCost()` | `buyListing` | the eth balance fell by more than `value` |
| `BadFormat()` | `compose(format)`, `composeChosen`, `setHeldFormat` | the format is above 7 |
| `BelowMinCc()` | `composeChosen`, `setHeldFormat` | the caller holds less coin than `minCcToChoose` |
| `ChosenComposeOff()` | `composeChosen` | chosen composition is off |
| `InWindow(uint256 id)` | `composeChosen` | the newest named credit (`id`) is inside its window while the credit sale is on |
| `BadModule()` | `setBalanceModule`, `redeemStatement`, `sellForBalance` | the module is rejected, or its `unitPerPoint()` read fails, returns short, returns 0 or exceeds a uint128. a redemption and the bid read the unit in the call and revert on a failed, short, zero or oversized read |
| `BadRate()` | `setRate`, constructor | the rate is outside its bounds |
| `BadSender()` | `onERC721Received` | an ERC721 other than Credits or Statements was safe transferred to the Core |
| `BadSetting(bytes32 field)` | `setSettings`, `setCreditCostToPotBps`, `setSale`, `setCredit`, constructor | the setting `field` is outside its bounds |
| `BadStack()` | constructor | a stack value is invalid |
| `BadStatement()` | `compose`, `composeChosen` | Statements returned an id, holder or credit count other than expected |
| `BadSuccessor(address who)` | `setSuccessor` | the address is the Core or a contract the Core works with (`who`) |
| `BadSwap()` | `buyback` | the pool swap result is out of bounds |
| `BelowFloor()` | `sellTo`, `sellCreditTo` | `msg.value` is below the hard floor: `cost * saleFloorBps / 10_000` for a statement, the credit's cost for a credit |
| `CallFailed()` | `buyListing`, `migrate` | the target call reverted, or the successor refused the eth |
| `Empty()` | `sellForEth`, `sellForBalance`, `adopt` | an empty id list |
| `BalanceTokenChanged()` | `setBalanceModule` | the module names another balanceToken |
| `ForbiddenTarget()` | `addAdapter`, `buyListing` | the address is a contract the Core refuses to approve or to call |
| `Held()` | `rescueNft` | the statement is on the books of the Core |
| `InPile()` | `adopt`, `rescueNft` | the credit is in the pile |
| `Locked(bytes32 what)` | owner setters | the door `what` (`controller`, `balanceModule`, `adapters`, `successor`) is locked |
| `NoCode(address who)` | constructor, `setSuccessor` | the address has no code |
| `NoCredit()` | `buyListing` | the target call did not deliver exactly the credit `id` to the Core |
| `NoBalanceModule()` | `redeemStatement`, `sellForBalance`, `lockBalanceModule` | no balance module is set |
| `NoSuccessor()` | `migrate` | the successor is zero |
| `Retired()` | `sellForEth`, `buyListing`, `sellForBalance`, `adopt`, `compose`, `composeChosen` | the Core ran `migrate` |
| `NotHeld()` | `compose`, `composeChosen`, `redeemStatement` | the Core does not hold the credit of the page, or has no record of the statement |
| `NotHolder()` | `adopt`, `rescueNft` | the Core is not the holder of the token |
| `NotInPile(uint256 id)` | `compose`, `composeChosen`, `sellCreditTo` | the credit `id` is not in the pile (a controller page that names one, a chosen compose that names one or names one twice, a credit sale of one) |
| `NotOwner()` | `sellForEth`, `sellForBalance` | the caller does not own the credit |
| `NotReady()` | `compose` | the controller reports no page, or the read fails |
| `NothingBought()` | `buyback` | the swap bought no coin |
| `NothingToBuy()` | `buyback` | the buyback pot `ethToBuyback` is empty |
| `OnlyController()` | `sellTo`, `sellCreditTo` | the caller is not the controller |
| `OnlyOwner()` | owner functions | the caller is not `owner` |
| `OnlyPendingOwner()` | `acceptOwnership` | the caller is not the pending owner |
| `OnlyPoolManager()` | `unlockCallback` | the caller is not the pool manager |
| `PotTooSmall()` | `sellForEth`, `buyListing`, `sellForBalance` | the spend is larger than the pot |
| `Reentrancy()` | guarded functions | a guarded function was entered while another guarded call runs |
| `SliceTooSmall()` | `buyback` | the slice is under twice the largest payment to the caller: 600,000 gas at the capped base fee plus `keeperFee` |
| `Slippage()` | `sellForEth`, `sellForBalance` | total payout below `minOut` |
| `AdapterNotAllowed()` | `buyListing` | the adapter is not approved |
| `BadQuote()` | `buyListing`, `sellForBalance` | the adapter reverted, ran out of gas or answered with fewer than three words or more than 8,192 bytes, or the controller gave no nonzero `refScore()` |
| `NotForSale()` | `sellTo`, `setHeldFormat` | the Core does not hold the statement |
| `NotEligible()` | `redeemStatement` | the statement's curve price has not reached its floor (`atFloor` is false), or the controller did not answer |
| `RedeemOff()` | `redeemStatement` | `redeemOn` is false |
| `BalanceBidOff()` | `sellForBalance` | `balanceBidOn` is false |
| `TooSoon()` | `buyback` | fewer than `buybackDelay` blocks since the last buyback |
| `Underpaid()` | `redeemStatement` | the module returned less balanceToken than `rating * unitPerPoint * (10_000 - redeemSlippageBps) / 10_000` |
| `ZeroAddress()` | constructor, `rescueCoin`, `rescueNft`, `setController` | a zero address argument |
| `ZeroAmount()` | `sellForEth`, `sellForBalance`, `releaseRedeemBurn`, `claimRoyalty` | a spend of 0: the bid is 0 for that credit (empty pot, or a zero balance token price), the redeem burn reserve or the amount is 0, or no royalty is owed |
| `ZeroId()` | `sellForEth`, `buyListing`, `adopt` | credit id 0 |

the controller:

| error | raised by | meaning |
|---|---|---|
| `BadSetting(bytes32 field)` | sale and credit setters, constructor, `setBalancePoolKey` | the setting `field` is outside its bounds, or (`setBalancePoolKey`) no balance token is set, `currency0` is not native eth, `currency1` is not the balance token or the pool is not initialized |
| `NotForSale()` | `buy`, `priceOf`, `referenceOf`, `atFloor`, `creditPrice`, `buyCredit`, `buyCredits` | the statement is not held, or the credit is not in the pile |
| `OnlyOwner()` | sale and credit setters and `setBalancePoolKey` on the controller, `setPaused` on the Core | the caller is not `core.owner()` |
| `Paused()` | `core.sellTo`, `core.sellCreditTo`, and through them `buy`, `buyCredit`, `buyCredits` | sales are paused (`core.paused()`) |
| `CreditSaleOff()` | `buyCredit`, `buyCredits` | the credit sale window is off |
| `Reentrant()` | `buy`, `buyCredit`, `buyCredits` | a sale door was entered again |
| `Underpaid()` | `buy`, `buyCredit`, `buyCredits` | `msg.value` is below `grossPriceOf(sid)` or the gross credit price |

the Core also raises `UseFund()` from `receive()` for a sender other than the hook and the fee escrow.

## 13. gas

measured on the pinned fork with foundry 1.8.1. `tx` includes the intrinsic 21,000 and the calldata, `exec` is the gas inside the call. forge reports a call after the EIP-3529 refund, which is up to 20 percent of the gas for a call that clears many records. the gas limit of a transaction has to cover the gas before the refund. the transaction cap is 16,777,216. the compose rows were measured before decision 84 added the rating read and store at compose, and the lens rows before its per statement reads; both are not re-measured at the tip. the gas rows of `composeChosen`, `buyCredit`, `buyCredits` and `sellCreditTo` are pending.

| call | gas | pinned by |
|---|---|---|
| `sellForEth`, 1 credit, cold | tx 378,496 | `test/GasCap.t.sol` `test_gas_sellForEth_batch_launchSettings` |
| `sellForEth`, each further credit | 143,854 | the same test (fit over 1 to 40 credits) |
| `sellForEth`, largest batch under the cap | 114 credits, tx 16,659,539 | the same test |
| `buyListing` through the CreditStrategy adapter | tx 439,537 | `test/GasCap.t.sol` `test_gas_buyListing_creditStrategy` |
| `buyListing` through the CreditStrategy adapter, 1 eth of unbooked income | tx 454,789 | `test_gas_buyListing_creditStrategy_incomeLoaded` |
| `buyListing` through the Seaport adapter, basic order | tx 428,672 | `test_gas_buyListing_seaport_basic` |
| `buyListing` through the Seaport adapter, basic order with a fee recipient | tx 469,028 | `test_gas_buyListing_seaport_basicWithFee` |
| `compose()`, 80 credits, first compose | tx 8,491,518 after the refund, 10.60 million before it (refund 2.12 million) | `test/GasCap.t.sol` `test_gas_compose_ethLane_firstCold`, `test/CallerPay.t.sol` |
| `compose()`, second compose | tx 8,452,306 | `test_gas_compose_ethLane_secondWarmAndCold` |
| `book()` with the payee share on | tx 88,442 | `test_gas_book` |
| `book()` that turns the payee share on (reads the factory record) | tx 189,009 | `test_gas_book_firstAfterTheWindow` |
| `fund()` with income to book | tx 120,039 | `test_gas_fund` |
| `collectEscrow()` | tx 96,859 | `test_gas_escrowClaim_collect_rescue` |
| `ControllerV1.nextPage`, full pile, cold | 238,062 (the Core allows 500,000) | `test_gas_readCaps_nextPage` |
| `controller.buy` (the `sellTo` path) | tx 177,648 | `test_gas_sellTo_throughControllerBuy` |
| `buyback` after a statement sale | tx 241,420 | `test_gas_buyback_afterAStatementSale` |
| `buyback` | exec 238,032, counted for the refund 258,586 | `test/Fees.t.sol` `test_callerIsPaidCountedGasAtTheBaseFeePlusTheFee` |
| `adopt`, 1 credit | call gas 199,532 | `test/Adopt.t.sol` `test_GAS_adopt` (asserted within 5 percent) |
| `adopt`, 80 credits | call gas 7,660,657 (95,758 per credit) | the same test |
| `migrate`, pots only | call gas 159,226 | `test/Migrate.t.sol` `test_GAS_migrateOneSixtyCredits` |
| `migrate`, the credits of the pile | call gas 8,022,084 (44,772 per credit), measured with two piles of 80 before decision 92 | `test/Migrate.t.sol` `test_GAS_migrateOneSixtyCredits` logs the current figure for 160 credits in the one pile |

## 14. interface files

generated from the production abi by `script/tools/gen-interfaces.sh`, which `--check` compares with the committed files.

| file | contract |
|---|---|
| `src/interfaces/ICore.sol` | `Core`: functions, events and errors |
| `src/interfaces/IControllerV1.sol` | `ControllerV1` |
| `src/interfaces/ICoreLib.sol` | `CoreLib`: the view functions of the library and `swapIn`. the Core forwards its owner functions, `sellForBalance` and `adopt` to the library under the same selectors, so a caller uses `ICore` for them |

hand written shared types and external interfaces: `src/interfaces/Interfaces.sol` (`Settings`, `Stack`, `Sale`, `Credit`, Credits, Statements and the `Mainnet` constants), and `src/interfaces/ArtCoinsV2.sol` (the v2 stack).
