# integration

for keepers, bots and frontends. the rules are in docs/SPEC.md; this file is the call surface. the interfaces are generated from the abi: src/interfaces/ICore.sol, IControllerV1.sol, ISeaportBasicAdapter.sol, ICreditStrategyAdapter.sol, IListingAdapter.sol.

## 1. contracts

| name | how to find it |
|---|---|
| Core | the launch record in docs/STATUS.md; `COIN()`, `HOOK()`, `controller()`, `balanceModule()`, `payee()` are views on it |
| ControllerV1 | `core.controller()` |
| SeaportBasicAdapter, CreditStrategyAdapter | the launch record; `core.allowedAdapter(a)` says whether one is approved |
| Credits 0x97630aA70AB14ed9883B41dAfccBc11349723043, Statements 0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b, CreditStrategy 0x8e607209899b5d12Bd3167a6CD0E8E11FEB053d6, Seaport 1.6 0x0000000000000068F116a894984e2DB1123eB395 | fixed |

## 2. reading the engine

one multicall over these views answers everything a seller, a buyer or a keeper decides on.

| view | answers |
|---|---|
| `core.ethRate()` | the bid for a credit of score `refScore` now, with the unbooked fees counted into the pot |
| `core.bidOf(id)` | the bid for credit `id` now: `ethRate()` times its score over `refScore`, the number a seller or keeper uses |
| `core.ethPrice()`, `core.floorRate()` | the price state before the pot clamp; the rate under every price floor |
| `core.climbMultiplier()` | the pot scaled multiplier now, bps (10,000 is 1x, up to `climbMultiplierCapBps`, launch 40,000 is 4x): the pages of 80 credits the pot covers at the current rate, clamped to [1x, the cap]. the ceiling's idle loosening runs this many times as fast (the per minute climb is unscaled). show it when above 1x ("pot covers 3 pages, ceiling loosening 3x") |
| `core.ethPot()`, `core.ethToBuyback()`, `core.ethRedeemBurn()` | the eth pots |
| `IBalanceModule(core.balanceModule()).available()` | the balance token the module commits to the bid (the Core holds none) |
| `core.balanceRate()` | the balance token bid now, bps of par (par is a credit's `score * unitPerPoint`): the rising balance bid lowered to `available()` as bps of par, at most 10,000 |
| `core.balanceBidOf(id)` | the balance token payout for credit `id` now: `score * unitPerPoint * balanceRate() / 10,000` |
| `core.pileSize()`, `core.pilePage(startAfter, n)`, `core.creditInfo(id)` | the pile, oldest first, with cost and acquisition time |
| `core.heldStatements()`, `core.statementInfo(sid)`, `core.statementAge(sid)`, `core.ratingOf(sid)`, `core.composerOf(sid)` | the held statements |
| `controller.nextPage()` | whether a page is ready for `compose` |
| `controller.priceOf(sid)`, `controller.referenceOf(sid)`, `controller.atFloor(sid)` | the asking price `buy` takes, the reference, redemption eligibility |
| `controller.creditPrice(id)`, `controller.pastWindow(acquiredAt)`, `controller.creditSaleOn()` | the credit sale window |
| `controller.pointRate()`, `controller.valueOf(points)`, `controller.anchorBps()`, `controller.startBps()` | the pricing inputs |
| `core.settings()`, `core.paused()`, `core.retired()`, the lock flags, `core.chosenComposeOn()`, `core.minCcToChoose()` | the switches |

## 3. selling credits for eth

1. read `core.bidOf(id)` for each credit (or `core.ethRate()` and scale by `score / refScore`) and `core.ethPot()`.
2. `credits.setApprovalForAll(core, true)` once.
3. `core.sellForEth(ids, minOut)` pays `core.bidOf(id)` = `ethRate() * score / refScore` per credit; set `minOut` a little under the sum of `bidOf` over the ids (each credit drops the rate by `dropPerCreditBps * score / refScore` for the next). the eth arrives in the same call. a batch whose total passes the pot reverts whole (`ZeroAmount` or `PotTooSmall`); up to about 91 credits fit under the gas cap (each credit reads its score).

reverts: `Empty`, `ZeroId`, `NotOwner`, `ZeroAmount`, `PotTooSmall`, `Slippage`, `Retired`. event `CreditBought(id, from, cost)` per credit, `EthRateFill(spent, rate, pot)` per fill.

## 4. sweeping a listing

`core.buyListing(adapter, id, params)`. the adapter prices the listing from its own data; the engine pays the listing and pays the caller the gas at the base fee (capped at `keeperMaxBaseFee`, 1,500,000 gas) plus `keeperFee`, at most the gap between the bid and the listing.

| adapter | `params` | reverts of the adapter |
|---|---|---|
| SeaportBasicAdapter | `abi.encode(BasicOrderParameters)` of a Seaport 1.6 basic order: Credits as offer token, `id`, amount 1, native consideration, an open order type, every additional recipient the offerer or allowlisted (`allowedRecipient(a)`) | `WrongToken`, `WrongId`, `WrongAmount`, `NotNative`, `ZeroPrice`, `RestrictedOrder`, `RecipientNotAllowed(recipient)` |
| CreditStrategyAdapter | empty | `NotForSale` when `nftForSale(id)` is 0 |

reverts of the Core: `AdapterNotAllowed`, `ZeroId`, `AlreadyOwned`, `BadQuote` (the adapter reverted or answered badly; an adapter's own revert surfaces as `BadQuote`), `ForbiddenTarget`, `ZeroAmount`, `PotTooSmall`, `AboveBid`, `CallFailed`, `NoCredit`, `BadCost`, `Retired`. event `ListingBought(id, adapter, caller, cost, paid, rate)`.

a listing whose price is above the bid is not swept; a holder sells it with `sellForEth` instead. a hook push landing inside the target call (a swap in a callback) is fee income at the next book.

## 5. composing

`controller.nextPage()` ready means 80 credits wait (and, while the credit sale is on, the newest is past its window). `core.compose()` composes them with a random format, `core.compose(format)` with the given one. `core.composeChosen(ids, format)` composes 80 credits the caller names (requires `chosenComposeOn`, a CC balance of at least `minCcToChoose`, every credit past its window). the caller pays the gas, about 8.5 million after refunds; the payment settings are `callerMaxBaseFee` 3 gwei and `callerFee` 0.0003 eth at launch (decision 131), about 0.026 eth per page at or above 3 gwei. `core.setHeldFormat(sid, format)` restyles a held statement for a holder of `minCcToChoose` CC.

reverts: `NotReady`, `BadFormat`, `NotInPile(id)`, `NotHeld`, `BadStatement`, `ChosenComposeOff`, `BelowMinCc`, `InWindow(id)`, `NotForSale` (restyle of an unheld statement), `Retired`. events `Composed(sid, ids, format, cost, price, caller)`, `HeldFormatSet(sid, format, caller)`.

## 6. buying statements and credits

- a statement: read `controller.priceOf(sid)` and send at least that to `controller.buy(sid)`. the controller forwards the price to the Core, which takes the artist cut (`saleToArtistBps`, 250 at launch) and the operator cut (`saleToOperatorBps`, 50 at launch) off the payment and pushes them to the artist and the payee; the controller refunds the excess. reverts `NotForSale`, `Underpaid`, `Reentrant`, and through the Core `Paused`, `BelowFloor`. events `Bought(sid, buyer, price)`, `AnchorMoved(sid, saleBps, anchorBps)`, `StatementSoldTo(sid, buyer, price, toBuyback, toArtist, toOperator)`.
- a pile credit, while `creditSaleOn`: `controller.creditPrice(id)` to `controller.buyCredit(id)`, or `buyCredits(ids)` with the sum. the Core takes the two cuts off each payment. reverts `CreditSaleOff`, `NotForSale`, `Underpaid`, `Reentrant`, `Paused`, `BelowFloor`. event `CreditSold(id, buyer, price, toArtist, toOperator)`.
- the artist and operator cuts are pushed during the sale, there is no claim. the owner sets the artist with `core.setArtist(to)` (event `ArtistSet`, the zero address refused while `saleToArtistBps` is nonzero) and the cut bps with `setSettings`.

## 7. fees, booking and funding

fees reach the Core from the pool's hook on every swap and are booked at the next door. `core.book()` books them now (a keeper calls it at the end of the anti sniper window, launch plus 30 minutes). `core.fund()` payable adds eth to the pot whole. `core.collectEscrow()` claims the Core's fee escrow credit into the pot. the payee share is pushed by the book, not claimed. the balance token is held by the module, not the Core, so there is no balance booking door. a plain send to the Core reverts `UseFund`. events `FeesAdded(amount, toPayee)`, `Funded(from, amount)`, `EscrowCollected(amount)`.

## 8. the buyback

`core.buyback()`, anyone, once per `buybackDelay` blocks while `ethToBuyback` holds at least twice the largest payment. the caller is paid the gas at the base fee (capped at `keeperMaxBaseFee`, 600,000 gas) plus `keeperFee` scaled by the eth spent. reverts `NothingToBuy`, `TooSoon`, `SliceTooSmall`, `NothingBought`, `BadSwap`. event `Buyback(caller, amountIn, paid)`.

## 9. the balance side

the module holds the balance token; the Core holds none. its interface adds `available()` (the token it commits to the bid) and `pay(to, amount)` (the Core only). at launch `redeemOn` is true, `balanceBidOn` is false and no module is set, so `redeemStatement` reverts `NoBalanceModule`. `core.redeemStatement(sid)` for a held statement with `controller.atFloor(sid)` true leaves its proceeds in the module; reverts `BadModule` when the module's holding rises by less than `rating * unit * (10,000 - redeemSlippageBps) / 10,000`. `core.sellForBalance(ids, minOut)` pays `score * unitPerPoint * core.balanceRate() / 10,000` in balance token per credit from the module, the rising balance bid (SPEC section 4): the rate climbs in bps of par toward the 10,000 cap, floors at `10,000 - balanceBidMarginBps`, clamps to `available()` as bps of par, and drops per credit. read `core.balanceBidOf(id)` for each credit and set `minOut` a little under the sum (each credit drops the rate for the next). the batch total must fit `available()` in base units and the seller's holding must rise by the total, else it reverts `NoBalanceModule`, `BalanceBidOff`, `Empty`, `BadModule`, `ZeroAmount`, `PotTooSmall`, `Slippage`, `Retired`. with the bid off and `redeemOn`, redemptions keep filling the module (the accumulate mode). events `StatementRedeemed(sid, received)`, `CreditBought(id, from, cost)`, `BalanceRateFill(spent, rateBps, available)` per credit sold into the balance bid.

## 10. adopt, migrate, rescue

`core.adopt(ids)` puts credits the Core holds without a record into the pile (anyone). the owner's `migrate(maxCredits)` sends the eth pot and credits to the successor and retires the engine (`Retired` from the buying and composing doors after it); the successor takes the eth through `fund()`; the balance token is held by the module, not the Core, so migrate has no balance leg. `rescueCoin` and `rescueNft` are owner only; `rescueNft` reverts `NoCreditRescue` for Credits in every state, and a credit sent to the Core leaves through `adopt` and the doors. events `CreditAdopted`, `Migrated`, `EngineRetired`, `CoinRescued`, `NftRescued`.

`core.swapCredit(inId, outId)` swaps a pile credit `outId` for one the caller owns, `inId`, of equal or higher score (anyone, not paused, not retired). reverts: `NotInPile(outId)`, `InPile()` (inId already in a pile), `NotOwner()`, `ScoreTooLow(inId, outId)`, `ZeroId()`, `Paused()`, `Retired()`. the caller approves the Core for `swapFeeCc` coin first; the Core burns it through the coin's `burnFrom(caller, fee)` (a zero fee skips it). `inId` takes `outId`'s pile position, cost basis and acquisition time, so `pileSize` and the credit sale window state of the slot are unchanged; `outId` returns to the caller. event `CreditSwapped(inId indexed, outId indexed, caller indexed, fee)`. read the score of a credit with the same source the bid uses (`CreditScore.scoreOf(seedOf, timestampOf)`).

## 11. owner events to watch

`SettingsSet(settings)`, `RateSet(rate)`, `ControllerSet`, `BalanceModuleSet`, `AdapterSet(adapter, allowed)`, `SuccessorSet`, `PayeeSet`, `ArtistSet`, `PausedSet`, `CreditCostToPotBpsSet`, `ChosenComposeOnSet`, `MinCcToChooseSet`, `RedeemBurnReleased`, the locks `ControllerLocked`, `BalanceModuleLocked`, `AdaptersLocked`, `SuccessorLocked`, the handover `OwnershipTransferStarted`, `OwnershipTransferred`; on the controller `SaleSet`, `CreditSaleSet`, `AnchorBpsSet`, `BalancePoolKeySet`; on the Seaport adapter `RecipientSet`.

## 12. gas

measured by test/GasCap.t.sol at the candidate, execution gas of one call, cold: `compose` about 8.5 million after refunds (10.6 million before), `buyListing` through the Seaport adapter about 480,000 and through the strategy adapter about 470,000, `buyback` about 270,000, `redeemStatement` under 1,500,000 with a real module, `sellForEth` about 400,000 for one credit and about 91 credits at the 16,777,216 transaction cap (per point, each credit reads its score); `swapCredit` about 253,000 (274,000 as a transaction, with the fee burned). the bounded reads: `nextPage` 500,000, `atFloor` 400,000, the adapter quote 300,000, the module unit 200,000 in the Core and 50,000 in the controller.
