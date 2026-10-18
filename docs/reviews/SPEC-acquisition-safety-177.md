# Acquisition safety items: the implementation spec after decision 177

Date 2026-10-18. Base: main `f843f5a`. Source: decision 177 (owner: "update the pr with only the cheap items"), the
design review docs/reviews/DESIGN-bid-time-path-anchor-f843f5a.md and its premise note. The time-path anchor of
decision 176 (docs/reviews/SPEC-time-path-anchor-176.md) is deferred until current market depth is measured; nothing
in it is built by this spec. The climb, ceiling, loosening, drop and peak of the bid are unchanged here.

Four items, each small, each right whether the market is deep or thin. One pull request against main, or one per
item if the reviewer prefers. AGENTS.md rules bind: `forge build` and `forge test --match-path` for the files
touched; `git checkout foundry.lock; git submodule update -- lib/solady` after a forge run; after a change of a
production contract's external surface `script/tools/gen-interfaces.sh`, then re-pin `script/Checks.sol` and
`test/BuildIdentity.t.sol`; Core has 538 bytes of headroom; no merge, push to main or deployment without the owner.

## 1. The pause halts acquisitions

Today `setPaused` stops `sellTo`, `sellCreditTo` and `swapCredit` only. After this change a pause stops everything
that moves eth or credits out of the pot or changes the price state.

- `Core._openDoor()` gains `if (s.paused) revert Paused();` before the `Retired` check. It is already the first
  action of `sellForEth`, `sellForBalance`, `buyListing`, `adopt`, `compose` and `composeChosen`, so one line covers
  both acquisition routes, the balance route, adoption and composition.
- `Core.buyback()` gains the same check after its `_book()`.
- Unchanged and live through a pause: `fund`, fee booking (`_book`, `book`), `collectEscrow`, `redeemStatement`
  (a holder right paid by the module; callable while paused and after migration today, by design), every view,
  every owner call including `setSettings`, `setRate`, `migrate`, the rescues.
- `setPaused(false)` sets `checkpointTime` and `lastFillTime` of the eth instance and of the shared balance instance
  to `block.timestamp`. Paused time then earns neither the per minute climb nor the ceiling's idle loosening, the same
  way statement age already excludes paused seconds. The remembered peak keeps decaying through a pause; that only
  lowers the ceiling. The spend bucket is untouched; its minute buckets simply expire.
- `setPaused(true)` changes nothing else. The comment on `setPaused` and SPEC section 1 ("the owner pauses sales") and
  section 11 are restated to the new scope.

Tests, `test/Pause.t.sol`, each with a `// promise:` line: every door above reverts `Paused` while paused and runs
after resume; `redeemStatement`, `fund`, `book`, `collectEscrow` run while paused; a one hour pause credits no climb
and no loosening (the read after resume equals the read before the pause, with the peak decayed); a pause does not
open or reset the spend bucket. `test/invariant/HandlerOwner.sol` already pauses; `invariant_11_noUnexpectedReverts`
and `invariant_16_theBidNeverCloses` list `Paused` as an expected revert on the newly covered doors. The keeper's
`decide.ts` reads `paused()` and skips `buyListing`, `buyback` and `compose` with a named reason instead of
simulating a revert.

## 2. `ethBidOn`, the switch for the eth routes

The mirror of `balanceBidOn`, built as a standalone field with its own setter like `chosenComposeOn`, so the packed
`Settings` struct and its ABI do not change.

- `State.ethBidOn` (bool), set true in the constructor. `setEthBidOn(bool)` owner only, idempotent, emits
  `EthBidOnSet(bool)`. View `ethBidOn()`.
- `sellForEth` and `buyListing` revert `EthBidOff()` while false, checked right after `_openDoor()`. Nothing else
  reads it: the balance route, compose, sales, buyback, redemptions and booking run.
- Turning it on from off sets the eth instance's `checkpointTime` and `lastFillTime` to now, so off time earns no
  climb and no loosening. Turning it off changes nothing else; the price state keeps its stored values.
- `ethRate()`, `bidOf` and the other reads are unchanged while off: the web shows the bid the engine would pay and a
  disabled action. The keeper skips `buyListing` with a named reason while off.

Tests in `test/Pause.t.sol` or a `test/EthBidOn.t.sol`: both doors revert `EthBidOff` while off and nothing else
does; the switch on resets the two clocks and credits no climb for the off period; `setEthBidOn` is owner only.
`test/CoreLayout.t.sol` pins the new field's slot. Interfaces regenerated and the pins redone.

## 3. `rateCap` 5 times the opening rate

- `script/config/mainnet.json`, `anvil.json`, `rehearsal.json`: `rateCap` 24,500,000,000,000,000 (5 times 4.9e15).
- `Mainnet.defaultSettings()` in `src/interfaces/Interfaces.sol`: the same.
- `script/Checks.sol`: the row "rateCap is 3 times rateStart" becomes 5 times; `_preSettingsRows` prints it.
- `test/Config.t.sol`, `test/Launch.t.sol`, `test/Flow.t.sol` and any assert that names the 3x ratio.
- docs/SPEC.md section 3 row for `rateCap` and section 1 parameter row; decisions 46, 60, 69 marked amended by 177.

Nothing else moves. The cap is read as today: `min(ceiling, rateCap)` in `_climb`, `setRate` refuses above it, a
`setSettings` that lowers it below the current price state lowers the read at once and the stored state at the next
checkpoint (`SetSettings.s.sol` warns).

## 4. A listing fill drops from `min(bid, ask)`

Today `CoreLib.spend(cost, score)` drops the price state from `rateAtCheckpoint`, the posted bid, for both routes.
A listing bought at a tenth of the bid therefore lowers the next bid as if it had paid the bid.

- `CoreLib.spend(uint256 cost, uint256 score, uint256 paidShareBps)` replaces `spend(cost, score)`. `paidShareBps`
  is the share of the per credit bid the fill actually paid, at most `BPS`. `_sellForEth` passes `BPS`.
  `buyListing` passes `value * BPS / bid` where `bid` is the per credit bid it already computes
  (`_bid().mulDiv(score, RATE_SCORE)`, nonzero because `value <= bid` and `value > 0`).
- In `spend`, mode off: `price = c.rateAtCheckpoint * paidShareBps / BPS`, then `_drop(c.anchor, price, ...)` as
  today. Value mode: `bps = _sharedRead(c) * paidShareBps / BPS`, then `_drop` on the shared anchor as today, never
  under its floor. The share is unit free, so one rule serves both instances.
- Consequences to state in the code comment and SPEC section 4: the price state after a cheap listing is the ask less
  its drop and recovers at the climb; `lastFillRate` becomes the ask rate, so the pot multiplier `m` reads more pages
  until the next fill (bounded by `climbMultiplierCapBps`); the remembered peak is `max(ask rate, peak now)`, so the
  ceiling's peak term still holds the posted level for its half life. This item lowers the next bids for the recovery
  period; it does not remove the ceiling ratchet (that is decision 176, deferred).
- `ListingBought` keeps its fields; `rate` is still the stored rate after the fill.

Tests: `test/BidRule.t.sol` "buyListing is one fill at the bid" becomes "at `min(bid, ask)`": a listing at a tenth
of the bid leaves `rateAtCheckpoint` equal to the ask rate less the drop and `lastFillRate` equal to the ask rate; a
listing at the bid is unchanged from today; a direct sale is unchanged. `test/utils/BidModel.sol` gains the paid
share so the invariant handlers and `invariant_21_ethBidEqualsNextFill` model it; `test/Seaport.t.sol` and
`test/SpendCap.t.sol` (the keeper fill shares the budget) adjusted where they assert the old drop. Interfaces
regenerated (`ICoreLib` changes), pins redone.

## 5. Docs

- docs/SPEC.md: section 1 rows (decision 177), section 3 `rateCap`, section 4 the listing drop, section 6 the doors
  under pause and `ethBidOn`, section 11 owner powers, section 14 the arbitrage risk row.
- docs/INDEXER.md section 9: `ethBidOn` and `paused` as live reads for the sell page and the keeper.
- docs/DECISIONS.md: 177 recorded; 46, 60, 69 amended on the cap; 81 and 97 amended on the pause scope.
- docs/STATUS.md: the baton.

## 6. Out of scope, on purpose

The time-path anchor, the token bucket budget, the savings share tip, the reference drift and the removal of the
ceiling, loosening, multiplier and peak. They wait on the market depth measurement decision 177 names: daily sales
and distinct sellers since 2026-10-07, and live listings within 2x of the opening bid. If the market is still deep,
the current climb is the better design and 176 stays a plan for a thin market. If it has thinned, packet 0 of
docs/reviews/SPEC-time-path-anchor-176.md starts.
