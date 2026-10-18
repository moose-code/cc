# Design review: the eth bid in a funded quiet period, against main f843f5a

Date 2026-10-18. Independent design review requested before mainnet deployment. Scope: the rules of the eth
acquisition routes (`sellForEth`, `buyListing`) and the price state behind them (`CoreLib._climb`, `_drop`,
`spend`), at the launch config `script/config/mainnet.json`. No production contract, script, config or test
changed. Evidence: the source at f843f5a; a minute-step model of the current and proposed dynamics
(scratchpad `bidmodel.py`, tables below; 440 point credits, 10 eth pot, market equal to the opening rate
unless stated). The model is synthetic; forge did not run.

## 0. Premise note, added 2026-10-18 after the owner's challenge

This review models a patient seller against a blind bid and omits the environment around it. The engine's bid and the
marketplace floor are both public, so whenever the bid is above the floor for a score, a bot buys the floor listing and
sells it to the engine directly at the bid within a block, with no tip. In a deep market the bid is therefore pinned one
block above the floor; the climb and loosening are only catch-up speed when the floor is above the bid, the ratchet
anchors on the floor, and a crash costs one burst of stale bid fills bounded by the drop. The quiet period premium of
sections 1 and 5 needs a market thin enough that no competitor undercuts a waiting seller.

The calibration data in sim/data/notes.md (window to 2026-10-06) shows a deep market with 13.7k holders and 12.5k
distinct sellers, and a volume that fell a hundredfold over the window (1,327 eth on mint day, 12 eth on the last day).
Which regime holds now is not in the repository. Decision 177 defers the time-path anchor until it is measured and
proceeds with the items that are right in both regimes (docs/reviews/SPEC-acquisition-safety-177.md). The arbitrage
also means the engine pays about its bid for listed supply and keeps little of the listing discount; the listing tip
pays its finder only where the gap is under the arbitrage's gas.

## 1. What the code does today, and the defect

- The eth bid is a price state `r` that climbs 2 percent a minute toward `min(ceiling, rateCap, pot)`.
- The ceiling is `1.1 * max(lastFillRate, peakNow) * (1 + 0.06 * m * floor(idle / 10 min))`, `m` up to 4
  when the pot covers four pages at the last fill rate (6.9 eth at launch). At a 10 eth pot the ceiling grows
  24 percent per idle 10 minutes and the state rides it: 2x the opening at 40 minutes, `rateCap` 3x at 80.
- `lastFillRate` and `peakRate` are written by every fill with the **posted** price state, in `buyListing` as
  well as `sellForEth` (`spend` passes `c.rateAtCheckpoint`, not the listing value). A fill of one 80 point
  credit at the climbed price therefore re-bases the ceiling at 110 percent of that price, and the peak holds
  it for a 6 hour half life. Idle time buys the premium; a fill locks it in. That is the ratchet named in
  docs/reviews/DESIGN-value-pricing-f1101cb.md F0 and accepted in decisions 151 and 155.
- `spendCapBps` is 10,000 (off). The pot less the reserve is the only bound on eth out.
- `setPaused` does not touch `sellForEth` or `buyListing`. No single owner call halts acquisition.

The defect is structural, not a number: fills are seller timed, so a fill at price P proves only that the
market is **at or below** P. The design uses that upper bound as a lower bound for the next ceiling.

## 2. The achievable safety property

Without an external price signal the engine cannot bound overpayment relative to market: a patient seller
and a repricing market are the same observation (funded, bidding, no fills). What can be bounded:

**P1 (per unit, adversary independent).** For every sequence of public calls,
`ethRate() <= min(rateCap, R_owner * (1 + u)^((now - t_owner) / 60))`, where `(R_owner, t_owner)` is the
last `setRate` or the deployment, and no public call raises the price state or its anchor. Time alone
raises the bid, at `u`; fills only lower it.

**P2 (eth per hour).** `spendCapBps` of the bucket's opening pot per `bucketSeconds`. This is the only bound
on total eth at risk other than the pot itself, and the only thing that creates owner reaction time.

Residual risk, stated plainly: a seller who waits T gets the premium `(1 + u)^T` on one burst, the burst
bounded by the drop (about 20 credit prices at the top: `1 / 0.0506`); the engine lags a market that moves
faster than `u` and stops at `rateCap` regardless; when the anchor is wrong, only volume (the anchor drop
below) or the owner corrects it, so a patient seller with inventory still drains the pot over a day at the
cap premium unless P2 binds. P1 bounds the price per credit; P2 and the pot bound eth at risk. Neither
bounds overpayment against the true market.

## 3. The recommended change: a time-path anchor

State per eth instance (reuse the `Anchor` slots):

| field | meaning |
|---|---|
| `rateAtCheckpoint`, `checkpointTime` | the price state `r`, as today |
| `anchorRate`, `anchorTime` | the anchor `A` (replaces `peakRate`, `peakTime`) |
| `lastFillTime` | unchanged |
| `minuteStartRate`, `minuteBucket` | unchanged (`dropFloorBps`) |

Settings: `climbPerMinBps` becomes the anchor climb `u` (slow); `recoveryClimbPerMinBps` stays the price
state climb `f` (fast; the bound `f >= u` exists). New `anchorDropPer100PointsBps` (`delta`, bound
`0 <= delta <= dropPer100PointsBps`). New `ethBidOn`. `ceilBps`, `idleLoosenBps`, `idleStepSeconds`,
`climbMultiplierCapBps`, `pointsPerPage`, `peakHalfLife`, `recoveryGapBps` lose their job: remove them, or
for a smaller pre-launch diff neutralize them in the config (`ceilBps` 10,000, `idleLoosenBps` 1,
`idleStepSeconds` uint32.max, `climbMultiplierCapBps` 10,000) and have `Checks.sol` assert the neutral values.

Read at `now` (`clamp` is `_bidRoom`, as today):

```text
A_now = A                                   if A >= clamp (decision 44: an unaffordable bid earns no climb)
      = min(rateCap, clamp, A * (1+u)^((now - anchorTime)/60))   otherwise
r_now = min(A_now, r * (1+f)^((now - checkpointTime)/60))         (no climb above clamp, as today)
read  = min(r_now, clamp)
```

Fill of score `s` paying rate `P` (`sellForEth`: `P = r_now`; `buyListing`: `P = min(r_now, value * RATE_SCORE / s)`):

```text
r := P * (1 - dropPer100PointsBps * s / RATE_SCORE)        (today's formula, floored as today)
A := A_now * (1 - anchorDropPer100PointsBps * s / RATE_SCORE)
anchorTime := checkpointTime := lastFillTime := now
```

`setRate(x)`: `A := r := x`, both clocks to now. `ethBidOn = false`: both eth doors revert `EthBidOff`;
turning it on sets both clocks to now so off time earns no climb. Batches: one checkpoint, then the two
formulas per credit, as today. Value mode's shared instance gets the same semantics; its cap stays
`balanceBidCapBps`. Flag: decision 152 relied on idle loosening for the shared instance's creep above par;
under this rule it climbs at `u` from the floor. Value mode is off at launch; revisit before the switch.

Why `A` is not pulled down to a cheap listing's ask: one 80 point credit listed at a tenth of the bid would
otherwise halt acquisitions for hours at a cost of 0.004 eth. Lowering the anchor must cost volume, so the
drop per fill is bounded; the cheap ask lands in `r`, which recovers at `f`.

Why no pause and reopen: a pause keyed to time since the last acquisition is seller timed; a cliff at the
timeout is raced (sell the whole burst the block before); a reopening at 25 percent that recovers at a rate
is a sawtooth whose envelope is the recovery rate, so the attacker gets the envelope and honest sellers get
the dead time. A rule whose envelope is a function of time only, with no cliff, is the same idea without the
two holes. Disabling direct sales while listings stay open removes nothing: a self listing at the bid pays
the seller the same eth and costs the engine the keeper payment on top.

## 4. Numbers (minute model, 10 eth pot, 440 point credits, market = opening rate, royalty excluded)

Best patient seller over a grid of selling intervals, eth paid above market:

| design | 2x at | 3x at | 1 h | 6 h | 24 h (eth paid) |
|---|---|---|---|---|---|
| current launch | 40 min | 80 min | 0.31 | 2.29 | 4.40 (9.64) |
| proposed u 30, f 200, delta 25 | 232 min | 367 min | 0.01 | 0.38 | 4.09 (9.63) |
| proposed u 20 | 347 | 550 | 0.01 | 0.15 | 2.49 (6.52) |
| proposed u 15 | 463 | 733 | | 0.09 | 1.54 |
| proposed u 10 | 694 | 1100 | | 0.04 | 0.72 |
| proposed u 30, delta 50 | 232 | 367 | 0.01 | 0.38 | 2.57 (5.96) |
| proposed u 30, spend cap 25 %/h | 232 | 367 | | 0.38 | 3.10 (7.48) |
| proposed u 30, spend cap 10 %/h | 232 | 367 | | 0.38 | 1.64 (5.31) |

The first hours improve 6 to 30 times. The day does not, unless `u` is low or P2 binds: once the anchor sits
at `rateCap`, the drain is the sustained throughput `60u / delta` credits an hour at the cap. The dynamics buy
time and visibility, not a daily bound.

Flat market, a greedy seller every minute (the throughput cost): current 22.9 fills an hour at 1.010x
market; proposed delta 25: 16.2 at 1.002x; delta 50: 8.1; f 50: 5.8. Market halves at t 0 with greedy
sellers: both designs pay about 0.1 eth over market in 24 hours and converge (greed, not the engine, holds
the bid at the market when sellers are present; the risk is the patient seller).

## 5. Adversarial sequences

| sequence | current | proposed (u 30, delta 25) |
|---|---|---|
| funded quiet hour, then dump | bid 2.68x; 20 credits sold above market, 0.31 eth over; anchor left at 2.68x, next burst minutes later | bid 1.20x; 4 credits, 0.01 eth; anchor 1.15x after |
| sale the block before a timeout | n/a (no timeout today) | n/a: no cliff exists. In the pause draft this sale takes the whole burst at the full bid and the engine then idles at 25 percent |
| one 80 point self listing after an hour idle | locks the loosened ceiling in: the peak and last fill become the posted price (probe: bid 10 min later 3.00x against 2.95x with no fill; the peak then holds it 6 h) | lowers `A` by 0.2 percent and `r` to the ask drop; nothing is raised |
| repeated small fills to ratchet a reference | every fill re-bases the anchor at the posted price | `A` is non-increasing across fills by construction |
| batch direct sale of n credits | prices `r, r(1-d), ...`; at most `r / d` (about 20 credit prices) per burst; the anchor keeps the posted top | same per burst bound; `A` falls `(1-delta_s)^n`; P2 bounds the hour |
| genuine 5x overnight | 3x in 80 min, then `rateCap` holds; 5x needs the owner | 3x in 6.1 h (9.2 h at u 20), then `rateCap`; 5x needs the owner: `setSettings(rateCap)` then `setRate` |

## 6. Owner controls

Exists: `setSettings` (instant; lowering `rateCap` caps the read at once, and a checkpoint then stores the
lower state), `setRate` within `rateCap`, `spendCapBps` and `bucketSeconds`, `setPaused` (sales only),
`balanceBidOn` (balance route only), adapter approval (listing route only), `migrate`.
Missing and recommended before deployment: `ethBidOn`, one switch for both eth doors, named error, price
state untouched, off time excluded from the climb. Recommended at launch: `spendCapBps` 2,000 to 2,500 with
`bucketSeconds` 3,600 (normal flow at market is about 4 percent of a 10 eth pot an hour, so the cap binds only
when an hour pays several times normal value; it guarantees at least three hours before half the pot is gone).
Operational: alerts on bid over opening, eth out per hour, and hours idle at the cap.

## 7. Tradeoffs and tests

Tradeoffs: sustained flat market throughput falls from about 23 to about 16 credits an hour (delta 25); the
engine follows a rising market at `u` (12 to 20 percent an hour) instead of 2 percent a minute; a Settings
layout change touches interfaces, build pins, `Checks.sol`, the keeper's `decide.ts`, `sim/engine.js`, the
web settings view and SPEC sections 3 and 4 (the neutralize variant avoids the layout change). The goals
"never pay a quiet premium", "follow any repricing speed" and "never block volume" are not jointly achievable
without a price signal; `u` is the explicit choice of the fastest market move the engine follows unaided.

Focused tests (each with a `// promise:` line):
1. a fill at any score and any paid rate leaves `anchorRate <= A_now` before the fill (direct and listing).
2. the time path bound: after a random sequence of `fund`, `book`, `sellForEth` batches, `buyListing` with
   asks in `[1, bid]`, time warps, `ethRate() <= min(rateCap, R_owner * (1+u)^dt)`; and no non-owner call
   increases `anchorRate` or `rateAtCheckpoint`.
3. `A` and `r` earn no climb while `A >= clamp` (empty pot) and none across an `ethBidOn` off period.
4. a listing at a tenth of the bid: `r` after is at most the ask less the drop; `A` after is exactly
   `A_now * (1 - delta_s)`, not the ask.
5. `ethBidOn` false reverts both eth doors with the named error and leaves `sellForBalance`, compose, sales,
   redemptions and booking live.
6. `setRate` restates `A` and `r` and restarts the bound's clock.
7. a batch of n credits pays at most `P * (1 - (1-d)^n) / d` and lowers `A` by `(1 - delta_s)^n`.
8. no cliff: `A(t + 1 min) / A(t) = 1 + u` for an idle funded engine until `rateCap`.
9. spend cap with hourly buckets: eth out in any hour is at most the budget plus one credit (first purchase rule).
10. `Checks.sol` asserts the neutral values if the neutralize variant ships.
Stateful: an invariant handler playing the patient seller (sell every k minutes while bid > a hidden
market), the self listing adapter and the small credit lock-in, asserting 1 to 3 after every call; the sim
(`sim/engine.js`) re-run with the new instance so the exposure grids in decision 146 and 151 are re-derived.
