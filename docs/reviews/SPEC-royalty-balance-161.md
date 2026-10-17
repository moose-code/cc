# The artist royalty on purchases and the flat balance bid: the implementation spec after decisions 160 and 161

Date 2026-10-17. Base: main `48be14c` (PR 66, the cold audit fixes, merged). Source of each rule: the decision in docs/DECISIONS.md named in brackets. Nothing here is built; this is what to build. The vocabulary is "balance", never "exit".

## 1. The two rules

- **The royalty** [160]. Whatever the engine pays for a credit, it pays `buyToArtistBps / 10,000` of that amount to the artist on top, in the same currency. The seller receives the displayed bid whole. 250 at launch.
- **The flat balance bid** [161]. The balance route pays `score * unitPerPoint * (10,000 - balanceDiscountBps) / 10,000` per credit, flat. No climb, no drop, no floor rate check. The only bound is the module's `available()`. 1,000 at launch.

Both are `Settings` fields set through `setSettings`, with no lock and no delay, effective for every later fill. The owner changes either after deployment with one `setSettings` call (RUNBOOK section 4, the settings table).

## 2. Settings

| field | type | bounds | launch | where |
|---|---|---|---|---|
| `buyToArtistBps` | uint16 | 0 to 1,000 | 250 | `Settings` field 37 (mirror index 36) |
| `balanceDiscountBps` | uint16 | 0 to 9,999 | 1,000 | `Settings` field 38 (mirror index 37) |

- `SettingsBounds.firstViolation`: `buyToArtistBps > 1_000` names `"buyToArtistBps"`; `balanceDiscountBps > 9_999` names `"balanceDiscountBps"` (a 10,000 discount would pay zero and every balance fill would revert `ZeroAmount`, the liveness rule of decision 143).
- `CoreLib.setSettings`: the zero artist rule becomes `(ns.saleToArtistBps != 0 || ns.buyToArtistBps != 0) && c.artist == address(0)` reverts `ZeroAddress`. `Core.setArtist(address(0))` is refused while either cut is nonzero.
- `balanceBidMarginBps` and `balanceBidCapBps` keep their fields, bounds and launch values. They are value mode settings only after this change: the floor and cap of the shared eth instance, and through the controller the sale floor multiplier. Their doc rows say so.
- The mirror `script/SettingsFields.sol` gains both names and indices; `script/LaunchConfig.sol` parses `.settings.buyToArtistBps` and `.settings.balanceDiscountBps`; `script/config/mainnet.json`, `anvil.json` and `rehearsal.json` carry 250 and 1000; `Interfaces.sol` `defaultSettings()` carries both; the launch asserts cover both. The launch config's `artist` stays required while `buyToArtistBps` or `saleToArtistBps` is nonzero.

## 3. The eth doors [160]

### `sellForEth(ids)`, `(ids, minOut)`

Per credit, in order, after the existing return lock and ownership checks:

```
pay      = bid * score / RATE_SCORE            // the displayed bid, unchanged
toArtist = pay * buyToArtistBps / BPS
_spend(pay + toArtist, score)                   // one ledger entry, the full outflow
_push(id, pay + toArtist)                       // cost basis is what the engine paid
total += pay; artistTotal += toArtist
emit CreditBought(id, msg.sender, pay + toArtist, toArtist)
```

After the loop: `minOut` floors `total` as today; the seller is paid `total` with `safeTransferETH`; then `artistTotal`, if nonzero, is pushed once with `SafeTransferLib.forceSafeTransferETH(s.artist, artistTotal, PUSH_GAS)`, the same forced push as the sale cuts, so a reverting artist never blocks a sale. One push per batch, not per credit.

The per credit `bid` is the read of section 5, already lowered to the room divided by `1 + bps`, so `pay + toArtist` fits the room whenever `pay` did before. `_spend`'s `cost > pot - reserve` check stays as the hard stop.

### `buyListing(adapter, id, params)`

```
toArtist = value * buyToArtistBps / BPS
if (value == 0) revert ZeroAmount();
if (value + toArtist > room) revert PotTooSmall();
if (value > bid) revert AboveBid();              // the bid caps the price, as today
... the venue call, the ownership and balance checks, unchanged ...
paid = payment.min(bid - value).min(room - value - toArtist)
_spend(value + toArtist + paid, score)
_push(id, value + toArtist + paid)
emit ListingBought(id, adapter, msg.sender, value, paid, rate, toArtist)
pay the keeper `paid`; then force push `toArtist` to the artist
```

The keeper payment is still capped at the bid less the price, so a listing never pays its offerer more than a direct seller receives, and the royalty rides on top of the listing price the way it rides on top of the bid. The spend budget counts the whole outflow.

### `adopt`, `swapCredit`, `compose`, the sales

No royalty: nothing is purchased. `sellTo` and `sellCreditTo` keep the sale cuts of decision 123 unchanged.

## 4. The balance door [160, 161]

`sellForBalance(ids)`, `(ids, minOut)`, `(ids, minOut, expectedToken)` keep their signatures and the `expectedToken` check. The body (`CoreLib._sellForBalance` and `_fillBalance`) becomes:

```
require not retired, balanceBidOn, ids nonempty, a module set     // unchanged
unit  = _liveUnit(module); avail = _liveAvailable(module)          // unchanged, BadModule on failure
rate  = BPS - balanceDiscountBps
floor = _ethFloorNow(c)                                            // the eth cost basis base, unchanged
for each id:
  owned, checkReturn, score                                        // unchanged
  paid     = score * unit * rate / BPS;  if (paid == 0) revert ZeroAmount();
  toArtist = paid * buyToArtistBps / BPS
  total += paid; artistTotal += toArtist
  if (total + artistTotal > avail) revert PotTooSmall();
  cost = floor * score / RATE_SCORE, at least 1                    // unchanged
  push the credit; transfer it in
  emit CreditBought(id, msg.sender, cost, toArtist)
  emit BalanceFill(paid, toArtist, avail - total - artistTotal)
if (total < minOut) revert Slippage();
module.pay(msg.sender, total); require the seller's holding rose by at least total (BadModule)
if (artistTotal != 0) module.pay(s.artist, artistTotal);
```

Removed from this path: `_balanceCheckpoint`, the `availBps` clamp, the floor rate check, the per credit `_drop`, `lastFillTime`. The module needs no change: `pay(to, amount)` already exists and reverts above `available()`; the sum check above runs first so the second `pay` cannot revert on funds. The artist's holding is not checked (an ERC20 transfer to the artist either succeeds or reverts the batch, which is the module's own `pay` guarantee; a fee on transfer token is unsupported, section 14 item 7).

## 5. The views and the clamp

- `balanceRate()` returns `BPS - balanceDiscountBps`, in every mode, bid on or off.
- `balanceBidForScore(score)` and `balanceBidOf(id)` return `score * unit * (BPS - balanceDiscountBps) / BPS`, and 0 when no module is set, the unit read fails, or `payout + payout * buyToArtistBps / BPS > available()` (the view never advertises a payout the fill refuses, C05 of decision 159). `_balanceRead` goes; `_balancePayout` reads the setting and `available()` only.
- The eth clamp. Every place the eth price state or its read is lowered to the pot divides that pot by `1 + bps`, one rule: `CoreLib.ethRate` (both branches), `_ethClimb`'s clamp, and the three price basis reads of decision 158 (`adopt`, `_moveEth`, `_ethFloorNow`), which decision 158 bound to the same clamp as the live bid and which stay bound to it. Concretely the clamp becomes `(_ethPagesPot(c) - reserve) * BPS / (BPS + buyToArtistBps)`, in one helper. `spendState()` keeps reporting the budget as `spendCapBps` of the pot: the budget counts outflow including royalties, as the ledger does.
- `ethRate`, `bidForScore`, `ethPerPoint`, `bidOf` keep their meaning: the amount the seller receives per 100 points, per score, per point, per credit.

## 6. The balance price state after the change

The `Rate` instance `State.balance` stays in storage and keeps its name. It is read and moved only in value mode, as the shared eth instance:

- `_valueRate` reads it (unchanged). `spend` drops it on an eth fill in value mode (unchanged). `_balanceCheckpointNow` and the `setSettings` reset run only for the value mode transitions: the `balanceBidOn` transitions no longer checkpoint or reset anything. `resetBalanceToFloor` (called by `Core.setBalanceModule`) becomes a no-op outside value mode and is removed with its Core call if nothing else needs it.
- `_toBps` is no longer needed; `_toBpsRaw` stays for the value mode pages pot of the shared instance.
- The value pricing spec's rule "every fill on either route drops the one instance" is amended: only eth fills drop it. A balance fill is invisible to the eth bid. docs/reviews/SPEC-value-pricing-153.md section 3 gets a dated note pointing here.

## 7. Events

| event | after |
|---|---|
| `CreditBought(uint256 indexed id, address indexed from, uint256 cost, uint256 toArtist)` | `cost` is the pile cost basis (eth routes: price plus royalty, plus the keeper payment for a listing; balance route: the eth floor basis); `toArtist` is the royalty in the route's currency |
| `ListingBought(uint256 indexed id, address indexed adapter, address indexed caller, uint256 cost, uint256 paid, uint256 rate, uint256 toArtist)` | `cost` stays the listing price (as today), `paid` the keeper payment, `toArtist` the royalty |
| `BalanceFill(uint256 paid, uint256 toArtist, uint256 available)` | replaces `BalanceRateFill(spent, rateBps, available)`: the balance paid to the seller for this credit, the royalty, and `available()` left after both |
| `EthRateFill`, `ValueRateFill` | unchanged; `spent` is the full outflow including the royalty |

## 8. Generated and pinned

- `script/tools/gen-interfaces.sh` regenerates `src/interfaces/ICore.sol` and friends. The ABIs in `packages/engine/src/abis.ts`, `keeper`, `indexer/abis/Core.ts` and `web` are regenerated from the build.
- `script/Checks.sol` and `test/BuildIdentity.t.sol` re-pin the Core, CoreLib and Controller build hashes. The Controller is untouched by this spec; its hash should not move.
- Size. The cold audit measured CoreLib at 51 bytes under EIP-170 and Core at 303 under, before PR 66 added the rescue door. Sections 3 and 4 add code; section 4 and 6 remove the balance climb, clamp, drop, floor check and the bid-on resets. Measure on the first build. If CoreLib is over, the next moves in order: drop `_toBps` and `resetBalanceToFloor` entirely, move the forced artist push into one private helper shared by the three doors and the sale cuts, move `rescueToken` into CoreLib behind `_toLib`. No behaviour change is spent on size.

## 9. Off chain

- Keeper `decide.ts`: `listingPayment` becomes `min(refund, bid - price, room - price - price * buyToArtistBps / BPS)` and the pre-check `price + price * buyToArtistBps / BPS <= room`. The settings decode gains the field. The e2e door tests assert the royalty leaves the pot.
- Indexer: the three events; the settings snapshot gains both fields (`ponder.schema.ts`, `chain.ts`); a running artist royalty total per currency; `balanceRate` keeps its column with the posted meaning. docs/INDEXER.md section 9 adds the rows: artist royalty per fill (I: `CreditBought.toArtist`, `ListingBought.toArtist`, `BalanceFill.toArtist`), artist royalty total (D: the sum), the balance bid (I: `balanceRate`, now the posted rate; L fallback `balanceRate()`), and names this spec as the source.
- Web: the sell panels show "the engine pays a 2.5 percent artist royalty on top" with the amount, on both routes; the balance bid is shown as a posted price per point; `sell.ts` drops the "shared instance" label; the settings page lists both fields; `sale-split.ts` is unchanged.
- Sim: `engine.js` charges the pot `pay * (1 + buyToArtistBps / BPS)` on every eth purchase and credits the artist; the balance bid is the posted rate; `value.mjs` stops dropping the shared instance on a balance fill. The volume table of the sim README gains the artist column.

## 10. Docs

- docs/SPEC.md: section 1 rows (added with the decision); section 3 the two new rows and the rewritten rows for `balanceBidMarginBps` and `balanceBidCapBps`; section 4 the clamp and the ETH purchase budget note; section 6 the three door rows and the pile cost basis line; section 8 the cost basis sentence; section 9 rewritten around the posted bid, with the shared instance paragraph moved under value mode; section 11 a row for the two new owner levers (the royalty bounded at 10 percent of every purchase, the discount at 99.99 percent); section 14 an item: the balance bid pays a known redemption, so it has no drop, and its only bound is `available()`.
- docs/RUNBOOK.md: the settings table rows for both fields with the `cast` line to change them; the switch call of section 4 step 4 unchanged except that the balance bid opens at the posted rate.
- docs/STATUS.md: the candidate row, the freeze table, the open items (the audited candidate `7919099` is superseded; the freeze re-runs on the new candidate).

## 11. Tests

Each kept or new test carries a `// promise:` line. `forge build` and `forge test --match-path` per touched file during the work; the whole suite, the deep invariants and the rehearsal once on the frozen candidate with `CANDIDATE_RUN=1`.

New, `test/ArtistRoyalty.t.sol`:

- each door pays exactly `bps` of the payment to the artist, in its currency, and the seller receives the displayed bid whole (`sellForEth` single and batch, `buyListing` on the Seaport and strategy adapters, `sellForBalance` single and batch);
- one push per `sellForEth` batch; a reverting and a gas-burning artist never block any door (the eth routes force push, the balance route's module pays an EOA);
- cost basis equals price plus royalty on the eth routes, plus the keeper payment for a listing; unchanged on the balance route;
- the ledger: `spendState` and `SpendCapReached` count the royalty; the pot accounting invariant holds (tracked pots plus pushed royalties equal the eth that left);
- the clamp: at a pot that covers one bid and its royalty exactly, the last credit fills; at one wei less, `PotTooSmall`; the displayed bid equals the paid bid at the clamp;
- `buyListing`: a listing at the bid clears with the royalty from the room and the keeper capped at zero; a listing whose price plus royalty passes the room reverts `PotTooSmall`;
- the zero artist rules for `setSettings` and `setArtist` with each cut nonzero; the bound at 1,001;
- at `buyToArtistBps` 0 every door behaves byte for byte as on `48be14c` (the differential, run against the pinned build).

New, `test/BalanceFlat.t.sol`:

- the payout is `score * unit * (10,000 - discount) / 10,000` at discount 0, 1,000, 9,999, before and after a `setSettings` change, with no climb after a day idle and no drop after a 300 credit batch;
- `PotTooSmall` exactly when payouts plus royalties pass `available()`; the view reads 0 there and the payout otherwise;
- a balance fill does not move `ethRate`, `ethPrice` or the shared instance, in and out of value mode; an eth fill in value mode does not move `balanceRate`;
- the `balanceBidOn` and module set transitions leave the shared instance alone; the value mode transitions still reset it;
- `balanceRate` reads the posted rate with the bid off, no module, a failing unit;
- the `expectedToken` overload and the return lock unchanged;
- the bound at 10,000.

Rewritten: the balance bid tests that assert the climb, the drop, the floor rate check, the `availBps` clamp and the bid-on resets (26 files reference the balance bid; each case is kept where the promise survives and deleted with its promise line where the promise is gone). The invariant handler's balance route and its accounting; `test/GasCap.t.sol` (the batch size with one more push); the keeper e2e door and Seaport tests; the exposure grids and the cold audit's launch day tests re-run on the new numbers, their result files refreshed.

## 12. Order of work

1. Settings, bounds, mirror, config, defaults, launch asserts.
2. The eth doors and the clamp; `ArtistRoyalty.t.sol`; the differential at bps 0.
3. The balance door, the views, the price state narrowing; `BalanceFlat.t.sol`; the rewritten balance tests.
4. Interfaces, hashes, size measurement; the size moves of section 8 only if needed.
5. Keeper, indexer, web, sim, their tests.
6. Docs of section 10.
7. The frozen candidate: full suite, deep, rehearsal, the delta review of the three doors.

## 13. Numbers

Per 1,000 eth of coin volume at launch values, engine fully deploying its pot: artist from purchases about 2.0 eth, pot buys about 2.4 percent fewer credits, the same eth leaving the pot. Per 100 points on the balance route at a 10 percent discount: seller 90, artist 2.25, module pays 92.25, redeems 100, keeps 7.75 less about 1.8 in eth processing at launch prices. Break even on that route is near a 4 percent discount.
