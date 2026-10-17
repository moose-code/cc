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

    cap  = ctl value rate (before _bidRoom) * score / RATE_SCORE * 1e18 / pSell
    paid = min(posted, cap)          // the Core still applies available() afterwards

Needs the Core to expose the un-clamped value rate (a new view, or `ethPrice()` bounded by `rateCap`, which already exists and is the pre-clamp price state). Core bytecode is 57 bytes over budget for new code, so use `ethPrice()` and have the controller apply `rateCap` itself.

## Candidate B (controller only)

The controller already owns the value rate: `valuePerPoint(true)` is the wei value of one point at `pSell`. Define the cap in tokens directly from it:

    capTokens = points(score) * POINT_UNIT_TOKENS * (1 - 0)   // the balance token amount whose sale value is the value rate
              = score * unit * balanceBidCapBps / 10_000      // bounded above by the cap bps of par

with the value rate and the sample reference agreeing by construction, since both come from `_protected`. No Core read and no `bidForScore` call, so the controller no longer depends on pot state at all. The posted amount (par less discount, already bounded by `balanceBidCapBps`) is then lowered only by `pSell` versus the reference band.

B removes the dependency instead of re-deriving it. It needs the controller to hold its own copy of the value rate ceiling (`rateCap`); A reuses the Core's.

## Loop closure each design keeps

Decision 165: a round trip through the balance route loses at least the spread, spread >= (1+tol)/(1-tol) - 1.
- Buy side pays at most the protected buy price (`pBuy <= ref*(1+tol)`).
- Balance payout is worth at most `valueRate * score` at `pSell >= ref*(1-tol)`.
Both A and B give a payout whose eth value at `pSell` is at most the un-clamped eth bid, which is at least the clamped bid. The un-clamped bid is the quantity the existing proof bounds (the pot clamp only lowers the eth door), so the inequality holds; the cap rises to the proof's own bound, no further. The pot never funds the balance payout, so no new solvency path opens.

## Controller byte impact

Estimate: A about +150 to +250 bytes (one extra read, one min). B about +100 bytes net (removes the `bidForScore` call, adds `unit` math). ControllerV1 has room; CoreLib and Core stay untouched.

## Test plan

1. ValueMode: drain `ethPot` to the reserve, fund the module; assert `balanceBidOf > 0` and `sellForBalance` pays `min(posted, cap)`.
2. Assert the loop-closure round trip (existing `test_balanceRoundTripLosesWhenSpotLeadsReference`) still loses at pot = reserve and at a full pot.
3. Unusable reference: still `(0, true)` and `ZeroAmount` (S02 rule).
4. ModeOffDifferential unchanged.

## Recommendation

Candidate B: derive the cap in the controller from the value rate and `pSell` so pot state cannot reach the balance route; the owner decides.
