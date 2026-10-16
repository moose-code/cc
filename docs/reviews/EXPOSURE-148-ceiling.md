# Exposure 148: ceiling, idle step and idle loosening at small pots

Simulation of the credit bid at main 876adba, shipped rules from `sim/engine.js`, cases from `sim/grid.mjs` (EXPOSURE-129, EXPOSURE-146). Source: `sim/ceiling.mjs` (`node sim/ceiling.mjs docs/reviews/EXPOSURE-148-ceiling.json`, 1 s). `sim/grid.mjs` gained an export of `makeCore` and three optional cell fields (`ceilBps`, `idleLoosenBps`, `idleStepSeconds`); the earlier grids are unchanged.

## Setup

Launch settings from `script/config/mainnet.json`: opening rate 0.0049 eth per 100 points, rate cap 3x (0.0147), dropPer100PointsBps 115, dropFloorBps 1, climbPerMinBps 200, recoveryClimbPerMinBps 200, pointsPerPage 35,200, climbMultiplierCapBps 40,000, spendCapBps 10,000. The grid is ceilBps {11000, 13000, 15000, 20000} x idleStepSeconds {600, 300} x idleLoosenBps {600, 1200} at pots 0.5, 2 and 10 eth (48 cells). The launch cell is 11000 / 600 / 600. The pages multiplier at the opening rate is 0.29 pages at 0.5 eth (1x), 1.2 pages at 2 eth and 5.8 pages at 10 eth (4x cap).

## Cases

- Dump: 500 credits at the nine census deciles, one seller, flat 0.005 eth market, 6 h of selling. Cost is eth paid out. Worst minute is the largest eth paid in one minute. Recovery is minutes after selling stops until the bid is back at the opening bid; "pot empty" means the dump emptied the pot and the bid stayed at the pot clamp.
- Collapse: same inventory, the ask falls from the opening bid to 0.005 over 10 minutes.
- Ask book: 433 point credits, 24 h, pot refilled every block. One ask seller whose ask is (1 + u) times the opening bid of 0.0212 eth per credit, u uniform from 0.10 to 0.25, redrawn after every fill. Credits per hour is the mean of hours 12 to 23. Mean of 3 seeds. Asks are anchored to the opening bid so the market level stays fixed.
- Asks follow the bid: the same seller with the ask drawn from the bid the previous fill leaves (the owner reading). Each fill lifts the market about 16%, so the rate reaches 2.8x of the opening rate after 80 minutes and the 3x cap soon after; the column counts first-hour credits only.
- With 35/h organic: the ask book plus 35 organic sellers an hour at the bid. Organic fills drop the bid 5% each and keep it under the asks, so the ask book contributes 0.0 of the fills in every cell and the total is the organic flow (33.5 an hour).
- Launch wave: 200 sellers at the bid clear inside the first block in every cell at every pot (not tabulated).
- Idle: no sellers, pot held. Highest rate as a multiple of the opening rate by 2 h and 6 h, and minutes until it first reaches 3x.

## Results, pot 0.5 eth

| ceilBps | idleStepSeconds | idleLoosenBps | ask book: credits first hour | ask book: credits/h steady | asks follow the bid: credits first hour | with 35/h organic: credits/h | dump eth 6 h | worst minute eth | collapse eth | recovery min | idle rate x open at 2 h | at 6 h | min to 3x |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 11000 | 600 | 600 | 19.3 | 23.3 | 5.0 | 33.5 | 0.499 | 0.369 | 0.498 | pot empty | 1.89 | 3.00 | 290 |
| 11000 | 600 | 1200 | 20.3 | 23.3 | 6.0 | 33.5 | 0.499 | 0.369 | 0.498 | pot empty | 2.68 | 3.00 | 150 |
| 11000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.499 | 0.369 | 0.498 | pot empty | 2.68 | 3.00 | 145 |
| 11000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.499 | 0.369 | 0.498 | pot empty | 3.00 | 3.00 | 75 |
| 13000 | 600 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.499 | 0.369 | 0.498 | pot empty | 2.24 | 3.00 | 220 |
| 13000 | 600 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.499 | 0.369 | 0.498 | pot empty | 3.00 | 3.00 | 110 |
| 13000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.499 | 0.369 | 0.498 | pot empty | 3.00 | 3.00 | 110 |
| 13000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.499 | 0.369 | 0.498 | pot empty | 3.00 | 3.00 | 56 |
| 15000 | 600 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.499 | 0.369 | 0.498 | pot empty | 2.58 | 3.00 | 170 |
| 15000 | 600 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.499 | 0.369 | 0.498 | pot empty | 3.00 | 3.00 | 90 |
| 15000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.499 | 0.369 | 0.498 | pot empty | 3.00 | 3.00 | 85 |
| 15000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.499 | 0.369 | 0.498 | pot empty | 3.00 | 3.00 | 56 |
| 20000 | 600 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.499 | 0.369 | 0.498 | pot empty | 3.00 | 3.00 | 90 |
| 20000 | 600 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.499 | 0.369 | 0.498 | pot empty | 3.00 | 3.00 | 56 |
| 20000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.499 | 0.369 | 0.498 | pot empty | 3.00 | 3.00 | 56 |
| 20000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.499 | 0.369 | 0.498 | pot empty | 3.00 | 3.00 | 56 |

## Results, pot 2 eth

| ceilBps | idleStepSeconds | idleLoosenBps | ask book: credits first hour | ask book: credits/h steady | asks follow the bid: credits first hour | with 35/h organic: credits/h | dump eth 6 h | worst minute eth | collapse eth | recovery min | idle rate x open at 2 h | at 6 h | min to 3x |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 11000 | 600 | 600 | 19.7 | 23.2 | 5.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 2.02 | 3.00 | 250 |
| 11000 | 600 | 1200 | 20.3 | 23.3 | 6.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 2.94 | 3.00 | 130 |
| 11000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 2.94 | 3.00 | 125 |
| 11000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 65 |
| 13000 | 600 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 2.39 | 3.00 | 190 |
| 13000 | 600 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 100 |
| 13000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 95 |
| 13000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |
| 15000 | 600 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 2.75 | 3.00 | 150 |
| 15000 | 600 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 80 |
| 15000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 75 |
| 15000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |
| 20000 | 600 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 80 |
| 20000 | 600 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |
| 20000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |
| 20000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |

## Results, pot 10 eth

| ceilBps | idleStepSeconds | idleLoosenBps | ask book: credits first hour | ask book: credits/h steady | asks follow the bid: credits first hour | with 35/h organic: credits/h | dump eth 6 h | worst minute eth | collapse eth | recovery min | idle rate x open at 2 h | at 6 h | min to 3x |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 11000 | 600 | 600 | 20.3 | 23.3 | 6.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 80 |
| 11000 | 600 | 1200 | 20.3 | 23.3 | 6.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |
| 11000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |
| 11000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |
| 13000 | 600 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 60 |
| 13000 | 600 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |
| 13000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |
| 13000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |
| 15000 | 600 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |
| 15000 | 600 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |
| 15000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |
| 15000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |
| 20000 | 600 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |
| 20000 | 600 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |
| 20000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |
| 20000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789 | 0.369 | 0.761 | 95 | 3.00 | 3.00 | 56 |

## Probe: what moves the ask book

Launch ceiling values (11000 / 600 / 600); throughput at pot 0.5, dump and collapse at pot 2 (the dump empties a 2 eth pot at 800 bps and at 70 / 500; those rows are pot bound).

| dropPer100PointsBps | climbPerMinBps = recoveryClimbPerMinBps | ask book credits first hour (pot 0.5) | ask book credits/h (pot 0.5) | dump eth 6 h (pot 2) | dump credits | worst minute eth | collapse eth | recovery min |
|---|---|---|---|---|---|---|---|---|
| 115 | 200 | 19.3 | 23.3 | 0.789 | 115 | 0.369 | 0.761 | 95 |
| 115 | 300 | 29.7 | 34.7 | 1.031 | 163 | 0.369 | 0.980 | 61 |
| 115 | 500 | 47.7 | 57.3 | 1.599 | 276 | 0.374 | 1.495 | 489 |
| 115 | 800 | 75.3 | 90.4 | 1.996 | 354 | 0.374 | 1.996 | pot empty |
| 70 | 200 | 31.3 | 38.6 | 1.341 | 199 | 0.605 | 1.310 | 109 |
| 70 | 300 | 47.7 | 57.6 | 1.824 | 295 | 0.605 | 1.757 | 380 |
| 70 | 500 | 79.0 | 95.1 | 1.997 | 329 | 0.610 | 1.997 | pot empty |
| 70 | 800 | 123.7 | 150.0 | 1.996 | 328 | 0.610 | 2.000 | pot empty |

## Reading

1. No cell reaches 60 credits an hour at 0.5 eth against the ask book: all 16 sell 23.3 an hour at steady state (19.3 to 20.3 in the first hour). The pace is the climb over the drop, 60 x 2% / 4.98% = 24 an hour for a 433 point credit, and the ceiling sits above the bid whenever the next ask is within 15.8% of the dropped bid, so it changes the first hour of the anchored book by one credit. When asks follow the bid at 10 to 25% above the dropped bid, the book sells 5 (launch) to 7 credits in the first hour with the other cells adding 1 to 2, and the 20 an hour seen on the dev chain matches the 24 an hour climb bound, so those asks sit closer than 10%.
2. Dump cost, worst minute, collapse cost and recovery are identical in all 16 cells of a pot (0.499 eth at 0.5 eth, which empties the pot; 0.789 eth at 2 and 10 eth): fills reset the ceiling every block, so the 2% a minute climb sets the pace and the ceiling is never reached. The 20% dump bound does not separate cells.
3. Only the idle column moves. At 0.5 eth the rate reaches 3x after 290 min at launch values and after 56 to 220 min in the other cells; the cells at 120 min or more are 11000/600/600 (290), 11000/600/1200 (150), 11000/300/600 (145), 13000/600/600 (220) and 15000/600/600 (170). At 2 eth the same five pass (250, 130, 125, 190, 150). At 10 eth none passes, the launch cell reaches 3x in 80 min because the 4x multiplier applies.
4. Recommendation: keep ceilBps 11000, idleStepSeconds 600, idleLoosenBps 600; the cells that pass the idle bar buy at most one credit in the first hour. Throughput is set by dropPer100PointsBps and climbPerMinBps, which trade against the dump one for one: climb 300 gives 34.7 an hour for a 1.03 eth dump on 2 eth (+31%), and 57 an hour needs climb 500 or drop 70 with climb 300 at 1.6 to 1.8 eth (+103% to +131%), so 60 an hour inside +20% is out of reach for this rule family.
