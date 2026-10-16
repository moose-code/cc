# Exposure grid: bid drop, climb and recovery climb against a stale bid (issue 129)

Settings grid over the credit bid at main 6930408 (PR 24 merged). Rules are the shipped rules in `sim/engine.js`; only `dropPerCreditBps`, `climbPerMinBps`, `recoveryClimbPerMinBps` and the pot vary. Source: `sim/grid.mjs` (`node sim/grid.mjs docs/reviews/EXPOSURE-129-grid.json`). Raw results, including per-hour series and the off-grid probe: `docs/reviews/EXPOSURE-129-grid.json`.

## Setup

- Grid: drop {50, 100, 200, 300, 500} bps, climb {50, 100, 200} bps per minute, recovery climb max(climb, {200, 400}), spend cap 100 bps, pot {10, 100} eth. 60 cells. A cell is written `drop/climb/recovery`.
- Held at launch values: drop floor 5000 bps, recovery gap 1000 bps, peak half-life 6 h, rate cap 0.075 eth, multiplier cap 40000 bps, idle loosening 600 bps per 600 s, ceiling 11000 bps, bucket 60 s, opening rate 0.025 eth at refScore 433 points.
- Dump (a): 500 credits, the nine census deciles (152 to 728 points) in equal share, seeded shuffle (seed 129), one seller. Each 12 s block the seller sells the first credit whose score-scaled bid covers the flat ask of 0.005 eth, repeatedly, until none clears or the spend cap stalls. Payment is the bid. Selling stops at 6 h or when the inventory is gone. Recovery is measured to a reference bid of 0.025 eth, observed to 48 h.
- Collapse (b): same inventory and seller; the ask falls linearly from 0.025 to 0.005 over 10 minutes and stays. The reference bid counts as under market from minute 10.
- Steady market (c): reference-score credits (433 points), 24 h. Unlimited sellers at a flat 0.020 ask, plus organic sellers (Poisson, 35 an hour, seed 130) that sell at the bid at any price and wait in a queue while the cap stalls. The pot is refilled to its starting value each block, so the run measures the rules at a funded pot. Credits per hour is the mean of hours 12 to 23. "No organic" repeats the run without the organic sellers. The 35 an hour is the organic arrival rate, not a fill rate: with a firm 0.018 ask and no pot top-ups, a 10 eth pot buys about 549 credits over 24 h and leaves about 305 arrivals queued.
- Launch wave (d): 200 reference-score sellers at open at the bid, with the case (c) sellers active, pot not refilled. Per fill the sellers rotate wave, organic, unlimited. Minutes are to the last of the 200 fills. "-" means the unlimited sellers drained the pot first.
- Horizons and block size are the specified ones; the whole grid runs in under one second, so the 10 minute budget left them as specified. Single seed per case; the inventory order is the only random input in (a) and (b), and (c) is averaged over 12 hours.
- Dump columns: "dump min under market" is minutes until the reference bid is under 0.005 ("pot empty" means the bid read 0 because the pot was gone, "-" means the reference bid never fell under 0.005); "dump eth after" is spent after that minute. Collapse eth is total spent. Limit: dump eth under 1 on the 10 eth pot, under 5 on the 100 eth pot.

## Results

| cell | dump eth | dump min under market | dump eth after | collapse eth | credits/h | credits/h no organic | bid h12-24 | wave min | limit |
|---|---|---|---|---|---|---|---|---|---|
| 50/50/200 pot 10 | 9.56 | - | - | 9.56 | 59.6 | 59.8 | 0.0199 | 138 | over |
| 50/50/400 pot 10 | 9.56 | - | - | 9.56 | 59.6 | 59.7 | 0.0199 | 138 | over |
| 50/100/200 pot 10 | 10.00 | pot empty | - | 9.95 | 119.2 | 119.1 | 0.0199 | 167 | over |
| 50/100/400 pot 10 | 9.96 | - | - | 9.97 | 119.1 | 119.1 | 0.0199 | 167 | over |
| 50/200/200 pot 10 | 9.97 | - | - | 10.00 | 237.8 | 237.8 | 0.0200 | - | over |
| 50/200/400 pot 10 | 9.97 | - | - | 10.00 | 237.8 | 237.8 | 0.0200 | - | over |
| 100/50/200 pot 10 | 4.52 | 41 | 1.42 | 4.50 | 35.4 | 29.8 | 0.0067 | 39 | over |
| 100/50/400 pot 10 | 9.36 | - | - | 9.35 | 35.4 | 29.8 | 0.0067 | 129 | over |
| 100/100/200 pot 10 | 4.55 | 41 | 1.42 | 4.57 | 59.3 | 59.4 | 0.0198 | 40 | over |
| 100/100/400 pot 10 | 9.50 | - | - | 9.49 | 59.3 | 59.4 | 0.0198 | 135 | over |
| 100/200/200 pot 10 | 4.73 | 44 | 1.37 | 4.73 | 118.3 | 118.3 | 0.0199 | 42 | over |
| 100/200/400 pot 10 | 9.95 | - | - | 9.95 | 118.3 | 118.2 | 0.0199 | 166 | over |
| 200/50/200 pot 10 | 2.50 | 13 | 1.32 | 2.50 | 35.4 | 14.8 | 0.0030 | 16 | over |
| 200/50/400 pot 10 | 3.49 | 17 | 2.02 | 3.48 | 35.4 | 14.8 | 0.0031 | 19 | over |
| 200/100/200 pot 10 | 2.51 | 13 | 1.32 | 2.51 | 35.4 | 29.6 | 0.0049 | 16 | over |
| 200/100/400 pot 10 | 3.49 | 17 | 2.02 | 3.49 | 35.4 | 29.5 | 0.0052 | 19 | over |
| 200/200/200 pot 10 | 2.52 | 14 | 1.32 | 2.52 | 58.8 | 58.8 | 0.0196 | 16 | over |
| 200/200/400 pot 10 | 3.50 | 17 | 2.02 | 3.50 | 58.7 | 58.8 | 0.0195 | 19 | over |
| 300/50/200 pot 10 | 1.53 | 8 | 0.79 | 1.56 | 35.4 | 9.8 | 0.0027 | 10 | over |
| 300/50/400 pot 10 | 2.77 | 9 | 1.96 | 2.84 | 35.4 | 9.8 | 0.0030 | 11 | over |
| 300/100/200 pot 10 | 1.54 | 8 | 0.79 | 1.57 | 35.4 | 19.6 | 0.0028 | 10 | over |
| 300/100/400 pot 10 | 2.78 | 9 | 1.96 | 2.84 | 35.4 | 19.6 | 0.0031 | 11 | over |
| 300/200/200 pot 10 | 1.55 | 8 | 0.80 | 1.58 | 38.3 | 39.0 | 0.0155 | 10 | over |
| 300/200/400 pot 10 | 2.79 | 9 | 1.96 | 2.85 | 40.8 | 39.0 | 0.0185 | 11 | over |
| 500/50/200 pot 10 | 0.88 | 4 | 0.45 | 0.90 | 35.4 | 5.8 | 0.0000 | 7 | ok |
| 500/50/400 pot 10 | 1.45 | 5 | 0.99 | 1.44 | 35.4 | 5.8 | 0.0028 | 7 | over |
| 500/100/200 pot 10 | 0.88 | 4 | 0.45 | 0.90 | 35.4 | 11.7 | 0.0000 | 7 | ok |
| 500/100/400 pot 10 | 1.45 | 5 | 0.99 | 1.44 | 35.4 | 11.7 | 0.0028 | 7 | over |
| 500/200/200 pot 10 | 0.88 | 4 | 0.45 | 0.90 | 35.4 | 23.2 | 0.0000 | 7 | ok |
| 500/200/400 pot 10 | 1.45 | 5 | 0.99 | 1.44 | 35.4 | 23.2 | 0.0043 | 7 | over |
| 50/50/200 pot 100 | 5.22 | 4 | 1.00 | 5.62 | 59.6 | 59.7 | 0.0199 | 3 | over |
| 50/50/400 pot 100 | 5.37 | 4 | 0.92 | 5.86 | 59.6 | 59.7 | 0.0199 | 3 | over |
| 50/100/200 pot 100 | 5.22 | 4 | 1.00 | 5.62 | 119.2 | 119.1 | 0.0199 | 3 | over |
| 50/100/400 pot 100 | 5.37 | 4 | 0.92 | 5.86 | 119.1 | 119.1 | 0.0199 | 3 | over |
| 50/200/200 pot 100 | 5.22 | 4 | 1.00 | 5.62 | 237.0 | 237.0 | 0.0199 | 3 | over |
| 50/200/400 pot 100 | 5.37 | 4 | 0.92 | 5.86 | 237.1 | 237.1 | 0.0199 | 3 | over |
| 100/50/200 pot 100 | 3.99 | 2 | 1.73 | 4.14 | 35.4 | 29.8 | 0.0067 | 2 | ok |
| 100/50/400 pot 100 | 4.03 | 2 | 1.75 | 4.26 | 35.4 | 29.8 | 0.0067 | 2 | ok |
| 100/100/200 pot 100 | 3.99 | 2 | 1.73 | 4.14 | 59.3 | 59.4 | 0.0198 | 2 | ok |
| 100/100/400 pot 100 | 4.03 | 2 | 1.75 | 4.26 | 59.3 | 59.4 | 0.0198 | 2 | ok |
| 100/200/200 pot 100 | 3.99 | 2 | 1.73 | 4.14 | 118.3 | 118.3 | 0.0199 | 2 | ok |
| 100/200/400 pot 100 | 4.03 | 2 | 1.75 | 4.26 | 118.3 | 118.3 | 0.0199 | 2 | ok |
| 200/50/200 pot 100 | 3.61 | 2 | 1.56 | 2.50 | 35.4 | 14.8 | 0.0030 | 2 | ok |
| 200/50/400 pot 100 | 3.69 | 2 | 1.62 | 3.40 | 35.4 | 14.8 | 0.0031 | 2 | ok |
| 200/100/200 pot 100 | 3.66 | 2 | 1.61 | 2.50 | 35.4 | 29.5 | 0.0049 | 2 | ok |
| 200/100/400 pot 100 | 3.69 | 2 | 1.62 | 3.40 | 35.4 | 29.6 | 0.0052 | 2 | ok |
| 200/200/200 pot 100 | 3.66 | 2 | 1.61 | 2.50 | 58.8 | 58.8 | 0.0196 | 2 | ok |
| 200/200/400 pot 100 | 3.69 | 2 | 1.62 | 3.41 | 58.7 | 58.8 | 0.0195 | 2 | ok |
| 300/50/200 pot 100 | 3.28 | 2 | 1.25 | 1.56 | 35.4 | 9.8 | 0.0027 | 1 | ok |
| 300/50/400 pot 100 | 3.65 | 2 | 1.60 | 2.83 | 35.4 | 9.8 | 0.0030 | 1 | ok |
| 300/100/200 pot 100 | 3.28 | 2 | 1.25 | 1.56 | 35.4 | 19.6 | 0.0028 | 1 | ok |
| 300/100/400 pot 100 | 3.65 | 2 | 1.60 | 2.83 | 35.4 | 19.6 | 0.0031 | 1 | ok |
| 300/200/200 pot 100 | 3.28 | 2 | 1.25 | 1.56 | 38.3 | 39.0 | 0.0155 | 1 | ok |
| 300/200/400 pot 100 | 3.65 | 2 | 1.60 | 2.83 | 40.8 | 39.0 | 0.0185 | 1 | ok |
| 500/50/200 pot 100 | 2.71 | 2 | 0.70 | 0.89 | 35.4 | 5.8 | 0.0000 | 1 | ok |
| 500/50/400 pot 100 | 3.46 | 2 | 1.44 | 1.43 | 35.4 | 5.8 | 0.0028 | 1 | ok |
| 500/100/200 pot 100 | 2.71 | 2 | 0.70 | 0.89 | 35.4 | 11.7 | 0.0000 | 1 | ok |
| 500/100/400 pot 100 | 3.60 | 2 | 1.57 | 1.43 | 35.4 | 11.7 | 0.0028 | 1 | ok |
| 500/200/200 pot 100 | 2.71 | 2 | 0.70 | 0.89 | 35.4 | 23.2 | 0.0000 | 1 | ok |
| 500/200/400 pot 100 | 3.61 | 2 | 1.58 | 1.43 | 35.4 | 23.2 | 0.0043 | 1 | ok |

## Reading

Two formulas from the finding, checked against the numbers.

**Throughput at a flat market is climb divided by drop fills a minute.** Without organic sellers the measured credits an hour sit 0 to 4 percent under 60 x climb / drop in every cell where the bid stays near the ask: 50/50 gives 59.8 (60), 50/100 gives 119.1 (120), 50/200 gives 237.8 (240), 100/100 gives 59.4 (60), 200/200 gives 58.8 (60), 300/200 gives 39.0 (40), 500/200 gives 23.2 (24), 500/50 gives 5.8 (6). The slow climb is the one that applies here: each fill resets the remembered peak to the price paid, so the bid stays within the 10 percent recovery gap of the peak. The organic sellers add 35.4 credits an hour at any price. Where climb / drop x 60 is under that flow the bid sinks (bid h12-24 of 0.0000 to 0.0067 against the 0.020 ask); where it is 58.8 or more the bid holds at 0.0195 to 0.0200. 300/200 sits between: 38.3 credits an hour in total and a bid of 0.0155.

**The price falls by fills per minute x drop x score ratio, less the climb.** In a dump the climb that applies is the recovery climb, because the remembered peak (half-life 6 h) stays far above the bid for the whole selling window. The dumper's equilibrium fill rate at the flat market is therefore recovery / (drop x mean score ratio of the credits that clear). Measured fills an hour in the last two selling hours against that prediction, on 10 eth cells where inventory was left: 500/./200 gives 15.0 (15.8), 300/./200 gives 28.0 (30.6), 500/./400 gives 35.5 (38.7), 300/./400 gives 87.5 (109.1). The prediction runs 5 to 25 percent high. The climb setting drops out of the dump entirely: for a given pot, drop and recovery, dump eth differs by at most 0.25 eth across climb 50, 100 and 200 wherever the pot is still funded at the end (500/./200 is 0.88 for all three). Climb 200 with recovery 200 therefore costs nothing in dump exposure and raises steady throughput fourfold over climb 50.

Resulting shape of the trade-off:

- Dump exposure is the cap-limited descent from 0.025 to 0.005 plus the drain at the floor. The descent costs about 0.4 eth at pot 10 and about 2 eth at pot 100 (spent before the crossing, drop 500), because the cap scales with the pot. The drain scales with recovery / drop. Raising drop shortens the drain; raising recovery lengthens it (500/./400 spends 1.45 against 0.88 on the 10 eth pot).
- Throughput scales with climb / drop, so a larger drop cuts it in the same proportion that it cuts the drain. With climb = recovery = 200, drop 500 gives 24 an hour and 0.88 eth, drop 400 gives 30 and 1.12 (off-grid probe, in the JSON), drop 300 gives 40 and 1.55, drop 200 gives 60 and 2.52, drop 100 gives 120 and 4.7. The 1 eth bar on the 10 eth pot is crossed between drop 400 and 500, and the 24 an hour ceiling is reached at drop 500.
- Drops of 50 let the dump take the pot: 9.56 eth of 10 on 50/50 and the whole pot once climb is 100 or more. On the 100 eth pot the 5 eth bar fails only at drop 50 (5.22 to 5.37).
- "Dump eth after" is positive. The market asks one flat price per credit while the bid scales with score: a credit with score ratio r clears while the reference bid is at least 0.005 / r, so the five census deciles at 440 points and above keep clearing after the reference bid is under 0.005 (down to 0.0030 for 728 points) and are paid 0.005 to 0.0084. Spend after the crossing is 0.45 eth on 500/200/200 at pot 10.
- Recovery to 0.025 after selling stops takes 103 minutes (pot 10) and 74 minutes (pot 100) on 500/200/200 after a dump, 105 and 102 minutes after the collapse. Larger drops recover more slowly because the bid ends lower (pot 10, climb 200: 30 minutes at drop 100, 73 at 200, 91 at 300, 103 at 500).
- Launch wave: on the 100 eth pot the 200 sellers clear in 1 to 3 minutes in every cell. On the 10 eth pot the cap sets the pace: 7 minutes at drop 500, 10 at 300, 16 at 200, about 40 at 100 with recovery 200 (129 to 166 with recovery 400), 138 or more at 50. At drop 50 with climb 200 the unlimited sellers drain the pot before the wave clears. Alone, without the case (c) sellers, the wave clears in 7 minutes on 500/200/200 at pot 10 and 1 minute at pot 100 (JSON, `wave.clearMinAlone`).

## Recommendation

A cell that meets the stated limits exists: **500/200/200** (dropPerCreditBps 500, climbPerMinBps 200, recoveryClimbPerMinBps 200, spendCapBps 100).

| Measure | pot 10 | pot 100 |
|---|---|---|
| dump eth, limit 1 / 5 | 0.88 | 2.71 |
| collapse eth | 0.90 | 0.89 |
| credits an hour, steady market (limit 24) | 35.4 | 35.4 |
| credits an hour, no organic sellers | 23.2 | 23.2 |
| launch wave, minutes | 7 | 1 |

The other two climb values give identical dump and collapse results and a lower throughput ceiling (climb 50: 6 an hour, climb 100: 12 an hour), so 200 is the setting to take. Recovery 400 at drop 500 spends 1.45 eth on the 10 eth pot and misses the bar.

The throughput pass sits on the bar. The 35.4 an hour is the organic sellers filling at a bid that has sunk to near 0 (mean bid 0.0000 over hours 12 to 23); the engine's own capacity at this cell is climb / drop = 24 an hour by formula and 23.2 measured. Seller flow above 24 an hour that accepts any bid pushes the bid down, and the 24 an hour figure comes from the formula with 23.2 measured.

Second best cell, with throughput margin: **300/200/200**. Dump 1.55 eth (pot 10) and 3.28 eth (pot 100), collapse 1.58 and 1.56, 38.3 credits an hour with the organic sellers present (39.0 without), formula 40 an hour, mean bid 0.0155, wave 10 minutes at pot 10 and 1 minute at pot 100. It misses the 10 eth bar by 0.55 eth and passes the 100 eth bar.

The constraint that has to give to gain throughput margin is the 1 eth bar on the 10 eth pot: every grid cell with a climb / drop ceiling over 24 an hour spends at least 1.5 eth in the 6 hour dump on that pot, and the off-grid probe at drop 400 (30 an hour) spends 1.12 eth. Exposure and ceiling both move with drop. The spend cap is the setting this grid holds at 100 bps; its effect on this trade-off is untested here.
