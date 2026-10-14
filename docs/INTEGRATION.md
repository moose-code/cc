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
| `core.ethRate()` | the bid per credit now, with the unbooked fees counted into the pot |
| `core.ethPrice()`, `core.floorRate()` | the price state before the pot clamp; the rate under every price floor |
| `core.ethPot()`, `core.ethToBuyback()`, `core.ethRedeemBurn()`, `core.balancePot()`, `core.payeeOwed()` | the pots |
| `core.pileSize()`, `core.pilePage(startAfter, n)`, `core.creditInfo(id)` | the pile, oldest first, with cost and acquisition time |
| `core.heldStatements()`, `core.statementInfo(sid)`, `core.statementAge(sid)`, `core.ratingOf(sid)`, `core.composerOf(sid)` | the held statements |
| `controller.nextPage()` | whether a page is ready for `compose` |
| `controller.priceOf(sid)`, `controller.grossPriceOf(sid)`, `controller.referenceOf(sid)`, `controller.atFloor(sid)` | the asking price, what `buy` takes, the reference, redemption eligibility |
| `controller.creditPrice(id)`, `controller.grossCreditPrice(id)`, `controller.pastWindow(acquiredAt)`, `controller.creditSaleOn()` | the credit sale window |
| `controller.pointRate()`, `controller.valueOf(points)`, `controller.anchorBps()`, `controller.startBps()` | the pricing inputs |
| `core.settings()`, `core.paused()`, `core.retired()`, the lock flags, `core.chosenComposeOn()`, `core.minCcToChoose()` | the switches |

## 3. selling credits for eth

1. read `core.ethRate()` and `core.ethPot()`.
2. `credits.setApprovalForAll(core, true)` once.
3. `core.sellForEth(ids, minOut)` with `minOut` a little under `rate * ids.length` (each credit drops the rate 0.5 percent for the next). the eth arrives in the same call. a batch whose total passes the pot reverts whole (`ZeroAmount` or `PotTooSmall`); up to about 115 credits fit under the gas cap.

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

`controller.nextPage()` ready means 80 credits wait (and, while the credit sale is on, the newest is past its window). `core.compose()` composes them with a random format, `core.compose(format)` with the given one. `core.composeChosen(ids, format)` composes 80 credits the caller names (requires `chosenComposeOn`, a CC balance of at least `minCcToChoose`, every credit past its window). the caller pays the gas, about 8.5 million after refunds; the payment settings `callerFee` and `callerMaxBaseFee` are 0 at launch. `core.setHeldFormat(sid, format)` restyles a held statement for a holder of `minCcToChoose` CC.

reverts: `NotReady`, `BadFormat`, `NotInPile(id)`, `NotHeld`, `BadStatement`, `ChosenComposeOff`, `BelowMinCc`, `InWindow(id)`, `NotForSale` (restyle of an unheld statement), `Retired`. events `Composed(sid, ids, format, cost, caller)`, `HeldFormatSet(sid, format, caller)`.

## 6. buying statements and credits

- a statement: read `controller.grossPriceOf(sid)` and send at least that to `controller.buy(sid)`. the controller forwards the engine price to the Core, keeps the royalty (`royaltyBps`, 250 at launch) for `royaltyRecipient`, and refunds the excess. reverts `NotForSale`, `Underpaid`, `Reentrant`, and through the Core `Paused`, `BelowFloor`. events `Bought(sid, buyer, price)`, `AnchorMoved(sid, saleBps, anchorBps)`, `StatementSoldTo(sid, buyer, price, toBuyback)`.
- a pile credit, while `creditSaleOn`: `controller.grossCreditPrice(id)` to `controller.buyCredit(id)`, or `buyCredits(ids)` with the sum. reverts `CreditSaleOff`, `NotForSale`, `Underpaid`, `Reentrant`, `Paused`, `BelowFloor`. event `CreditSold(id, buyer, price)`.
- `controller.claimRoyalty()` sends `royaltyOwed` to the recipient; anyone may call. event `RoyaltyClaimed(to, amount)`.

## 7. fees, booking and funding

fees reach the Core from the pool's hook on every swap and are booked at the next door. `core.book()` books them now (a keeper calls it at the end of the anti sniper window, launch plus 30 minutes). `core.fund()` payable adds eth to the pot whole. `core.collectEscrow()` claims the Core's fee escrow credit into the pot. `core.claimPayee()` pays the payee claim. `core.bookBalance()` books balance token held above the pot. a plain send to the Core reverts `UseFund`. events `FeesAdded(amount)`, `Funded(from, amount)`, `EscrowCollected(amount)`, `PayeeClaimed(payee, amount)`, `BalanceBooked(amount)`.

## 8. the buyback

`core.buyback()`, anyone, once per `buybackDelay` blocks while `ethToBuyback` holds at least twice the largest payment. the caller is paid the gas at the base fee (capped at `keeperMaxBaseFee`, 600,000 gas) plus `keeperFee` scaled by the eth spent. reverts `NothingToBuy`, `TooSoon`, `SliceTooSmall`, `NothingBought`, `BadSwap`. event `Buyback(caller, amountIn, paid)`.

## 9. the balance side

off at launch (`redeemOn`, `balanceBidOn` false, no module). once on: `core.redeemStatement(sid)` for a held statement with `controller.atFloor(sid)` true; `core.sellForBalance(ids, minOut)` pays balance token per credit by score. reverts `NoBalanceModule`, `RedeemOff`, `BalanceBidOff`, `NotHeld`, `NotEligible`, `Underpaid`, `BadModule`, `BadQuote`, `PotTooSmall`, `Slippage`, `Retired`. events `StatementRedeemed(sid, received)`, `CreditBought(id, from, cost)`.

## 10. adopt, migrate, rescue

`core.adopt(ids)` puts credits the Core holds without a record into the pile (anyone). the owner's `migrate(maxCredits)` sends the pots and credits to the successor and retires the engine (`Retired` from the buying and composing doors after it); the successor takes the eth through `fund()`. `rescueCoin` and `rescueNft` are owner only. events `CreditAdopted`, `Migrated`, `EngineRetired`, `BalanceTokenMigrationSkipped`, `CoinRescued`, `NftRescued`.

## 11. owner events to watch

`SettingsSet(settings)`, `RateSet(rate)`, `ControllerSet`, `BalanceModuleSet`, `AdapterSet(adapter, allowed)`, `SuccessorSet`, `PayeeSet`, `PausedSet`, `CreditCostToPotBpsSet`, `ChosenComposeOnSet`, `MinCcToChooseSet`, `RedeemBurnReleased`, the locks `ControllerLocked`, `BalanceModuleLocked`, `AdaptersLocked`, `SuccessorLocked`, the handover `OwnershipTransferStarted`, `OwnershipTransferred`; on the controller `SaleSet`, `CreditSaleSet`, `AnchorBpsSet`, `BalancePoolKeySet`; on the Seaport adapter `RecipientSet`.

## 12. gas

measured by test/GasCap.t.sol at the candidate, execution gas of one call, cold: `compose` about 8.5 million after refunds (10.6 million before), `buyListing` through the Seaport adapter about 480,000 and through the strategy adapter about 470,000, `buyback` about 270,000, `redeemStatement` under 1,500,000 with a real module, `sellForEth` about 315,000 for one credit and about 115 credits at the 16,777,216 transaction cap. the bounded reads: `nextPage` 500,000, `atFloor` 400,000, the adapter quote 300,000, the module unit 200,000 in the Core and 50,000 in the controller.
