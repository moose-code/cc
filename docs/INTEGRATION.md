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
| `core.balanceRate()` | the balance token bid now, bps of par (par is a credit's `score * unitPerPoint`): the rising balance bid lowered to `available()` as bps of par, at most `settings.balanceBidCapBps` (10,000 at launch) |
| `core.balanceBidOf(id)` | the balance token payout for credit `id` now: `score * unitPerPoint * balanceRate() / 10,000` |
| `core.pileSize()`, `core.pilePage(startAfter, n)`, `core.creditInfo(id)` | the pile, oldest first, with cost and acquisition time |
| `core.heldStatements()`, `core.statementInfo(sid)`, `core.statementAge(sid)`, `core.ratingOf(sid)`, `core.composerOf(sid)` | the held statements |
| `controller.nextPage()` | whether a page is ready for `compose` |
| `controller.priceOf(sid)`, `controller.referenceOf(sid)`, `controller.atFloor(sid)` | the asking price `buy` takes, the reference, redemption eligibility |
| `controller.creditPrice(id)`, `controller.pastWindow(acquiredAt)`, `controller.creditSaleOn()` | the credit sale window |
| `controller.pointRate()`, `controller.valueOf(points)`, `controller.anchorBps()`, `controller.startBps()` | the pricing inputs |
| `controller.referencePrice()`, `controller.referenceTime()`, `controller.spotPrice()`, `controller.quote()`, `controller.valuePerPoint(forSale)` | the reference price of value mode (decisions 148 and 156): the rate limited reference of the balance token and the pool spot, wei per 1e18 base units, the reference sample time, the reference price settings, and the wei value of one point at the buy (`false`) or sale (`true`) price with whether the reference price is usable |
| `core.settings()`, `core.paused()`, `core.retired()`, the lock flags, `core.chosenComposeOn()`, `core.minCcToChoose()` | the switches |

in value mode (`settings().valueModeOn`) `ethRate()` is the shared balance instance (`balanceRate()`, climbed with the cap as its clamp) times `valuePerPoint(false) * 100 / 10,000`, at most `rateCap` and the room, and `ethRate`, `ethPrice`, `bidOf` and `sellForEth` revert `NoQuote()` while the quote is unusable; read them with a tolerant multicall and show no eth bid. `controller.observe()` is public: anyone moves the reference toward the spot by at most the rate times the elapsed time, and the sale doors call it first.

`ethRate()` and `bidOf(id)` report the rate and pot clamp without the purchase budget. A nonzero quote does not mean a purchase can execute: simulate the actual transaction, and handle `SpendCapReached(uint256 spent, uint256 cost, uint256 budget)` by waiting for the next bucket or an owner settings change. The first purchase of a bucket always passes. There is no separate remaining-budget view.

## 3. selling credits for eth

1. read `core.bidOf(id)` for each credit (or `core.ethRate()` and scale by `score / refScore`) and `core.ethPot()`.
2. `credits.setApprovalForAll(core, true)` once.
3. `core.sellForEth(ids, minOut)` pays `core.bidOf(id)` = `ethRate() * score / refScore` per credit; set `minOut` a little under the sum of `bidOf` over the ids (each credit drops the rate by `dropPerCreditBps * score / refScore` for the next). the eth arrives in the same call. a batch whose total passes the pot reverts whole (`ZeroAmount` or `PotTooSmall`); up to about 91 credits fit under the gas cap (each credit reads its score).

reverts: `Empty`, `ZeroId`, `NotOwner`, `ZeroAmount`, `PotTooSmall`, `SpendCapReached`, `Slippage`, `Retired`, `ReturnLocked`, and in value mode `NoQuote`. event `CreditBought(id, from, cost)` per credit, `EthRateFill(spent, rate, pot)` per fill, in value mode `ValueRateFill(spent, rateBps, pot)` with the shared instance rate after the drop.

## 4. sweeping a listing

`core.buyListing(adapter, id, params)`. the adapter prices the listing from its own data; the engine pays the listing and pays the caller the gas at the base fee (capped at `keeperMaxBaseFee`, 1,500,000 gas) plus `keeperFee`, at most the gap between the bid and the listing and the pot left after the listing. the gas calculation adds 350,000 overhead gas for work after its count, the transaction base and typical calldata; this is an accounting constant, not a measured transaction total. the purchase budget counts the listing price plus the actual keeper payment.

| adapter | `params` | reverts of the adapter |
|---|---|---|
| SeaportBasicAdapter | `abi.encode(BasicOrderParameters)` of a Seaport 1.6 basic order: Credits as offer token, `id`, amount 1, native consideration, an open order type, every additional recipient the offerer or allowlisted (`allowedRecipient(a)`) | `WrongToken`, `WrongId`, `WrongAmount`, `NotNative`, `ZeroPrice`, `RestrictedOrder`, `RecipientNotAllowed(recipient)` |
| CreditStrategyAdapter | empty | `NotForSale` when `nftForSale(id)` is 0 |

reverts of the Core: `AdapterNotAllowed`, `ZeroId`, `AlreadyOwned`, `BadQuote` (the adapter reverted or answered badly; an adapter's own revert surfaces as `BadQuote`), `ForbiddenTarget`, `ZeroAmount`, `PotTooSmall`, `AboveBid`, `CallFailed`, `NoCredit`, `BadCost`, `SpendCapReached`, `Retired`. event `ListingBought(id, adapter, caller, cost, paid, rate)`.

a listing whose price is above the bid is not swept; a holder sells it with `sellForEth` instead. a hook push landing inside the target call (a swap in a callback) is fee income at the next book.

## 5. composing

`controller.nextPage()` ready means 80 credits wait (and, while the credit sale is on, the newest is past its window). `core.compose()` composes them with a random format, `core.compose(format)` with the given one. `core.composeChosen(ids, format)` composes 80 credits the caller names (requires `chosenComposeOn`, a CC balance of at least `minCcToChoose`, every credit past its window). the caller pays the gas, about 8.5 million after refunds; the payment settings are `callerMaxBaseFee` 3 gwei and `callerFee` 0.0003 eth at launch (decision 138), about 0.026 eth per page at or above 3 gwei. `core.setHeldFormat(sid, format)` restyles a held statement for a holder of `minCcToChoose` CC.

reverts: `NotReady`, `BadFormat`, `NotInPile(id)`, `NotHeld`, `BadStatement`, `ChosenComposeOff`, `BelowMinCc`, `InWindow(id)`, `NotForSale` (restyle of an unheld statement), `Retired`. events `Composed(sid, ids, format, cost, price, caller)`, `HeldFormatSet(sid, format, caller)`.

## 6. buying statements and credits

- a statement: read `controller.priceOf(sid)` and send at least that to `controller.buy(sid)`. the controller forwards the price to the Core, which takes the artist cut (`saleToArtistBps`, 250 at launch) and the operator cut (`saleToOperatorBps`, 50 at launch) off the payment and pushes them to the artist and the payee; the controller refunds the excess. reverts `NotForSale`, `Underpaid`, `Reentrant`, and through the Core `Paused`, `BelowFloor`. events `Bought(sid, buyer, price)`, `AnchorMoved(sid, saleBps, anchorBps)`, `StatementSoldTo(sid, buyer, price, toBuyback, toArtist, toOperator)`.
- a pile credit, while `creditSaleOn`: `controller.creditPrice(id)` to `controller.buyCredit(id)`, or `buyCredits(ids)` with the sum. the Core takes the two cuts off each payment. reverts `CreditSaleOff`, `NotForSale`, `Underpaid`, `Reentrant`, `Paused`, `BelowFloor`. event `CreditSold(id, buyer, price, toArtist, toOperator)`.
- the artist and operator cuts are pushed during the sale, there is no claim. the owner sets the artist with `core.setArtist(to)` (event `ArtistSet`, the zero address refused while `saleToArtistBps` is nonzero) and the cut bps with `setSettings`.

## 7. fees, booking and funding

fees reach the Core from the pool's hook on every swap and are booked at the next door. `core.book()` books them now. the first book with income at or after the factory launch time plus `settings.sniperSeconds` latches `payeeOn`; that book shares nothing, and later books apply `payeePpm`. the launch default is 1,800 seconds. changing this setting does not undo a latched payee share or change the external launch skim schedule. `core.fund()` payable adds eth to the pot whole. `core.collectEscrow()` claims the Core's fee escrow credit into the pot. the payee share is pushed by the book, not claimed. the balance token is held by the module, not the Core, so there is no balance booking door. a plain send to the Core reverts `UseFund`. events `FeesAdded(amount, toPayee)`, `Funded(from, amount)`, `EscrowCollected(amount)`.

## 8. the buyback

`core.buyback()`, anyone, once per `buybackDelay` blocks while `ethToBuyback` holds at least twice the largest payment. the caller is paid the gas at the base fee (capped at `keeperMaxBaseFee`, 600,000 gas) plus `keeperFee` scaled by the eth spent. reverts `NothingToBuy`, `TooSoon`, `SliceTooSmall`, `NothingBought`, `BadSwap`. event `Buyback(caller, amountIn, paid)`.

## 9. the balance side

the module holds the balance token; the Core holds none. its interface adds `available()` (the token it commits to the bid) and `pay(to, amount)` (the Core only). at launch `redeemOn` is true, `balanceBidOn` is false and no module is set, so `redeemStatement` reverts `NoBalanceModule`. `core.redeemStatement(sid)` for a held statement with `controller.atFloor(sid)` true leaves its proceeds in the module; reverts `BadModule` when the module's holding rises by less than `rating * unit * (10,000 - redeemSlippageBps) / 10,000`. `core.sellForBalance(ids, minOut)` pays `score * unitPerPoint * core.balanceRate() / 10,000` in balance token per credit from the module, the rising balance bid (SPEC section 4): the rate climbs in bps of par toward `settings.balanceBidCapBps` (10,000 at launch), floors at `10,000 - balanceBidMarginBps`, clamps to `available()` as bps of par, and drops per credit. read `core.balanceBidOf(id)` for each credit and set `minOut` a little under the sum (each credit drops the rate for the next). the batch total must fit `available()` in base units and the seller's holding must rise by the total, else it reverts `NoBalanceModule`, `BalanceBidOff`, `Empty`, `BadModule`, `ZeroAmount`, `PotTooSmall`, `Slippage`, `Retired`. with the bid off and `redeemOn`, redemptions keep filling the module (the accumulate mode). events `StatementRedeemed(sid, received)`, `CreditBought(id, from, cost)`, `BalanceRateFill(spent, rateBps, available)` per credit sold into the balance bid.

balance purchases do not consume the ETH purchase budget. raising `balanceBidCapBps` permits bids above par; the floor remains `10,000 - balanceBidMarginBps`. lowering the cap checkpoints the old climb first and clamps the stored balance rate to the new cap.

## 10. adopt, migrate, rescue

`core.adopt(ids)` puts credits the Core holds without a record into the pile (anyone). the owner's `migrate(maxCredits)` sends the eth pot and credits to the successor and retires the engine (`Retired` from the buying and composing doors after it); the successor takes the eth through `fund()`; the balance token is held by the module, not the Core, so migrate has no balance leg. `rescueCoin` and `rescueNft` are owner only; `rescueNft` reverts `NoCreditRescue` for Credits in every state, and a credit sent to the Core leaves through `adopt` and the doors. events `CreditAdopted`, `Migrated`, `EngineRetired`, `CoinRescued`, `NftRescued`.

`core.swapCredit(inId, outId)` swaps a pile credit `outId` for one the caller owns, `inId`, of equal or higher score (anyone, not paused, not retired). reverts: `NotInPile(outId)`, `InPile()` (inId already in a pile), `NotOwner()`, `ScoreTooLow(inId, outId)`, `ZeroId()`, `Paused()`, `Retired()`. the caller approves the Core for `swapFeeCc` coin first; the Core burns it through the coin's `burnFrom(caller, fee)` (a zero fee skips it). `inId` takes `outId`'s pile position, cost basis and acquisition time, so `pileSize` and the credit sale window state of the slot are unchanged; `outId` returns to the caller. event `CreditSwapped(inId indexed, outId indexed, caller indexed, fee)`. read the score of a credit with the same source the bid uses (`CreditScore.scoreOf(seedOf, timestampOf)`).

## 11. owner events to watch

`SettingsSet(settings)`, `RateSet(rate)`, `ControllerSet`, `BalanceModuleSet`, `AdapterSet(adapter, allowed)`, `SuccessorSet`, `PayeeSet`, `ArtistSet`, `PausedSet`, `CreditCostToPotBpsSet`, `ChosenComposeOnSet`, `MinCcToChooseSet`, `RedeemBurnReleased`, the locks `ControllerLocked`, `BalanceModuleLocked`, `AdaptersLocked`, `SuccessorLocked`, the handover `OwnershipTransferStarted`, `OwnershipTransferred`; on the controller `SaleSet`, `CreditSaleSet`, `AnchorBpsSet`, `BalancePoolKeySet`; on the Seaport adapter `RecipientSet`.

## 12. gas

last recorded before the issue 23 changes by test/GasCap.t.sol, execution gas of one call, cold: `compose` about 8.5 million after refunds (10.6 million before), `buyListing` through the Seaport adapter about 480,000 and through the strategy adapter about 470,000, `buyback` about 270,000, `redeemStatement` under 1,500,000 with a real module, `sellForEth` about 400,000 for one credit and about 91 credits at the 16,777,216 transaction cap (per point, each credit reads its score); `swapCredit` about 253,000 (274,000 as a transaction, with the fee burned). the bounded reads: `nextPage` 500,000, `atFloor` 400,000, the adapter quote 300,000, the module unit 200,000 in the Core and 50,000 in the controller, the controller's `valuePerPoint` 200,000 in value mode. in value mode a one credit `sellForEth` measured 480,178 against 435,297 on the eth instance (test/ValueMode.t.sol).

## 13. settings ABI and purchase buckets

`settings()` and `SettingsSet` carry 37 fields in declaration order, packed into five storage slots. retain the original 29 fields, including `uint16 climbMultiplierCapBps`, then append `uint16 spendCapBps`, `uint32 bucketSeconds`, `uint32 balanceBidCapBps`, `uint32 idleStepSeconds`, `uint32 sniperSeconds`, `uint64 reserveWei`, `uint32 returnLockSeconds`, `bool valueModeOn`. use integer-safe decoders: `keeperFee`, `rateCap`, `callerFee`, `swapFeeCc` and `buybackSlice` exceed JavaScript's safe-number range at their width limits. the complete tuple types are:

```text
(uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint16,bool,bool,uint16,uint16,uint16,uint128,uint64,uint48,uint64,uint64,uint48,uint16,uint24,uint32,uint96,uint16,uint16,uint16,uint16,uint32,uint32,uint32,uint32,uint64,uint32,bool)
```

`Sale` and `SaleSet` append `uint16 anchorMoveBps`, making six fields: `(uint16 markupBps,uint32 startCapBps,uint16 decayHours,uint32 anchorHalfLife,uint128 anchorMinCost,uint16 anchorMoveBps)`. a qualifying statement sale moves the anchor by this share of the upward gap, capped at `startCapBps`. zero disables sale-driven movement and leaves its clock unchanged. the launch value is 0 (decision 154).

the controller's constructor takes a fourth argument, the `Quote` struct `(uint32 referenceRateBpsPerHour, uint16 referenceStepBps, uint16 tolBps, uint32 referenceMaxStale, uint32 referenceMinSeconds, uint128 minLiquidity)`, also set by `setQuote(Quote)` (owner, `BadSetting("referenceStepBps")` above 10,000, `BadSetting("tolBps")` at 10,000 or more) with `QuoteSet(Quote)`; every reference refresh logs `ReferenceRefreshed(uint256 referencePrice, uint256 spot)`. a refresh runs at most once per `referenceMinSeconds` and only while `referenceMaxStale` is nonzero. in value mode the controller's `valueOf`, `priceOf`, `creditPrice` and sale doors revert `NoQuote()` while the reference price is unusable.

`CreditSale` and `CreditSaleSet` carry `(bool saleOn, uint32 window, uint16 spreadBps, uint32 startBps)`; `spreadBps` replaces `floorBps` and the getter is `creditSpreadBps()`. the credit floor is `max(cost, valueOf(score)) * floorMultBps() / 10,000` with `floorMultBps() = max(10,000, (10,000 + creditSpreadBps) * balanceBidCapBps / 10,000)`, the Core's cap read live (11,000 at launch, spread 1,000 per decision 155). `reserve()` on the Core is the eth the pot keeps for processing; the eth bids and `ethRate()` read `ethPot` plus the pending pot share less it, and `buyListing` refuses a quote above `ethPot` less it. every intake door refuses a credit the engine sold within `returnLockSeconds` (21,600 at launch, 0 is no lock) with `ReturnLocked(uint256 id, uint256 until)`, which replaces `SameBlockReturn`. `atFloor(sid)` is gated by the controller's `ageEligibilityOn` (false at launch): off it compares the curve price with its floor and reads the reference, on it is age only (the start at or below 10,000 or `statementAge(sid) >= decayHours * 3600`). `setAgeEligibilityOn(bool)` flips it.

ETH purchases through `sellForEth` and `buyListing` share one fixed bucket, `floor(block.timestamp / bucketSeconds)`. the first successful purchase snapshots the booked buying pot before its cost. the bucket budget is `snapshotPot * spendCapBps / 10,000`; the first purchase of a bucket always passes whatever its cost, and later purchases need spent plus cost at or below the budget; successful purchase outflow accumulates against it. later deposits do not enlarge that snapshot, unused budget does not carry forward, and a failing purchase or batch rolls back its accounting. buybacks, caller payments, balance purchases, redemptions and migration do not consume this purchase budget. the launch is 100 bps, 1 percent, per 60 seconds. purchases on opposite sides of a boundary may consume two successive budgets.

`spendCapBps == 10,000` bypasses enforcement, including for funds added after the snapshot, while still recording successful outflow. a settings edit retains active spent amounts and the original snapshot, and reprices its budget using the new cap. reducing the budget below spent blocks new purchases until the bucket ends or the budget is raised. a duration change translates the active bucket and preserves spent, snapshot and active bid drop floors; an already expired bucket is cleared. toggling bypass off does not erase spending during bypass. unrelated settings edits do not reset the budget.

`bucketSeconds` also controls both bids' first-fill drop floor. `idleStepSeconds` controls ceiling loosening steps (600 seconds at launch). the climb and recovery climb remain per 60 seconds. `balanceBidCapBps` defaults to 10,000 and `sniperSeconds` to 1,800. all durations are owner settings. current bounds and coupled constraints are in RUNBOOK section 4 and SPEC section 3.

for raw ETH quote readers, the expanded Settings moves `State.anchor` to slot 28: first-fill rate is slot 29; bucket is the low uint64 of slot 30, with peak time above it. decode with bigint and divide time by `bucketSeconds`. prefer generated ABI views for other reads. the web replay does not enforce or reserve purchase budget.

owner setBalanceModule may select another token until lockBalanceModule. holdings stay with their original modules, so each module keeps its own token reserve. a stored pool key contributes pool value while its currency1 is the current balance token. clients pin currency and quantity with sellForBalance(ids, minOut, expectedToken), which reverts BalanceTokenChanged before any Credit moves on a mismatch. the older overloads accept the token active at execution, and the web seller uses the token-pinned form. re-select an old module to spend its reserve, and spend old reserves before locking the replacement.

## Production balance module (decision 144)

`StatementBalanceModule(core, balanceToken)` targets Jack's `AuctionLineageWithdrawals`, whose ERC20 and redemption entry point share one address. The constructor checks the fixed Statements source, 18 decimals and `SCORE_TO_TOKEN == 1e14`. `redeem(sid)` is callable by the Core: it reads the statement's rating, quotes, approves that statement, withdraws, and reverts `RedeemedBelowRating` when the module's balance rose by less than `rating * unitPerPoint`. The proceeds stay in the module. The upstream contract holds the surrendered Statement. Receipts, contributed ink and wallet history belong to the module.

`available()` returns 0 until upstream retirement is complete and the opening block is reached, then the module's token balance. Renderer registration is a separate requirement for redemption. After retirement the module accumulates redemptions before opening while `available()` stays 0. `pay` is callable by the Core and reverts above `available()`.

The module has no owner. The balance token leaves it through the Core's `pay` or `redeem` path, or through `migrateReserve()`. After Core retirement anyone may call `migrateReserve()`: it sends the module's whole holding to `core.successor()`'s current module when that module's `core()` is the successor and its `balanceToken()` is the module's token. Repeat calls move later statement proceeds. A different token on the successor reverts `InvalidSuccessor`. Binding getters do not authenticate code: the owner selects the successor and its module, as with Core migration. A replacement module cannot retrieve the original module's reserve; `migrateReserve` is the only path, and it is called by a person or keeper after `Core.migrate`.
