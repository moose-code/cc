# Exposure 146: drop without a minute floor and without a spend cap

Simulation of the credit bid at main e5cb263, shipped rules from `sim/engine.js`, cases from `sim/grid.mjs` (EXPOSURE-129). Source: `sim/nofloor.mjs` (`node sim/nofloor.mjs docs/reviews/EXPOSURE-146-nofloor.json`, 0.3 s). `sim/grid.mjs` gained exports and two optional cell fields (`floorBps`, `cap`) plus extra dump metrics; the 129 grid output is unchanged.

## Configurations

All use drop 500 bps per reference credit (433 points), climb 200 bps a minute, opening rate 0.025 eth at 433 points. `dropFloorBps` 1 is the smallest floor the setting accepts; `spendCapBps` 10,000 bypasses the cap.

| config | dropFloorBps | spendCapBps | recoveryClimbPerMinBps | dropPerCreditBps |
|---|---|---|---|---|
| A today | 5,000 | 100 | 200 | 500 |
| B | 1 | 10,000 | 200 | 500 |
| C | 1 | 10,000 | 500 | 500 |
| D | 1 | 10,000 | 500 | 300 |
| E | 5,000 | 10,000 | 200 | 500 |

## Cases

- Dump: 500 credits at the nine census deciles (152 to 728 points), seeded shuffle, one seller. Every 12 s block the seller sells each credit whose score-scaled bid covers a flat 0.005 eth, until none clears. Selling stops at 6 h or when the inventory is gone. Recovery is measured to the opening bid 0.025 eth.
- Collapse: same inventory, the ask falls from 0.025 to 0.005 over 10 minutes.
- Steady: 433-point credits, 24 h. Unlimited sellers at a flat 0.018, plus 35 organic sellers an hour (Poisson) that sell at the bid at any price. Pot refilled each block. Credits an hour is the mean of hours 12 to 23. The no organic column repeats the run without the organic sellers and shows the rule's own capacity.
- Launch wave: 200 sellers at the open at the bid with the steady sellers active, pot not refilled. 0 means all 200 filled inside the first 12 s block.
- Sellable probe: at the last block of each minute of the dump, after the dumper has acted, a non-mutating check whether one 440-point credit would sell (pot holds the price and the minute bucket admits it). The column is the share of those minutes (360 for A, B, C) refused. The keeper is not modeled; the dumper takes the minute's budget.
- Avg price / market is eth paid per credit sold over the flat 0.005 ask. Values above 1 come from score scaling: credits of 440 points and above are paid more than the reference bid and still clear after the reference bid is under 0.005.
- Dump eth before under market is spent until the reference bid first reads under 0.005; "-" means the reference bid never read under 0.005 (E sells all 500 inside one minute at bids above market).

## Results, pot 10 eth

| config | dump eth before under market | dump eth 6 h | credits | points | min to under market | min to recover | worst minute eth | credits/h steady, with 35/h organic | credits/h, no organic | wave min | avg price / market | refused minutes % | collapse eth |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| A | 0.43 | 0.88 | 118 | 76328 | 4 | 103 | 0.094 | 35.4 | 23.2 | 7 | 1.50 | 1 | 0.90 |
| B | 0.41 | 0.86 | 118 | 76616 | 0 | 105 | 0.443 | 35.4 | 23.2 | 0 | 1.46 | 0 | 0.89 |
| C | 0.41 | 1.67 | 278 | 160336 | 0 | 58 | 0.443 | 35.4 | 23.2 | 0 | 1.20 | 0 | 1.76 |
| D | 0.67 | 2.96 | 500 | 219280 | 0 | 30 | 0.738 | 40.9 | 39.1 | 0 | 1.18 | 0 | 3.13 |
| E | 6.45 | 6.45 | 500 | 219280 | - | 29 | 6.176 | 35.4 | 23.2 | 0 | 2.58 | 0 | 0.89 |

## Results, pot 100 eth

| config | dump eth before under market | dump eth 6 h | credits | points | min to under market | min to recover | worst minute eth | credits/h steady, with 35/h organic | credits/h, no organic | wave min | avg price / market | refused minutes % | collapse eth |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| A | 2.01 | 2.71 | 327 | 177288 | 2 | 74 | 0.996 | 35.4 | 23.2 | 1 | 1.66 | 1 | 0.89 |
| B | 0.41 | 0.86 | 118 | 76616 | 0 | 105 | 0.443 | 35.4 | 23.2 | 0 | 1.46 | 0 | 0.89 |
| C | 0.41 | 1.67 | 278 | 160336 | 0 | 58 | 0.443 | 35.4 | 23.2 | 0 | 1.20 | 0 | 1.76 |
| D | 0.67 | 2.96 | 500 | 219280 | 0 | 30 | 0.738 | 40.9 | 39.1 | 0 | 1.18 | 0 | 3.13 |
| E | 6.45 | 6.45 | 500 | 219280 | - | 29 | 6.176 | 35.4 | 23.2 | 0 | 2.58 | 0 | 0.89 |

## Reading

1. B keeps dump exposure under both bars: 0.86 eth in 6 h (bar 1 on 10 eth, 5 on 100 eth), the same on both pots because without a cap nothing in the dump scales with the pot. A spends 0.88 and 2.71.
2. B sells a credit at any minute while the pot holds its price (0 of 360 minutes refused); A refuses 4 of 360 minutes on 10 eth (minutes 0, 1, 3, 4) and 2 of 360 on 100 eth (minutes 0, 1), all in the opening descent. C and D share this by construction.
3. B costs 105 minutes to recover to the opening bid after selling stops (A: 103 on 10 eth, 74 on 100 eth), the same 23.2 credits an hour capacity, and a worst minute of 0.44 eth against A's 0.09 (10 eth) and 1.00 (100 eth). The launch wave clears inside one block instead of 7 minutes on 10 eth.
4. C (recovery 500) passes only the 100 eth bar (1.67 eth) and recovers in 58 minutes; D (drop 300, recovery 500) passes only the 100 eth bar (2.96 eth), recovers in 30 minutes and lifts capacity to 39 credits an hour. E (floor, no cap) spends 6.45 eth on both pots, 500 credits inside one minute: the floor holds the bid at 0.0125 for the minute, so the cap is what bounds the dump while the floor is in place.
