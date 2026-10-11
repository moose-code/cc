# integration

for integrators and keepers: the contracts, the call sequences of each door, the events, the reverts and the measured gas. the rules behind the numbers are in docs/ARCHITECTURE.md (the bid, the doors, the settings) and docs/FLOW.md (the decisions). the owner commands are in docs/DEPLOY.md.

units. a rate is wei per credit. every credit has the same price, the rate. a `Lane` is 0 for the eth lane and 1 for the exit lane. bps is out of 10,000, ppm out of 1,000,000. settings values quoted below are the launch values of `script/config/mainnet.json`; `core.settings()` returns the live ones.

## 1. contracts and addresses

| contract | address | where to read it |
|---|---|---|
| Credits | 0x97630aA70AB14ed9883B41dAfccBc11349723043 | constant `Mainnet.CREDITS` |
| Statements | 0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b | constant `Mainnet.STATEMENTS` |
| CreditStrategy | 0x8e607209899b5d12Bd3167a6CD0E8E11FEB053d6 | allowed target of `buyListing` at launch |
| Seaport 1.6 | 0x0000000000000068F116a894984e2DB1123eB395 | allowed target of `buyListing` at launch |
| pool manager | 0x000000000004444c5dc75cB358380D2e3dE08A90 | uniswap v4, holds the coin pool |
| Core | the `core` line of the `Deploy` output | custody and every rule |
| coin | `core.COIN()` | launched through the artcoins v2 factory |
| controller | `core.controller()` | ControllerV1 at launch. the owner can replace it until `lockController` |
| fee router | `core.FEE_SOURCE()` | the bounty recipient of the pool |
| lens | the `lens` line of the `Deploy` output, or the CREATE2 address derived from the Core | `CoreLens`. `lens.CORE()` names the Core it reads |
| exitModule, exitToken | `core.exitModule()`, `core.exitToken()` | zero until the owner sets them |

the record of a launch is the output of `script/Deploy.s.sol` (core, coin, controller, router, lens), the broadcast file `broadcast/Deploy.s.sol/1/run-latest.json`, and the table that `script/Postflight.s.sol` prints after reading every address back (docs/DEPLOY.md steps 6 and 9). a keeper needs the Core address and reads the rest from it. the lens address is a function of the Core (CREATE2 through the deterministic deployer, salt `keccak256("credits.core.lens.v1")`, the Core as constructor argument), which `Postflight` derives from `CORE`.

## 2. quoting a credit

| question | call |
|---|---|
| the eth a seller receives now for a credit | `core.ethRate()` (the snapshot field `ethRate`) |
| the price state before the clamp of a thin pot | `core.ethPrice()` |

a batch sold through `sellForEth` is paid credit by credit. after each credit the rate falls by `dropPerCreditBps` (50, which is 0.5 percent) and stays at or above `dropFloorBps` (5,000) of the price state at the first fill of the current minute, so the total of a batch of `n` credits is below `n * ethRate`. the quote of the first credit is exact for the state of the block the transaction runs in. the pull of fees (section 7) runs first and can raise the pot, which can only raise the read, so the first credit is paid `ethRate` or more. `minOut` is the floor on the total.

## 3. door 1: sell credits for eth

`sellForEth(uint256[] ids)` and `sellForEth(uint256[] ids, uint256 minOut)`. the first form is the second with `minOut` 0.

sequence for a seller:

1. approve the Core once: `Credits.setApprovalForAll(core, true)`, or `Credits.approve(core, id)` per credit.
2. quote with `core.ethRate()` and set `minOut` below the expected total.
3. call `core.sellForEth(ids, minOut)` from the owner of every credit in `ids`.

what the call does, in order:

1. `CoreLib.pullFees(router)`: the Core calls `router.flush()` with at most 1,000,000 gas and ignores the outcome. fee eth reaches `ethPot` before any price is read.
2. reverts `Empty` for an empty list.
3. for each id: the caller must own the credit (`ZeroId`, `NotOwner`). the price is the rate now. the spend is checked against the pot (`PotTooSmall`, `ZeroAmount`). the rate falls. the credit enters the eth pile with the price as its cost basis. `Credits.transferFrom(caller, core, id)`. event `CreditBought(id, caller, 0, price)`.
4. `Slippage` when the total is below `minOut`.
5. the total goes to the caller in one eth transfer, last. a contract caller needs a `receive()` that accepts eth.

what the caller receives: the total payout.

the batch size is bounded by the transaction gas cap: the largest batch under 16,777,216 gas is 115 credits at the launch settings (section 13).

`sellForExitToken(ids)` and `(ids, minOut)` are the phase 2 door (docs/ARCHITECTURE.md section 5).

## 4. door 2: buy a listed credit through an allowed marketplace

`buyListing(uint256 value, bytes data, uint256 id, address target)`. the caller supplies the complete calldata for the marketplace and is paid from `ethPot` for the gas of the call. the Core pays with its own eth and the credit arrives at the Core.

sequence for a keeper:

1. find a listing of credit `id` on an allowed target: Seaport 1.6 or the CreditStrategy at launch (`core.allowedTarget(target)`).
2. check the room: `price <= core.ethRate()` and `price <= core.ethPot()`.
3. build the calldata that makes the target deliver `id` to the Core. for Seaport the recipient of the order is the Core. for the CreditStrategy the call is `sellTargetNFT(id)` with `value` equal to `nftForSale(id)`. `test/GasCap.t.sol` runs a basic order, a basic order with a fee recipient, an advanced order and the CreditStrategy.
4. call `core.buyListing(value, data, id, target)`. `value` is the eth the Core forwards, at most the ceiling.

what the call does, in order:

1. the fee pull of section 7, before anything is measured.
2. `TargetNotAllowed` when the target is not allowed or is a forbidden contract. `ZeroId`. `AlreadyOwned` when the Core owns the credit. `PotTooSmall`, `AboveCeiling` (value above `ethRate()`).
3. the Core calls `target` with `value` and `data`. `CallFailed` when it reverts. during the call the router cannot flush into the Core (`Measuring`), so the pull waits for the next door.
4. the Core checks that exactly one credit arrived and that it is `id` (`NoCredit`), that the eth balance fell (`BadCost`) and that the fall is at most `value` (`BadCost`). the fall is the cost, so a target that refunds part of `value` lowers the cost, and a consideration item that the caller appends to a Seaport order is paid from `value` and counts as cost.
5. the payment is `min(min(counted gas, BUYLISTING_GAS) * min(block.basefee, keeperMaxBaseFee) + keeperFee, ceiling - cost)`, paid to the caller last. counted gas is the gas measured from the first line of `buyListing` (the fee pull included) plus 250,000 for the work after the count, the transaction base cost and calldata. `BUYLISTING_GAS` is 1,500,000. `keeperFee` is paid whole. the base fee is used and the priority fee is not refunded. the cap `ceiling - cost` is the bid less the listing cost, and the bid is at most `ethPot`, so cost plus payment never exceeds the bid.
6. `cost + payment` is spent from the pot and is the cost basis of the credit. event `ListingBought(id, target, caller, cost, paid, rate)`.

keeper economics: the caller's profit is the payment plus anything it appends to the order for itself, less its own gas cost at the base fee plus its priority fee. the caller writes the target calldata. Seaport lets the fulfiller append consideration items (or additional recipients in a basic order) that the seller signature does not cover. the Core pays them from `value` and they count as `cost`, so the fastest caller can add itself as a recipient and take up to the whole gap `ceiling - cost` between the bid and the listing price. the engine pays at most its bid for the credit, the same outcome as buying the listing on Seaport and selling the credit with `sellForEth` at the bid, and competing callers bid priority fees for whole gaps. a caller that appends nothing is paid the payment of step 5: a gap above the full payment pays counted gas plus `keeperFee`. counted gas exceeds the gas of the transaction by 19,000 to 31,000 on the measured paths, so that caller earns `keeperFee` plus that margin at the base fee, less its priority fee. a smaller gap pays the whole gap, so the caller profits when the gap exceeds its gas cost. at 2 gwei and no priority fee a basic Seaport order costs the caller about 0.00086 eth, so the payment alone breaks even at a gap of that size (10 percent under the opening bid of 0.0089 eth) and a gap above 0.0014 eth pays about 0.00054 eth net (`test/Seaport.t.sol` `SeaportCallerPayTest`).

## 5. compose

`compose()` for the eth lane and `composeExit()` for the exit lane. anyone may call. the controller decides the page: `ControllerV1.nextPage(lane)` is ready when the lane pile holds 80 credits and returns the 80 oldest with format 0. `lens.snapshot().ethPageReady` reports it.

what the call does:

1. the fee pull of section 7.
2. `NotReady` when the controller reports no page. `BadFormat` for a format above 7.
3. the 80 credits leave the pile (`NotInPile`, `NotHeld`) and go to `Statements.compose`. `BadStatement` when the result is not the next statement id held by the Core with 80 credits.
4. the statement is booked with the sum of the cost bases of its 80 credits. holders of the coin and people in the project compose, and the owner composes when nobody does.
5. event `Composed(sid, lane, format, cost, caller)`. the statement stays in the Core with its compose time (`statementInfo(sid)`).
6. the caller payment, last. `min(counted gas, 13,700,000) * min(block.basefee, callerMaxBaseFee) + callerFee`, from `ethPot`, at most `ethPot`. counted gas is the gas measured from the first line of the body, which includes the fee pull, plus 60,000 for the transaction base cost and the work after the measured part. `callerFee` and `callerMaxBaseFee` are 0 at launch, so the payment is 0 and no eth moves. the owner turns it on with `setSettings`. the payment goes to `msg.sender`, so a contract caller needs a `receive()` that accepts eth. `exitStatement` pays its caller by the same rule and the same two settings, with a gas bound of 1,500,000 and 50,000 of overhead. the transfer is the last action of the door and the Core is locked against re entry while it runs.

send at least 12,000,000 gas: the live Statements contract needs about 8.7 million for 80 credits, and the gas the transaction needs is the gas before the refund of the cleared credit records, 10.6 million, or 11.1 million with a loaded fee router of four gas burning payees (section 13).

## 6. statements: buying

a statement stays in the Core after compose and sells only through `ControllerV1.buy`. `lens.snapshot().statements` lists every held statement with its lane, cost, compose time and `askingPrice`. the asking price of a statement of cost `c` at `age` seconds since its compose is `c * price / 10,000`, with `price` in bps of cost falling at a fixed rate and changing every second: `start` less `fastDecayBpsPerHour` (100) per hour while above `kneeBps` (10,000), then `kneeBps` less `slowDecayBpsPerHour` (25) per hour from the second the knee is reached, never below `floorBps` (7,500). a `start` at or below `kneeBps` falls at the slow rate from compose. at the launch anchor the price is 15,000 at compose, 10,000 at hour 50, 9,000 at hour 90 and 7,500 from hour 150. `start` is `controller.startBps()`, which is `min(anchorBps * markupBps / 10,000, startCapBps)`, 15,000 at the launch anchor of 10,000. `anchorBps` is the running level of sale prices in bps of cost. a `buy` of a statement whose cost is at least `controller.anchorMinCost()` (0.1 eth at launch, an owner setting from 0 to 10 eth) and whose sale price in bps of cost is above the anchor sets it to the mean of the anchor now and the sale price, at most `startCapBps` (100,000). every other `buy` completes and leaves the anchor and `anchorTime` unchanged. the part of the anchor above 10,000 halves every `anchorHalfLife` (604,800 seconds, 7 days at launch), continuously, so the anchor falls with time and `controller.anchorBps()` returns the value now. the price is computed from the age, the anchor now and the current settings at every call, so the price of a held statement rises when another statement sells above the anchor, falls as the anchor decays, and changes at once when the owner changes `markupBps`, `startCapBps`, `anchorHalfLife`, `anchorMinCost`, either rate, `kneeBps`, `floorBps` or `saleFloorBps`. `sellTo` takes at least `saleFloorBps` (7,500) of the cost, and `controller.priceOf(sid)` returns the asking price now, never below that floor.

1. `controller.priceOf(sid)` returns the price in wei. `NotForSale` for a statement that is not held or is on the exit lane. the price falls with time and rises when the anchor rises, so a price read in an earlier block can be too low by the time the transaction lands. an indexer reads the anchor now from `controller.anchorBps()`. `storedAnchorBps()` and `anchorTime()` are the anchor at its last change.
2. `controller.buy{value: v}(sid)` with `v` at least the quote from `priceOf`. a buy earlier in the same block can raise the price, and the call then reverts `Underpaid`. the controller records the sale at the asking price and refunds any excess of `v` to the caller last. the controller calls `core.sellTo(sid, buyer)`, which sends the statement to the buyer and books the payment at once: `saleToBuybackBps` to the coin buyback pot, the rest to `ethPot`.
3. events `StatementSoldTo(sid, buyer, price, toBuyback)` on the Core, `AnchorMoved(sid, saleBps, anchorBps)` and `Bought(sid, buyer, price)` on the controller. read `controller.anchorBps()` and `controller.startBps()` for the level the next statement starts from. `AnchorMoved` is emitted only by a buy above the anchor.

## 7. the fee pull and flush()

the pool sends fee eth to the fee router. the router holds it until `flush()`:

* anyone may call. `amount = balance - totalOwed`.
* while the split is on (`splitOn`, from `splitStart`), each payee receives `amount * ppm / 1_000_000` with 100,000 gas. a share that fails is recorded in `owed` and paid by `claim(payee)`.
* the rest goes to the engine, the Core, whose `receive()` books it: `feeToBuybackBps` to the coin buyback pot, the rest to `ethPot`. `FlushFailed` when the engine refuses it, and the fees stay in the router. `NoEngine` while no engine is set. an empty balance returns early.

the Core pulls the fees itself. `sellForEth` (both forms), `buyListing`, `compose`, `composeExit` and `adopt` call `flush()` first. the gas of the flush is part of the gas counted for the caller payment of `compose`, `composeExit` (section 5) and `buyListing` (section 4). `CoreLib.pullFees` uses at most 1,000,000 gas and ignores a failing router. `adopt` pulls as well, before it reads the price. `sellForExitToken`, `exitStatement`, `sellTo`, `skim` and `buyback` read no eth price and book on their own schedule. `lens.snapshot()` reports what a flush would send now: `flushToCore` and `flushToPayees`.

## 8. adopt

`adopt(uint256[] ids)`, callable by anyone. it records credits that were sent to the Core with a plain transfer (`Credits.transferFrom(owner, core, id)` or a safe transfer) so they enter the eth pile.

sequence:

1. transfer the credits to the Core. a transferred credit has no record and sits in no pile. compose pages draw from the piles, so the credit joins a page once it is adopted. the owner can send it out with `rescueNft`.
2. call `core.adopt(ids)`.

the call, in order: the fee pull of section 7, so pending router eth is booked before the price is read `Empty` for an empty list. for each id: `ZeroId`, `InPile` when the credit is in a pile (the same id twice in a call included), `NotHolder` when another address holds it (an id that does not exist reverts inside Credits). the credit enters the eth pile with the arrival time of the block. event `CreditAdopted(id, cost)`.

the cost basis is `core.ethPrice()`, at least 1 wei: the price state per credit at that moment before the clamp. the price state is what the engine pays with a funded pot, so a statement built from adopted credits is priced at that level. the read after the clamp of a thin pot would book a basis of 1 wei and the statement price would collapse with it. a donor who inflates the basis of a statement only loses the credits.

the basis is booked and the eth pile grows. eth, the rate state and the pots keep their values apart from the fee pull. the order of the pile is the order of the ids. a statement composed from adopted credits costs the sum of their bases.

a successor Core (section 9) receives credits without records and adopts them the same way. `adopt` reverts `Retired` on a Core that has run `migrate`, so a credit that left through `migrate` is adopted by the successor.

## 9. migrate and rescue (owner only)

| call | what it does | reverts |
|---|---|---|
| `setSuccessor(address)` | names the contract that `migrate` sends to. zero or an address with code other than the Core, the exit module, the exit token, the fee source, the coin, Credits or Statements | `OnlyOwner`, `Locked("successor")`, `NoCode`, `BadSuccessor` |
| `lockSuccessor()` | closes `setSuccessor` permanently. allowed while the successor is zero, which disables `migrate` | `OnlyOwner` |
| `migrate(maxCredits)` | the first call sets `retired` (view `retired()`, event `EngineRetired`). moves in batches: `ethPot` by one plain call, `xPot` by `transfer`, up to `maxCredits` from the head of each pile by `transferFrom`. `ethToBuyback` and `xToBuyback` stay in the Core. an exit token `transfer` that reverts or returns false leaves `xPot` in the Core, logs `ExitTokenMigrationSkipped(successor, amount)` and the other legs go on (`Migrated` shows 0 exit tokens). the held statements and their records stay in the Core | `OnlyOwner`, `NoSuccessor`, `Reentrancy`, `CallFailed` |
| `rescueCoin(to, amount)` | sends coin the Core holds to `to`. coin an allowlisted holder sent to the Core is the only coin it holds | `OnlyOwner`, `ZeroAddress` |
| `rescueNft(token, id, to)` | sends an ERC721 the Core holds to `to`: a credit only while it is outside both piles, a statement only while the Core has no record of it, any other ERC721 freely | `OnlyOwner`, `ZeroAddress`, `InPile`, `Held`, `NotHolder` |

what a successor has to implement: a `receive()` that accepts a plain eth call, and an exit token and Credits that it accepts by `transfer` and `transferFrom`, so the `onERC721Received` of the successor is skipped. `migrate` transfers eth, exit token and credits. the old Core is retired by the first `migrate`; an integrator that sells credits to a Core reads `core.retired()` first. `sellForEth`, `buyListing`, `sellForExitToken`, `adopt`, `compose` and `composeExit` revert `Retired`, and `retired()` reads true. it keeps its statements and sells them out itself, so `buy` and `exitStatement` still work there, and call `migrate` again to move the proceeds, until it moves nothing. it keeps `sellTo`, `skim`, `buyback` and `buybackExit`, and books the fees that still arrive. `buybackExit` there sells the `xToBuyback` that stayed at the migration and whatever later exits add. `exitStatement` there repays its caller from what is left in `ethPot`, capped at the pot, so the repayment is often 0 after a `migrate`. point the fee router at the successor with `router.setEngine` before the first `migrate`: the retired Core calls no `flush`. `maxCredits` applies to each pile, and 0 moves the pots only. the successor builds its pile with `adopt`.

## 10. the lens

`CoreLens` (`src/CoreLens.sol`) holds immutable pointers and reads state only.

| call | returns |
|---|---|
| `snapshot()` | the `Snapshot` struct below, with every held statement. the struct has no `retired` field: read `core.retired()` |
| `statementsPage(start, n)` | `StatementView[]` for the held statements `start` to `start + n`, in the order of `core.heldStatements()` |
| `controller()` | the controller of the Core now |
| `CORE()`, `ROUTER()`, `CREDITS()`, `STATEMENTS()` | the pointers |

| `Snapshot` field | meaning |
|---|---|
| `ethRate` | the bid per credit as the Core reads it for a sale |
| `ethPrice` | the price state before the clamp |
| `ethPileSize`, `ethPileHead`, `exitPileSize`, `exitPileHead` | size and oldest credit of each pile |
| `ethPageReady`, `exitPageReady` | the controller answers `nextPage` for the lane with a ready flag and the full answer size (82 words) that `compose` requires |
| `ethPot`, `ethToBuyback`, `xPot`, `xToBuyback` | the four pots. `ethToBuyback` leaves only through a `buyback()` whose swap completes: a pool or hook failure reverts the call and the pot stays |
| `unbookedEth` | Core balance above the booked pots. `skim()` books it |
| `routerBalance`, `routerOwed` | eth in the router, and the part owed to payees |
| `flushToCore`, `flushToPayees` | what `flush()` sends now |
| `controller`, `successor` | the addresses now |
| `controllerLocked`, `exitModuleLocked`, `targetsLocked`, `successorLocked` | the four one way locks |
| `statements` | `StatementView[]` |

| `StatementView` field | meaning |
|---|---|
| `id`, `lane`, `cost` | statement id, lane and cost basis |
| `composedAt` | the compose time. an eth lane statement may exit after `composedAt + exitAfter` |
| `askingPrice` | the controller's `priceOf(id)` in wei for an eth lane statement. 0 for an exit lane statement and for a controller that does not answer |

`snapshot()` costs about 120,000 gas plus 25,000 per held statement. a list of several hundred statements exceeds the gas that a public node allows for one `eth_call`, so a keeper reads them with `statementsPage` in pages of a few hundred.

## 11. events

the Core (`src/interfaces/ICore.sol`):

| event | fields | emitted when |
|---|---|---|
| `Buyback` | `address indexed caller, uint256 amountIn, uint256 paid` | `buyback`: `amountIn` eth swapped for coin and the coin burned, `paid` to `caller`: counted gas at the base fee plus the keeper fee |
| `Composed` | `uint256 indexed sid, Lane lane, uint8 format, uint256 cost, address indexed caller` | `compose` or `composeExit`. `lane` 0 or 1, `format` the Statements format, `cost` the cost basis of the statement (the sum of the bases of the 80 credits) |
| `ControllerLocked` | (empty) | `lockController` |
| `ControllerSet` | `address controller` | `setController` (also at construction) |
| `CreditAdopted` | `uint256 indexed id, uint256 cost` | `adopt`, one per credit. `cost` is the cost basis written |
| `CreditBought` | `uint256 indexed id, address indexed from, Lane lane, uint256 cost` | one per credit of `sellForEth` or `sellForExitToken`. `lane` 0 is the eth lane, 1 the exit lane. `cost` is the payout and the cost basis |
| `EthRateFill` | `uint256 spent, uint256 rate, uint256 pot` | every spend from `ethPot`: `spent`, the price state after the drop (`rate`) and the pot after the spend |
| `ExitBuyback` | `address indexed caller, uint256 slice, uint256 coinIn` | `buybackExit` (phase 2): `slice` sold to `caller` for `coinIn` coin, which is burned |
| `ExitModuleLocked` | (empty) | `lockExitModule` |
| `ExitModuleSet` | `address exitModule, address exitToken, uint256 unitPerCredit` | `setExitModule` |
| `ExitRateFill` | `uint256 rate, uint256 pot` | phase 2 spend of the exit pot by `sellForExitToken`: the exit rate and the pot after |
| `FeesAdded` | `uint256 amount` | `receive()` booked a flush of the fee router: `feeToBuybackBps` of it to the coin buyback pot, the rest to `ethPot` |
| `ListingBought` | `uint256 indexed id, address indexed target, address indexed caller, uint256 cost, uint256 paid, uint256 rate` | `buyListing`. `cost` is the eth the target took, `paid` the payment to the caller, `rate` the price state after the fill. the cost basis of the credit is `cost + paid` |
| `EngineRetired` | `address indexed successor` | the first `migrate`, once. the Core refuses the six doors from then on |
| `Migrated` | `address indexed successor, uint256 eth, uint256 exitTokens, uint256 credits` | `migrate`: eth moved (`ethPot`), exit token moved (`xPot`), credits moved |
| `ExitTokenMigrationSkipped` | `address indexed successor, uint256 amount` | `migrate`: the exit token `transfer` of `amount` (`xPot`) reverted or returned false. `xPot` stays in the Core, the other legs went through |
| `CoinRescued` | `address indexed to, uint256 amount` | `rescueCoin` |
| `NftRescued` | `address indexed token, uint256 indexed id, address indexed to` | `rescueNft` |
| `OwnershipTransferStarted` | `address indexed owner, address indexed pending` | the owner named `pending` |
| `OwnershipTransferred` | `address indexed from, address indexed to` | `acceptOwnership` completed (also at construction, from the zero address) |
| `RateSet` | `uint256 rate` | the owner restated the eth rate (wei per credit) |
| `SettingsSet` | `Settings settings` | the owner set every setting |
| `Skimmed` | `uint256 eth, uint256 exitToken` | `skim` booked eth and exitToken the Core held above the recorded pots |
| `StatementExited` | `uint256 indexed sid, Lane lane, uint256 received` | `exitStatement` handed the statement on (phase 2). `received` is the exitToken that came back |
| `StatementSoldTo` | `uint256 indexed sid, address indexed buyer, uint256 price, uint256 toBuyback` | `sellTo` (the controller `buy` path): the statement went to `buyer` for `price`, booked at once: `toBuyback` to the coin buyback pot, the rest to `ethPot` |
| `SuccessorLocked` | (empty) | `lockSuccessor` |
| `SuccessorSet` | `address successor` | `setSuccessor` |
| `TargetAdded` | `address target` | `addTarget` (Seaport and CreditStrategy at construction) |
| `TargetRemoved` | `address target` | `removeTarget` |
| `TargetsLocked` | (empty) | `lockTargets` |

the controller (`src/interfaces/IControllerV1.sol`):

| event | fields | emitted when |
|---|---|---|
| `Bought` | `uint256 indexed sid, address indexed buyer, uint256 price` | `buy`: `buyer` paid `price` and received statement `sid` |
| `AnchorMoved` | `uint256 indexed sid, uint256 saleBps, uint32 anchorBps` | `buy`: the sale price in bps of cost and the new anchor |
| `AnchorBpsSet` | `uint32 anchorBps` | the owner set the anchor, or a lower `startCapBps` lowered it |
| `AnchorHalfLifeSet` | `uint32 anchorHalfLife` | sale setting changed |
| `AnchorMinCostSet` | `uint128 anchorMinCost` | sale setting changed |
| `FastDecayBpsPerHourSet` | `uint16 fastDecayBpsPerHour` | sale setting changed |
| `KneeBpsSet` | `uint32 kneeBps` | sale setting changed |
| `SlowDecayBpsPerHourSet` | `uint16 slowDecayBpsPerHour` | sale setting changed |
| `FloorBpsSet` | `uint16 floorBps` | sale setting changed |
| `MarkupBpsSet` | `uint16 markupBps` | sale setting changed |
| `StartCapBpsSet` | `uint32 startCapBps` | sale setting changed |

the fee router (`src/interfaces/IFeeRouter.sol`):

| event | fields | emitted when |
|---|---|---|
| `Claimed` | `address indexed payee, uint256 amount` | `claim` paid an owed share |
| `EngineSet` | `address indexed previous, address indexed engine` | the owner set the engine |
| `Flushed` | `address indexed engine, uint256 toEngine, uint256 toPayees` | `flush`: `toEngine` sent to the engine (the Core), `toPayees` shared (paid or owed) |
| `Locked` | `address indexed engine` | the owner locked the router settings |
| `OwnershipTransferStarted` | `address indexed owner, address indexed pendingOwner` | the router owner named `pendingOwner` |
| `OwnershipTransferred` | `address indexed previousOwner, address indexed newOwner` | the router owner changed |
| `PayeeOwed` | `address indexed payee, uint256 amount` | a payee share failed to send (100,000 gas limit) and is recorded in `owed` for `claim` |
| `PayeePaid` | `address indexed payee, uint256 amount` | a payee share was sent |
| `PayeesSet` | `address[] payees, uint32[] ppm` | the owner set the payee list and the shares in ppm |
| `SplitStartSet` | `uint64 at` | the owner set the split start time |
| `SplitStarted` | `uint256 at` | the first flush at or after the split start turned the split on |

## 12. reverts

the Core. an error named here is declared in `ICore`, and the ones raised inside `CoreLib` carry the same selectors.

| error | raised by | meaning |
|---|---|---|
| `AboveCeiling()` | `buyListing` | `value` is above `ethRate()` |
| `AlreadyOwned()` | `buyListing` | the Core already owns the credit |
| `BadCost()` | `buyListing` | the eth balance did not fall, or fell by more than `value` |
| `BadFormat()` | `compose` | the controller returned a format above 7 |
| `BadModule()` | `setExitModule` | the module is rejected |
| `BadRate()` | `setRate`, constructor | the rate is outside its bounds |
| `BadSender()` | `onERC721Received` | an ERC721 other than Credits or Statements was safe transferred to the Core |
| `BadSetting(bytes32 field)` | `setSettings` | the setting `field` is outside its bounds |
| `BadStack()` | constructor | a stack value is invalid |
| `BadStatement()` | `compose` | Statements returned an id, holder or credit count other than expected |
| `BadSuccessor(address who)` | `setSuccessor` | the address is the Core or a contract the Core works with (`who`) |
| `BadSwap()` | `buyback` | the pool swap result is out of bounds |
| `BelowFloor()` | `sellTo` | `msg.value` is below the hard floor `cost * saleFloorBps / 10_000` |
| `CallFailed()` | `buyListing`, `migrate` | the target call reverted, or the successor refused the eth |
| `Empty()` | `sellForEth`, `sellForExitToken`, `adopt` | an empty id list |
| `ExitTokenChanged()` | `setExitModule` | a replacement module names another exitToken |
| `ForbiddenTarget()` | `addTarget` | the target is a contract the Core refuses to call |
| `Held()` | `rescueNft` | the statement is on the books of the Core |
| `InPile()` | `adopt`, `rescueNft` | the credit is in a pile |
| `Locked(bytes32 what)` | owner setters | the door `what` (`controller`, `exitModule`, `targets`, `successor`) is locked |
| `Measuring()` | `receive` | the fee router sent eth while a measured external call of the Core was running |
| `NoCode(address who)` | constructor, `setSuccessor` | the address has no code |
| `NoCredit()` | `buyListing` | the target call did not deliver exactly the credit `id` to the Core |
| `NoExitModule()` | phase 2 functions | no exit module is set |
| `NoSuccessor()` | `migrate` | the successor is zero |
| `Retired()` | `sellForEth`, `buyListing`, `sellForExitToken`, `adopt`, `compose`, `composeExit` | the Core ran `migrate` |
| `NotHeld()` | `compose`, `exitStatement` | the Core does not hold the credit of the page, or has no record of the statement |
| `NotHolder()` | `adopt`, `rescueNft` | the Core is not the holder of the token |
| `NotInPile(uint256 id)` | `compose` | the controller named a credit that is not in the lane pile (`id`) |
| `NotOwner()` | `sellForEth`, `sellForExitToken` | the caller does not own the credit |
| `NotReady()` | `compose`, `composeExit` | the controller reports no page, or the read fails |
| `NothingBought()` | `buyback` | the swap bought no coin |
| `NothingToBuy()` | `buyback`, `buybackExit` | the buyback pot is empty |
| `OnlyController()` | `sellTo` | the caller is not the controller |
| `OnlyOwner()` | owner functions | the caller is not `owner` |
| `OnlyPendingOwner()` | `acceptOwnership` | the caller is not the pending owner |
| `OnlyPoolManager()` | `unlockCallback` | the caller is not the pool manager |
| `PotTooSmall()` | `sellForEth`, `buyListing`, `sellForExitToken` | the spend is larger than the pot |
| `Reentrancy()` | guarded functions | a guarded function was entered while another guarded call runs |
| `SliceTooSmall()` | `buyback` | the slice is under twice the largest payment to the caller: 600,000 gas at the capped base fee plus `keeperFee` |
| `Slippage()` | `sellForEth`, `sellForExitToken`, `buybackExit` | total payout below `minOut`, or the coin cost above `maxCoinIn` |
| `TargetNotAllowed()` | `buyListing` | the target is not on the allowlist, or it is a forbidden contract |
| `NotForSale()` | `sellTo` | the Core does not hold the statement, or it is on the exit lane |
| `TooEarly()` | `exitStatement` | the eth lane statement was composed less than `exitAfter` ago |
| `TooSoon()` | `buyback` | fewer than `buybackDelay` blocks since the last buyback |
| `Underpaid()` | `exitStatement` | the module returned less than the credit count times the unit |
| `ZeroAddress()` | constructor, `rescueCoin`, `rescueNft`, `setController` | a zero address argument |
| `ZeroAmount()` | `sellForEth` | a spend of 0 wei: the bid is 0 (empty pot) for that credit |
| `ZeroId()` | `sellForEth`, `buyListing`, `adopt` | credit id 0 |

the controller:

| error | raised by | meaning |
|---|---|---|
| `BadSetting(bytes32 field)` | sale setters, constructor | the setting `field` is outside its bounds |
| `NotForSale()` | `buy`, `priceOf` | the statement is not held, or is on the exit lane |
| `OnlyOwner()` | sale setters | the caller is not `core.owner()` |
| `Reentrant()` | `buy` | `buy` was entered again |
| `Underpaid()` | `buy` | `msg.value` is below `priceOf(sid)` |

the fee router:

| error | raised by | meaning |
|---|---|---|
| `BadPayees()` | `setPayees` | more than 4 payees, a zero address, a zero share, or a total above 200,000 ppm |
| `ClaimFailed()` | `claim` | the payee refused the eth |
| `FlushFailed()` | `flush` | the engine refused the eth |
| `IsLocked()` | owner setters | the router is locked |
| `NoCode(address account)` | `setEngine` | the engine has no code (`account`) |
| `NoEngine()` | `flush`, `lock` | no engine is set |
| `NothingOwed()` | `claim` | the payee is owed nothing |
| `OnlyOwner()` | owner setters | the caller is not the router owner |
| `OnlyPendingOwner()` | `acceptOwnership` | the caller is not the pending owner |
| `Reentered()` | `flush`, `claim` | the router was entered again |
| `SplitIsOn()` | `setSplitStart` | the split already started |
| `ZeroAddress()` | setters | a zero address |

## 13. gas

measured on the pinned fork with foundry 1.8.1. `tx` includes the intrinsic 21,000 and the calldata, `exec` is the gas inside the call. forge reports a call after the EIP-3529 refund, which is up to 20 percent of the gas for a call that clears many records. the gas limit of a transaction has to cover the gas before the refund. the transaction cap is 16,777,216.

| call | gas | pinned by |
|---|---|---|
| `sellForEth`, 1 credit, cold | tx 429,897 | `test/GasCap.t.sol` `test_gas_sellForEth_batch_launchSettings` |
| `sellForEth`, each further credit | 142,066 | the same test (fit over 1 to 40 credits) |
| `sellForEth`, largest batch under the cap | 115 credits, tx 16,659,842 | the same test |
| `sellForEth`, 1 credit, router empty, call gas | 344,241 | `test/PullFees.t.sol` `test_gasOfThePullOnOneCredit` |
| `sellForEth`, 1 credit, router holds 1 eth, call gas | 404,992 | the same test |
| `flush`, most expensive case (four payees that burn all their gas) | 639,876 | `test/PullFees.t.sol` `test_worstCaseFlushGasAndTheDoorCompletes` |
| `flush` with the split on, two payees | tx 139,228 | `test/GasCap.t.sol` `test_gas_routerFlush` |
| `flush` that turns the split on | tx 104,997 | `test/GasCap.t.sol` `test_gas_routerFlush_firstAtSplitStart` |
| `buyListing` through the CreditStrategy | tx 436,005 | `test/GasCap.t.sol` `test_gas_buyListing_creditStrategy` |
| `buyListing` through the CreditStrategy, router holding 1 eth | tx 471,684 | `test_gas_buyListing_creditStrategy_routerLoaded` |
| `buyListing` through the CreditStrategy, router holding 1 eth, four gas burning payees (the largest; `BUYLISTING_GAS` is 1.59 times its transaction gas) | tx 946,013 | `test_gas_buyListing_creditStrategy_routerWorstCaseFlush` |
| `buyListing` through Seaport, basic order | tx 448,223 | `test_gas_buyListing_seaport_basic` |
| `buyListing` through Seaport, basic order with a fee recipient | tx 485,554 | `test_gas_buyListing_seaport_basicWithFee` |
| `buyListing` through Seaport, advanced order | tx 462,112 | `test_gas_buyListing_seaport_advanced` |
| `compose()`, eth lane, 80 credits, first compose | tx 8,484,004 after the refund, 10.60 million before it (refund 2.12 million), 11.1 million before it with a loaded router of four gas burning payees | `test/GasCap.t.sol` `test_gas_compose_ethLane_firstCold`, `test/CallerPay.t.sol` |
| `compose()`, second compose | tx 8,444,792 | `test_gas_compose_ethLane_secondWarmAndCold` |
| `composeExit()`, 80 credits | tx 8,467,837 | `test_gas_composeExit_andExitStatement_exitLane` |
| `ControllerV1.nextPage`, full eth pile, cold | 238,062 (the Core allows 500,000) | `test_gas_readCaps_nextPage` |
| `controller.buy` (the `sellTo` path) | tx 177,648 | `test_gas_sellTo_throughControllerBuy` |
| `buyback` after a statement sale | tx 234,500 | `test_gas_buyback_afterAStatementSale` |
| `buyback` | exec 238,032, counted for the refund 258,586 | `test/Fees.t.sol` `test_callerIsPaidCountedGasAtTheBaseFeePlusTheFee` |
| `adopt`, 1 credit, router empty | call gas 199,532 | `test/Adopt.t.sol` `test_GAS_adopt` (asserted within 5 percent) |
| `adopt`, 80 credits, router empty | call gas 7,660,657 (95,758 per credit) | the same test |
| `migrate`, pots only | call gas 159,226 | `test/Migrate.t.sol` `test_GAS_migrateEightyCreditsPerPile` |
| `migrate`, 80 credits per pile | call gas 8,022,084 (44,772 per credit) | the same test |
| `lens.snapshot()` | 120,041 with no statements, 25,201 more per statement | `test/Lens.t.sol` `test_GAS_snapshotPerStatement` |

## 14. interface files

generated from the production abi by `script/tools/gen-interfaces.sh`, which `--check` compares with the committed files.

| file | contract |
|---|---|
| `src/interfaces/ICore.sol` | `Core`: functions, events and errors |
| `src/interfaces/IControllerV1.sol` | `ControllerV1` |
| `src/interfaces/IFeeRouter.sol` | `FeeRouter` |
| `src/interfaces/ICoreLens.sol` | `CoreLens` with the `Snapshot` and `StatementView` structs |
| `src/interfaces/ICoreLib.sol` | `CoreLib`: the pure and view functions of the library and `swapIn`. the Core forwards its owner functions, `sellForExitToken` and `adopt` to the library under the same selectors, so a caller uses `ICore` for them |

hand written shared types and external interfaces: `src/interfaces/Interfaces.sol` (`Lane`, `Settings`, `Stack`, `Sale`, Credits, Statements and the `Mainnet` constants), and `src/interfaces/ArtCoinsV2.sol` (the v2 stack).
