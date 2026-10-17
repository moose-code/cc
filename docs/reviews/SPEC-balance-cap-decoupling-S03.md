# S03: decouple the balance cap from the eth pot clamp

Status: proposal for the owner. No code. Value mode is off at launch; `ControllerV1` is replaceable, so the change lands there.

## Current formula

`ControllerV1.balanceClampFor(score, posted)` (src/ControllerV1.sol, ~437):

    cap  = Core.bidForScore(score) * 1e18 / pSell
    paid = min(posted, cap)

`Core.bidForScore` is `ethRate() * score / RATE_SCORE`. In value mode `ethRate()` is `_valueRateOrLast(c).min(_bidRoom(c))` (src/lib/CoreLib.sol, ~525-531), where `_bidRoom` is `ethPot` plus the pending pot share less the reserve.

## Why the ETH clamp leaks in

The cap is meant to bound a cross-currency round trip: a payout in tokens is worth at most the eth bid when the engine sells the tokens. That bound depends on the value rate and on `pSell`. It does not depend on how much eth the pot holds. `_bidRoom` caps the eth bid so the pot never pays more eth than it has, which is correct for the eth door. Reading the same clamped number for the balance route makes the balance cap fall to 0 when `ethPot` is at the reserve, so `balanceBidOf` reports 0 and `sellForBalance` reverts `ZeroAmount` while the module holds a full `available()`. The balance route spends module tokens, not pot eth.

## Candidate A (audit)

Compute the cap from an un-clamped value rate and the protected sale price, then apply the module bound separately:

    cap  = valueRateUnclamped * score / RATE_SCORE * 1e18 / pSell
    paid = min(posted, cap)          // the Core still applies available() afterwards

Finding on `ethPrice()`: in value mode `CoreLib.ethPrice()` returns `_valueRateOrLast`, which is `min(sharedBps * valuePerPoint(false) * 100 / 10_000, rateCap)` before `_bidRoom` while the quote is usable, and the last stored eth instance rate while it is unusable. So it is the pre-clamp value rate (bounded by `rateCap`), not the eth Rate price state, and it is not pot-clamped. While the quote is unusable the cap is refused anyway (S02), so the fallback value is not read. A needs only a Core read through the existing `ethPrice()`; no Core change.

## Candidate B (controller only)

The controller computes the same un-clamped value rate itself and does not call `bidForScore`:

    valueRateUnclamped = min(sharedBps * valuePerPoint(false) * 100 / 10_000, rateCap)
    cap = valueRateUnclamped * score / RATE_SCORE * 1e18 / pSell

It needs `sharedBps` (a Core read) and `rateCap` (a Core setting read), so it reads the same inputs as A, in the controller. `balanceBidCapBps` bounds the eth instance, not balance tokens, and is not part of this cap. The posted amount lowered by `min(posted, cap)` stays as today.

A reuses the Core's own definition of the rate; B re-derives it and can drift from it. A is the smaller change and keeps one definition.

## Loop closure each design keeps

Both give a payout whose eth value at `pSell` is at most the un-clamped eth bid, which is at least the clamped bid. The existing proof bounds the un-clamped bid, since the pot clamp only lowers the eth door. With the buy side at most `ref*(1+tol)` and the sale side at least `ref*(1-tol)`, a round trip loses the spread, spread >= (1+tol)/(1-tol) - 1, and the spot-leads-reference case of decision 165 stays closed because `pSell` is in the denominator. The pot never funds the balance payout, so no new solvency path opens.

## Controller byte impact

Unverified estimate: A about +150 to +250 bytes, B about +200 to +300 bytes. ControllerV1 has room; CoreLib and Core stay untouched. Measure with `forge build --sizes` before deciding.

## Test plan

1. ValueMode: drain `ethPot` to the reserve, fund the module; assert `balanceBidOf > 0` and `sellForBalance` pays `min(posted, cap)`.
2. Assert the loop-closure round trip (existing `test_balanceRoundTripLosesWhenSpotLeadsReference`) still loses at pot = reserve and at a full pot.
3. Unusable reference: still `(0, true)` and `ZeroAmount` (S02 rule).
4. ModeOffDifferential unchanged.

## Recommendation

Candidate A: cap = the un-clamped value rate (`ethPrice()`) valued at `pSell`, then the module bound separately, so pot state cannot reach the balance route; the owner decides.
