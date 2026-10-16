# Decision 129: spend cap simulator and bounded exposure study

## Scope and behavior

The numerical simulator reads every new setting from the launch configuration. ETH purchases charge an integer-wei bucket ledger, including keeper payments and purchases while the cap is bypassed. The opening buying pot excludes the separate buyback and redeem reserves. The ledger captures the snapshot only after a successful purchase. Same-bucket deposits do not expand it. A cap change recomputes the limit from the retained snapshot, and a duration change rebases the active bucket while retaining its snapshot and spend. Unrelated settings and `setRate` retain spend. A failed purchase or batch restores the prior state. Balance purchases do not use this ledger.

The multiplier uses the last fill rate and scales ceiling loosening only. Balance conversion retains both configurable caps above par. The market runner preserves the separate recovery climb speed. Controller anchor movement uses the configured fraction with downward rounding; zero leaves its clock untouched. Zero balance floor remains zero. The credit sale floor follows `max(cost, valueOf(score))`, removing a stale flat-rate term that overstated low-score credits. Bounds follow the integer widths and semantic constraints of the revised Solidity settings.

## Frozen assumptions

Run command: `node sim/market.mjs --spendcap`. It prints these assumptions and every result as JSON. This is a bounded synthetic scenario, not a historical replay or a claim about eventual behavior.

- Seed: 129. Opening buying pot: 10 ETH. Opening reference bid: 0.025 ETH. Rate cap: 0.075 ETH.
- Inventory: 500 credits. Scores and counts: 150 points x 50, 300 x 100, 433 x 200, 600 x 100, 750 x 50. `refScore` is 4,330,000 stored score units, or 433 points.
- Flat scenario: every credit has a 0.005 ETH ask. Collapse scenario: every ask falls linearly from 0.025 to 0.005 ETH in 600 seconds, then holds.
- Sellers use the direct ETH bid door and receive the complete score-scaled quote whenever it covers their ask. They repeatedly offer the first eligible credit in a seeded inventory order per block. This measures direct seller exposure. Listing purchases pay the ask plus a bounded keeper payment and can spend less.
- Modeled blocks: 12 seconds. Bucket duration: 60 seconds. Starts: at a bucket opening and 48 seconds into a bucket, twelve seconds before its next boundary.
- Selling stops when inventory is exhausted or after 21,600 seconds (six hours), whichever comes first. Total modeled horizon: 86,400 seconds (24 hours). No deposits, fee income, sales proceeds, balance purchases, or owner changes.
- Caps: 50, 100, 200 bps. Other launch settings: drop 50 bps, drop floor 5,000 bps, climb 50 bps/min, recovery climb 200 bps/min, idle loosen 600 bps per 600 seconds, multiplier cap 40,000 bps, peak half life 21,600 seconds.
- Crossing: reference-score bid strictly below 0.005 ETH. In the collapse scenario measurement starts after the first 600 seconds. A credit of score `s` remains eligible when `referenceBid * s / 433 >= ask`; this differs from the reference-score crossing.
- Market recovery: after a downward crossing and after sellers stop, the reference bid returns to at least 0.005 ETH. If no crossing occurs, recovery is N/A. Initial-bid recovery to 0.025 ETH is a separate optional diagnostic in the JSON.

## Measured results

No reference bid crosses below 0.005 ETH in any of the twelve runs during the selling window. Therefore spend and count *until crossing* are censored at seller stop, shown below; market recovery is N/A for all twelve runs. The 50 and 100 bps cases do not exhaust the inventory within six hours.

| Scenario | Start offset (s) | Cap (bps) | Credits at stop | ETH spent at stop | Stop (s) | Reference bid at stop (ETH) | Remaining |
|---|---:|---:|---:|---:|---:|---:|---:|
| flat | 0 | 50 | 102 | 2.419741271 | 21600 | 0.075000000 | 398 |
| flat | 48 | 50 | 102 | 2.398642260 | 21600 | 0.075000000 | 398 |
| flat | 0 | 100 | 343 | 7.088959506 | 21600 | 0.046974477 | 157 |
| flat | 48 | 100 | 343 | 7.091499355 | 21600 | 0.046909576 | 157 |
| flat | 0 | 200 | 500 | 6.799040472 | 6252 | 0.014461661 | 0 |
| flat | 48 | 200 | 500 | 6.796220065 | 6204 | 0.014458491 | 0 |
| collapse | 0 | 50 | 102 | 2.397086858 | 21600 | 0.075000000 | 398 |
| collapse | 48 | 50 | 102 | 2.387695913 | 21600 | 0.075000000 | 398 |
| collapse | 0 | 100 | 343 | 7.089053821 | 21600 | 0.046974477 | 157 |
| collapse | 48 | 100 | 343 | 7.091864251 | 21600 | 0.046909576 | 157 |
| collapse | 0 | 200 | 500 | 6.798862759 | 6252 | 0.014461511 | 0 |
| collapse | 48 | 200 | 500 | 6.778904673 | 6204 | 0.014417689 | 0 |

The cap limits aggregate bucket spending; it does not force a stale bid to converge to market. At 50 bps the remaining eligible credits eventually cost more than the new bucket budget. Fills stop, the idle bid climbs to its 0.075 ETH hard cap, and 398 credits remain. At 100 bps 157 credits remain at the six-hour horizon. Raising the cap to 200 bps buys all 500 credits while the reference bid remains above market. These are observed limitations of the approved design, not simulator targets to tune away.

The boundary-adjacent start gives another budget after twelve seconds. Its effects are included in the second start offset for each scenario. This is an explicit boundary stress case, not a rolling-window guarantee.

## Verification and limits

- `node sim/engine.test.mjs`: passed, 1,917 checks. Focused simulator file, including cap equality, one wei overflow, bypass toggling, original snapshot retention, duration rebase, rejected purchase state, batch rollback, balance exemption, zero floor, anchor movement and separate climb behavior.
- `node sim/market.mjs --spendcap`: passed, twelve bounded runs, with assumptions and seed printed. The historical 108-combination market grid was not run.
- Integer comparison vectors use BigInt, including 100 ETH snapshot / 50 ETH spend / 5,000 bps and the 500-denominator balance holding with balance cap 20,000, multiplier cap 40,000 and last fill 20,000 producing multiplier 31,250 bps. These are shared test inputs for comparison with Solidity, not proof of an executed cross-runtime differential test.
- Market prices and rate trajectories remain JavaScript Number calculations. Wei conversions and width checks cannot recover precision already lost in a Number input. The integer helper vectors avoid that limitation; market totals are economic estimates. The simulator does not replace Solidity boundary or overflow tests.
- Old whole-simulation assertions requiring fixed market ratios or fixed willingness-to-pay effects were removed: those thresholds were not product guarantees and depended on superseded launch values and the incorrect low-score sale floor. Focused rate-cap, accounting and acquisition checks remain.

`node --check sim/engine.js`, `node --check sim/market.mjs`, and `git diff --check` also passed. The launch config used for verification was copied from the parent implementation and is not part of this simulator commit.

The parent implementation owns Solidity verification, generated interfaces, build identities, independent candidate review and the single frozen candidate gate. No deployment or transaction is part of this packet.
