# Acceptance of decisions 99 to 114 at commit b88940c

Short names: Core = `src/Core.sol`, Ctl = `src/ControllerV1.sol`, Lib = `src/lib/CoreLib.sol`, Ifc = `src/interfaces/Interfaces.sol`, Cfg = `script/config/mainnet.json`.

## Decisions 99 to 114

| Dec | Rule | Where | Verdict | Note |
|---|---|---|---|---|
| 99 | balance side built, off at launch, switches turn on later | Core `redeemStatement`; Lib `_sellForBalance`; Ctl `setCredit`; Ifc `Settings` | matches | Rule read from DECISIONS.md line 299; no section 11 row. |
| 100 | `buyListing` for owner-approved adapters only; adapter prices, Core calls; raw path removed; Seaport 1.6 and CreditStrategy adapters; one credit must arrive; pay at most bid | Core `buyListing`, `_quote`, `addAdapter`, `lockAdapters`; `SeaportBasicAdapter.price`; `CreditStrategyAdapter.price` | matches | Only raw `target.call` in src is in `buyListing`. Seaport constant is the 1.6 address. |
| 101 | rating at compose; mode switches; replaceable balance module, token fixed once set; pool key setter; one pile | Core `_compose`, `_setBalanceModule`; Ctl `setBalancePoolKey`; Lib `_sellForBalance` | matches | |
| 102 | "balance" vocabulary and listed names | Names present in Core, Lib, Ifc, Ctl | matches | Exit names absent from src, script, test. Docs residue: RUNBOOK line 139, SPEC line 61. |
| 103 | ten bid knobs, including `setRate` | Ifc `Settings` (nine fields); Core `setRate` | matches with noted difference | `setRate` is a function, not a setting, and has no Cfg key. |
| 104 | `pointRate = floorRate/refScore`; `pointValue = max(pointRate, unit x pool price)`; reference and credit floor on it; balance-bought cost `score x pointRate`; unit read live | Ctl `pointRate`, `valueOf`, `_poolValue`, `_reference`, `creditPrice`; Lib `_sellForBalance` | matches with noted difference | (a) No `pointValue` identifier; the function is `valueOf`. (b) Cost is `floor.mulDiv(score, refScore)`, full precision; differs by under `score` wei per credit. |
| 105 | `saleFloorBps` is the hard floor; controller `floorBps` removed | Core `sellTo`; Ctl `_saleFloorBps`, `_quote`; `Sale` has no floor field | matches | |
| 106 | `feeToBuybackBps` removed; fee splits once to reserve and pot | Core `_split`, `_book`, `releaseRedeemBurn`; Cfg | matches | |
| 107 | `redeemOn` and `balanceBidOn` replace `exitMode` | Ifc `Settings`; Core `redeemStatement`; Lib `_sellForBalance` | matches | |
| 108 | kept items | see 108 table | matches | |
| 109 | Core is bounty recipient; FeeRouter removed; `receive` from hook only; `book`, `fund`, `collectEscrow`, `claimPayee`; payee after sniper window read from factory record; `skim` removed; coin via `predictToken` | Core `receive`, `_book`, `fund`, `collectEscrow`, `claimPayee`, `_sniperOver`, constructor | matches with noted differences | (a) `receive` also accepts `ESCROW` (Core line 330); SPEC line 64 agrees with code. (b) Only `launchedAt` comes from the factory; the window is constructor input `cfg_.mev.windowSeconds`. (c) Lib `_moveEth` falls back to a plain send when `fund()` fails. |
| 110 | evidence ledger replaced by freeze table; gate refuses deploy unless HEAD is candidate and rows filled | docs/STATUS.md section 4; `script/tools/check-freeze.sh` | matches with noted difference | Gate is called from RUNBOOK step 6 only, not from a deploy script. |
| 111 | composer stored at compose; no v1 payout | Core `_compose`; Lib State `composerOf` | matches with noted difference | Kept in a mapping beside the Statement record, not a field of `Lib.Statement`. |
| 112 | royalty on top of `p`; pull claim; `royaltyBps` 250; payee 75,185 ppm | Ctl `buy`, `buyCredit`, `buyCredits`, `_royalty`, `claimRoyalty`, `setCredit`; Core `_split` | matches with noted difference | Cfg `royaltyRecipient` is the owner address; the decision names the artist. Artist address needs owner confirmation. |
| 113 | `compose(uint8)`; random `compose()` from `keccak256(prevrandao, head id) % 8`; `setHeldFormat` gated by `minCcToChoose` | Core `compose`, `_composePage`, `setHeldFormat`, `composeChosen`; Cfg `minCcToChoose` | matches with noted difference | The Ctl contract doc comment says the controller composes with format 0; stale. |
| 114 | `setSale(Sale)` and `setCredit(CreditSale)` replace field setters; whole struct emitted | Ctl `setSale`, `_setSale`, `setCredit`, `setAnchorBps`, `setBalancePoolKey` | matches with noted difference | Cross-field checks remain inside `_setSale`; confirm "one call" is the intent. Comment pass is not in the tree. |

## Agreement paragraph, eight clauses (clause 6 split at the semicolon)

| # | Clause | Where | Verdict | Note |
|---|---|---|---|---|
| 1 | Trading fees fund a permanent public bid | Core `receive`, `_book`, `sellForEth` | matches with noted difference | Bid ends at `migrate`, which sets `retired`. |
| 2 | Sellers sell at the bid; engine sweeps cheaper approved listings and keeps the discount | Core `sellForEth`, `buyListing` | matches | |
| 3 | Compose 80 Credits into a Statement, sold from a start above cost down to an owner floor | Core `_compose`, `sellTo`; Ctl `startBps`, `_quote` | matches with noted difference | Bounds allow markup and anchor of 10,000, so the start can equal cost. Cfg 15,000 is above cost. |
| 4 | Half of every sale burns CC, half buys Credits | Core `sellTo` (`saleToBuybackBps` 5000); `sellCreditTo` | matches with noted difference | Statement sales only. Credit sales send the whole markup to the buyback at `creditCostToPotBps` 10,000. |
| 5 | With $balance live, floor Statements redeem by rating; Credits bought by score; each redemption burns CC from a reserve | Core `redeemStatement`, `sellForBalance` | matches with noted difference | Each redemption moves 20% of the reserve to the buyback; the burn runs in a later `buyback`. |
| 6 | Owner sets every number at once, with no delay | Core `setSettings`, `setRate`; Ctl `setSale`, `setCredit` | matches | Effective at the call. |
| 7 | Holders trust the owner key; locks and migration are the only ways to narrow or move that power | Locks: `lockController`, `lockBalanceModule`, `lockAdapters`, `lockSuccessor`; `migrate` | missing | `setPayee`, `rescueCoin` and `rescueNft` act at once with no lock. Check section 10.10. |
| 8 | Launch before $balance; balance side, credit window and chosen composition built and off | Cfg `redeemOn`, `balanceBidOn`, `credit.saleOn`, `credit.chosenComposeOn` | matches | |

## Decision 108 kept items

| Item | Where | Verdict | Note |
|---|---|---|---|
| caller payment (`callerFee`, `callerMaxBaseFee`) | Core `_payCaller` | matches | Both 0 in Cfg. |
| `creditCostToPotBps` | Core constructor, `sellCreditTo`, setter | matches | Cfg 10000. |
| `composeChosen` | Core `composeChosen`, `_pastWindow` | matches | Cfg off. |
| pause | Core `setPaused`; `sellTo` and `sellCreditTo` revert `Paused` | matches | |
| anchor and guards | Ctl `setAnchorBps`, `anchorBps`, `_moveAnchor` | matches | |
| credit sale window | Ctl `setCredit`, `creditPrice`, `buyCredit` | matches | Cfg `saleOn` false. |
| live pool reads | Ctl `setBalancePoolKey`, `_poolValue`, `_priceBaseUnits` | matches | Pool key unset at launch. |
| single owner, instant power | Core `onlyOwner`; no timelock | matches | AI run review is a process item, not checked. |

Launch values: `payeePpm` 75185, `royaltyBps` 250, `minCcToChoose` 1e18, `redeemOn` and `balanceBidOn` false, and the Seaport allowlist equal to `Mainnet.OPENSEA_FEE_COLLECTOR` all match.
