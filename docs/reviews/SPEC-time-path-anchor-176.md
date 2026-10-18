# Time-path anchor: the implementation spec after decision 176

Date 2026-10-18. Base: main `f843f5a`. Source of each rule: decision 176 and the design review
docs/reviews/DESIGN-bid-time-path-anchor-f843f5a.md with the owner discussion that followed it. Nothing here is built.
No deployment authority. Items marked **open** carry a proposed default; the owner confirms them before packet A
ships, and the sim of packet 0 is the evidence for the numbers.

## 1. What changes and what does not

The two routes stay: `sellForEth` for single and batch direct sales at the posted bid, `buyListing` for a signed
listing at its ask. The owner rejected an auction. What changes is the price machine behind both routes, the pause,
the owner switches, the listing tip and the spend bound.

Principle: the bid path reads three inputs and no other. Time raises it. Volume bought lowers it. The owner sets it.
Fill prices and fill timing are seller chosen, so no rule reads them to raise anything.

## 2. State of one bid instance

The eth instance keeps its fields inline in `State` at their slots (`CoreLib.Rate` and `CoreLib.Anchor`); the value
mode shared instance is `State.balance`. The `Anchor` fields are repurposed, the slots do not move:

| field today | field after | meaning |
|---|---|---|
| `rateAtCheckpoint`, `checkpointTime` | unchanged | the price state `r` and its clock |
| `lastFillTime` | unchanged | time of the last fill |
| `Anchor.lastFillRate` | `Anchor.referenceRate` | `R`, the owner reference: `rateStart` at deploy, restated by `setRate` |
| `Anchor.peakRate`, `Anchor.peakTime` | `Anchor.anchorRate`, `Anchor.anchorTime` | `A`, the anchor and its clock |
| `Anchor.minuteStartRate`, `Anchor.minuteBucket` | removed (**open**, default remove) | the minute floor of `dropFloorBps`, off since decision 146 |

`test/CoreLayout.t.sol` pins the slots and is updated with the renames. Removing the two minute floor words leaves a
gap unless the struct is repacked; repack only if the layout test and the pins are redone in the same packet.

## 3. Settings

Removed: `ceilBps`, `idleLoosenBps`, `idleStepSeconds`, `climbMultiplierCapBps`, `pointsPerPage`, `peakHalfLife`,
`recoveryGapBps`; `dropFloorBps` and the drop use of `bucketSeconds` with the minute floor (**open**).
`spendCapBps` and `bucketSeconds` are replaced by the budget of section 8.

Re-meant, same names:

| setting | meaning after | bound |
|---|---|---|
| `climbPerMinBps` | `u`: the climb of `A` per minute above `R`, compounded | 1 to 65,535 |
| `recoveryClimbPerMinBps` | `f`: the climb of `r` toward `A` per minute, and of `A` toward `R` while below it | at least `climbPerMinBps` |
| `dropPer100PointsBps` | `d0`: the drop of `r` per 100 points at `A <= R`; the effective drop is `d0 * (A / R)^2` | 1 to 9,999 |
| `rateCap` | the fuse on one credit's price: `A` and `r` never read above it | 5 times `rateStart` at launch (`Checks.sol`) |

New:

| setting | meaning | bound |
|---|---|---|
| `anchorPullBps` | `k`: the share of the gap `A_now - P` a fill paid below the anchor removes from `A`, weighted by `min(1, score / RATE_SCORE)` | 0 to 10,000 |
| `ethBidOn` | the eth routes run (`sellForEth`, `buyListing`); the mirror of `balanceBidOn` | bool |
| `tipSavingsBps` | the share of `bid - value` added to the `buyListing` caller payment | 0 to 10,000 |
| `budgetRefillBpsPerHour` | the eth budget refill per hour, bps of the pot (section 8) | 0 to 65,535; 0 turns the budget off |
| `budgetBurstBps` | the most the budget holds, bps of the pot | 1 to 65,535 |

`SettingsBounds.firstViolation` drops the removed rows and adds the new ones. `Settings` is five packed slots today;
the implementer repacks it and regenerates the interfaces (`script/tools/gen-interfaces.sh`), `SettingsFields.sol`,
`LaunchConfig.sol`, the three configs, `Mainnet.defaultSettings()` and the `Config`, `Launch` and `Flow` asserts.
`setSettings` keeps its checkpoint before the store and loses the `peakHalfLife` restatement; a change of `ethBidOn`
from false to true sets `checkpointTime` and `anchorTime` of the eth instance to now.

## 4. The read

`clamp` is `_bidRoom`: the pages pot less the reserve over `1 + buyToArtistBps / 10,000`, as today. `cap` is
`rateCap` for the eth instance and `balanceBidCapBps` for the shared one. All climbs are the existing `_climbTo`
(wad log of one minute's growth, whole minutes).

```text
A_now:  if A >= clamp                 A                                   (decision 44: an unaffordable bid earns no climb)
        else if A < R                 min(R, clamp, climbTo(A, f, dt_A))   then, with the remaining minutes, the slow climb from R
        else                          min(cap, clamp, climbTo(A, u, dt_A))
r_now:  min(A_now, climbTo(r, f, dt_r))  while r < min(A_now, clamp); a stored r at or above A_now reads A_now
read:   min(r_now, clamp)                `ethRate()`; `ethPrice()` is r_now; `floorRate()` is A_now
```

`dt_A` is `now - anchorTime`, `dt_r` is `now - checkpointTime`. A checkpoint stores `A_now` and `r_now` with both clocks
at now, as `checkpoint()` does for `r` today; the Core still checkpoints before every pot change and before a settings
write. Below `R` the anchor recovers at `f`; the crossing from `f` to `u` at `R` is one `_climbTo` to `R`, then the
remaining minutes at `u`, continuous and monotone in `now`.

## 5. The fill

`spend(cost, score, paidRate)` replaces `spend(cost, score)`. `paidRate` is the rate the credit cleared at, wei per
100 points: `sellForEth` passes the bid it paid (`r_now` after the previous credit of the batch); `buyListing` passes
`min(r_now, value * RATE_SCORE / score)`.

```text
P      = paidRate                                 at most r_now, so at most A_now
w      = min(RATE_SCORE, score) / RATE_SCORE       a 100 point credit weighs 1, smaller credits less
A     := A_now - k * (A_now - P) * w               a fill at the anchor moves nothing; A never rises on a fill
d_eff  = d0 * A_now^2 / R^2                        bps per 100 points, computed in mulDiv, at most 9,999
r     := P * (1 - d_eff * score / RATE_SCORE)      the existing bound at 10,000 and the existing rounding
anchorTime := checkpointTime := lastFillTime := now
emit EthRateFill(spent, r, A, pot)                 the event gains the anchor (ABI change; the indexer follows)
```

Properties the implementer tests, each as a `// promise:` line:

1. no non-owner call raises `anchorRate` or `rateAtCheckpoint`; only time does, and only while the pot affords the bid
   and the route is on and not paused.
2. `rateAtCheckpoint <= anchorRate` after every call (`A := A_now - k * gap * w >= P * (1 - drop)` since `k <= 1`).
3. the time path bound: after any sequence of `fund`, `book`, `sellForEth` batches, `buyListing` at asks in `[1, bid]`,
   pauses and time warps, `ethRate() <= min(rateCap, R_owner * (1 + u)^((now - t_owner) / 60))` where `(R_owner,
   t_owner)` is the last `setRate` or the deployment.
4. a listing at a tenth of the bid: `r` after is at most the ask rate less its drop; `A` after is `A_now - k * 0.9 *
   A_now * w`, not the ask.
5. a batch of n credits of equal score walks `r` down by `(1 - d_eff)` per credit with `d_eff` re-read from the moving
   `A`, and never raises `A`.
6. no cliff: with an idle funded engine, `A(t + 1 min) / A(t) = 1 + u` above `R` until `rateCap`.
7. lowering `A` by x through fills costs the sellers at least `x / k` of discount actually given (the sum of
   `(A_now - P) * w` over the fills).

## 6. Owner calls

- `setRate(x)`: `R := A := r := x`, both clocks to now; `x` within the rate bounds and at most `rateCap`, as today.
- `setSettings`: as today, with section 3.
- `setPaused(true)` stops everything that moves value out of the pot or changes price: `_openDoor()` gains
  `if (s.paused) revert Paused()`, which covers `sellForEth`, `sellForBalance`, `buyListing`, `adopt`, `compose` and
  `composeChosen`; `buyback` gains the same check; `sellTo`, `sellCreditTo` and `swapCredit` keep theirs. Live through
  a pause: `fund`, fee booking, `collectEscrow`, `redeemStatement` (a holder right paid by the module, callable while
  paused and after migration today, unchanged), every view, every owner call. `setPaused(false)` sets `checkpointTime`
  and `anchorTime` of both instances and `budgetTime` to now, so paused time earns no climb and no refill, the same way
  statement age excludes paused seconds.
- `ethBidOn` false: `sellForEth` and `buyListing` revert `EthBidOff`; everything else runs. Turning it on resets the
  eth instance clocks (section 3).

## 7. The listing route

`value <= bid` and `value + toArtist <= room` as today. The caller payment becomes

```text
paid = min(gas refund + keeperFee + (bid - value) * tipSavingsBps / 10,000,  bid - value,  room - value - toArtist)
```

so the pot pays at most the bid plus its royalty for the credit, as today, and a cheaper listing pays its finder more.
The fill passes `min(r_now, value * RATE_SCORE / score)` as `paidRate` (section 5). The keeper's `listingPayment`
in `keeper/src/decide.ts` mirrors the formula.

## 8. The budget (**open**: on or off at launch; default on with the numbers of section 10)

A token bucket in wei replaces the minute bucket of `Spend`:

```text
state:      budgetAvailable (uint128), budgetTime (uint64), budgetFull (bool)
available:  min(burst, budgetAvailable + pot * refillBpsPerHour / 10,000 * dt / 3600), burst = pot * burstBps / 10,000
purchase:   passes when cost <= available, or when the bucket is full (budgetFull): a full bucket always buys one credit
            available := available - cost floored at 0; budgetFull := false; budgetTime := now
off:        refillBpsPerHour 0 and burstBps at its bound: every purchase passes, nothing is tracked
```

`pot` is `ethPot` at the read. `spendState()` becomes `budgetState()`; the keeper reads it in place of the bucket.
`SpendCapReached` becomes `BudgetReached(available, cost)`. The `valueModeOn` rule that the cap must be active stays
in the form "the budget must be on while value mode is on" (**open**, default keep).

## 9. Value mode and the shared instance

The shared instance runs the same code with `R` fixed at par (`BPS`), the floor `BPS - balanceBidMarginBps` and the
cap `balanceBidCapBps`: `A` recovers fast up to par and explores slowly above it, the drop scales with `(A / par)^2`.
This restates decision 152's creep above par through idle loosening. Value mode is off at launch and the switch resets
the instance to its floor as today; the numbers are decided at the switch. The code path compiles and is tested in
packet A because `_climb` and `_drop` are shared.

## 10. Numbers proposed for launch (packet 0 confirms or replaces them)

| setting | value | why |
|---|---|---|
| `rateStart` | 4.9e15 wei per 100 points | unchanged |
| `rateCap` | 5 times `rateStart` | decision 176; a fuse on one credit, no longer the bound on the chase |
| `climbPerMinBps` (u) | 20 | 12.7 percent an hour: 2x in 5.8 h, 5x in 13.5 h |
| `recoveryClimbPerMinBps` (f) | 200 | as today: a 1 percent drop recovers in half a minute |
| `dropPer100PointsBps` (d0) | 23 | 1 percent per 440 point credit at `R`; 4 at 2x; 9 at 3x; 25 at 5x |
| `anchorPullBps` (k) | 500 to 1,000 | one cheap fill moves `A` at most 5 to 10 percent of the gap |
| `tipSavingsBps` | 2,500 | decision 69's share, reinstated |
| `budgetRefillBpsPerHour` | 2,500 | binds only when an hour spends several times normal flow |
| `budgetBurstBps` | 5,000 | a launch wave or a deep market clears at once |
| `buyToArtistBps`, `reserveWei`, `returnLockSeconds`, fees | unchanged | |

Model results at these shapes (docs/reviews/DESIGN-bid-time-path-anchor-f843f5a.md section 4, 10 eth pot, 440 point
credits): bid after a quiet hour 1.13x against 2.68x today; patient seller six hours 0.15 eth over market against
2.29; a deep flat market at `R` clears about 120 credits an hour before the budget binds; at 3x about 11 an hour.

## 11. Implementation plan

Each packet is one pull request against main, in order. Each follows AGENTS.md: `forge build`, then `forge test
--match-path` for the test files touched, nothing more; `git checkout foundry.lock; git submodule update --
lib/solady` after a forge run; after a change of a production contract's external surface `script/tools/gen-
interfaces.sh`, then re-pin `script/Checks.sol` and `test/BuildIdentity.t.sol`. Core has 538 bytes of headroom:
new arithmetic goes into CoreLib, Core gains only the pause line, the switch line and the tip call. No merge, push to
main or deployment without the owner's instruction.

**Packet 0, the sim (no contract change).** Add the anchor instance to `sim/engine.js` beside the current one (or a
`sim/anchor.mjs` that reuses its arrivals), with `R`, `A`, `r`, `k`, the squared drop and the token bucket. Re-run the
grids of decisions 146 and 151 plus: patient seller at selling intervals from 1 minute to 6 hours over 1, 6 and 24
hours; a quiet hour then a dump; a launch wave of 500 credits in one block; a crash to 0.3x with greedy sellers; a deep
flat market at `R` with a 10 and a 100 eth pot; a rise to 1.5x and 3x with deep supply; one cheap self listing;
small credit lock-in attempts. Report eth over market, credits bought, fills landing at the anchor against below it.
Record the chosen numbers as decision 177 and close the open items of this spec in it.

**Packet A, the price machine.** CoreLib: the `Anchor` renames (section 2); `_climb` rewritten to section 4 and
`_recover`, `_climbMulBps`, the loosening and the peak halving removed (keep `Halving.sol`, the controller uses it);
`_drop` rewritten to section 5 with `spend(cost, score, paidRate)`; `floorRate()` returns `A_now`; `climbMultiplier()`
removed; `setSettings` per section 3; the `EthRateFill` event gains the anchor. Core: constructor sets `R = A = r =
rateStart`; `setRate` per section 6; `_openDoor` and `buyback` pause checks; `setPaused(false)` clock resets;
`ethBidOn` checks; `buyListing` tip and `paidRate`; `_sellForEth` passes the bid paid; the price basis reads of
decision 158 (`adopt`, `_moveEth`, `_ethFloorNow`) read `ethPrice()` and `floorRate()` as redefined; views
`anchorRate()`, `referenceRate()`. Tests: `test/utils/BidModel.sol` rewritten to the new machine (the invariant
handlers and the model suites read it); `test/BidRule.t.sol` rewritten around properties 1 to 7 of section 5 with hand
arithmetic; `test/CoreLayout.t.sol` slots; `test/SetSettings.t.sol` bounds and the `ethBidOn` clock reset; a
`test/Pause.t.sol` covering section 6 door by door; `test/invariant`: `invariant_06_rateFollowsTheModel`,
`invariant_16_theBidNeverCloses`, `invariant_19_bidBounds`, `invariant_20` (becomes the budget), `invariant_21` kept,
plus three new ones (no non-owner call raises `A` or `r`; `r <= A`; the time path bound against the handler's record
of the last `setRate`); `HandlerBase` and `HandlerOwner` gain a patient seller, a self listing adapter and the small
credit lock-in; `ColdAudit`, `Recovery`, `PerPoint*`, `ModeOffDifferential`, `ClampDifferential`, `Adopt`, `Sale`,
`Seaport`, `Fees`, `Flow`, `Launch`, `Config`, `ReviewDeploy` updated where they name a removed field or model the old
climb. Then gen-interfaces and the pins.

**Packet B, the budget.** `Spend` becomes the token bucket of section 8; `test/SpendCap.t.sol` becomes
`test/Budget.t.sol` (full bucket buys one credit; refill is pot proportional; a pause earns no refill; off means
untracked; the keeper fill shares the bucket with the direct seller). Separate from A so A can ship with the budget
off if the owner decides so.

**Packet C, configs and scripts.** `script/config/mainnet.json`, `anvil.json`, `rehearsal.json`,
`Mainnet.defaultSettings()`, `LaunchConfig.sol` parser, `SettingsFields.sol`, `SetSettings.s.sol` table, `Checks.sol`
("rateCap is 5 times rateStart", the sign off rows for the bid), `PostflightChecks.sol` (`anchorRate`, `referenceRate`
at `rateStart`), the `Config`, `Launch` and `Flow` asserts.

**Packet D, consumers and docs.** Keeper: `decide.ts` skips on `Paused` and `EthBidOff`, reads `budgetState()`, the
tip formula of section 7; `listings.ts` unchanged in shape. Indexer: `ponder.schema.ts` and `chain.ts` for the
settings fields and the anchor on `EthRateFill`; a derived "fills at the anchor" share. Web: the settings view, the bid
view showing `R`, `A` and `r`, the share of fills at the anchor, eth out per hour, hours at the cap; alerts for the
last two in the keeper. docs/INDEXER.md section 9 names each new value's source. docs/SPEC.md sections 1, 3, 4, 6, 11,
13 and 14 restated; decisions 50, 69, 128, 141, 146, 151, 152 and 155 marked superseded in part by 176 and 177;
docs/STATUS.md baton.

**Packet E, the candidate.** Freeze; `CANDIDATE_RUN=1` full suite, deep invariants, the fork rehearsal at the pinned
block; an independent review record in docs/reviews; re-pin. Deployment remains a separate owner instruction.

## 12. Open items for the owner

1. Budget on at launch with section 10's numbers, or off (`budgetRefillBpsPerHour` 0).
2. A time-only drift of `R` toward `A` (about 3 percent an hour) so a level held for a day becomes the reference
   without `setRate`. Not in this spec; it trades a day of owner reaction for less owner work. Add only with the budget.
3. Remove the minute floor (`dropFloorBps`, `minuteStartRate`, `minuteBucket`, the drop use of `bucketSeconds`).
4. The value mode mapping of section 9, decided at the switch.
5. `tipSavingsBps` 2,500.
6. `EthRateFill` gaining the anchor field against a separate `AnchorMoved` event.
7. The numbers of section 10, from packet 0.
