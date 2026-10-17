# Exposure 148: ceiling, idle step and idle loosening at small pots

Simulation of the credit bid at main 50b8e8c (regenerated with the 0.1 eth reserve and the 2.5 percent artist royalty on top of every purchase), shipped rules from `sim/engine.js`, cases from `sim/grid.mjs` (EXPOSURE-129, EXPOSURE-146). Source: `sim/ceiling.mjs` (`node sim/ceiling.mjs docs/reviews/EXPOSURE-148-ceiling.json`, 1 s). The JSON carries the seller payment, the royalty and the pot total for the dump and the collapse.

## Setup

Launch settings from `script/config/mainnet.json`: opening rate 0.0049 eth per 100 points, rate cap 3x (0.0147), dropPer100PointsBps 115, dropFloorBps 1, climbPerMinBps 200, recoveryClimbPerMinBps 200, pointsPerPage 35,200, climbMultiplierCapBps 40,000, spendCapBps 10,000, reserveWei 0.1 eth, buyToArtistBps 250. The pot funds every purchase as seller payment plus royalty: a purchase of price p takes 1.025 p from the pot, the bid reads the pot less the reserve, and a bid at the pot clamp is the room divided by 1.025. The grid is ceilBps {11000, 13000, 15000, 20000} x idleStepSeconds {600, 300} x idleLoosenBps {600, 1200} at pots 0.5, 2 and 10 eth (48 cells). The launch cell is 11000 / 600 / 600.

## Cases

- Dump: 500 credits at the nine census deciles, one seller, flat 0.005 eth market, 6 h of selling. Seller is the eth paid to the seller, royalty is the artist share on top (2.5 percent of seller), total is the pot spend (seller plus royalty). Worst minute is the largest seller eth in one minute. Recovery is minutes after selling stops until the bid is back at the opening bid; "-" means the bid had not returned inside the run (the pot stays at the reserve).
- Collapse: same inventory, the ask falls from the opening bid to 0.005 over 10 minutes. Seller, royalty and total as above.
- Ask book: 433 point credits, 24 h, pot refilled every block. One ask seller whose ask is (1 + u) times the opening bid of 0.0212 eth per credit, u uniform from 0.10 to 0.25, redrawn after every fill. Credits per hour is the mean of hours 12 to 23. Mean of 3 seeds. Asks are anchored to the opening bid so the market level stays fixed.
- Asks follow the bid: the same seller with the ask drawn from the bid the previous fill leaves. The column counts first-hour credits only.
- With 35/h organic: the ask book plus 35 organic sellers an hour at the bid. Organic fills keep the bid under the asks, so the total is the organic flow.
- Idle: no sellers, pot held. Highest rate as a multiple of the opening rate by 2 h and 6 h, and minutes until it first reaches 3x.

## Results, pot 0.5 eth

| ceilBps | idleStepSeconds | idleLoosenBps | ask book: credits first hour | ask book: credits/h steady | asks follow the bid: credits first hour | with 35/h organic: credits/h | dump seller eth 6 h | dump royalty eth | dump total pot eth | worst minute seller eth | collapse seller eth | collapse royalty eth | collapse total pot eth | recovery min | idle rate x open at 2 h | at 6 h | min to 3x |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 11000 | 600 | 600 | 19.3 | 23.3 | 5.0 | 33.5 | 0.388628 | 0.009716 | 0.398344 | 0.369 | 0.388922 | 0.009723 | 0.398645 | - | 1.89 | 3.00 | 290 |
| 11000 | 600 | 1200 | 20.3 | 23.3 | 6.0 | 33.5 | 0.388628 | 0.009716 | 0.398344 | 0.369 | 0.388922 | 0.009723 | 0.398645 | - | 2.68 | 3.00 | 150 |
| 11000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.388628 | 0.009716 | 0.398344 | 0.369 | 0.388922 | 0.009723 | 0.398645 | - | 2.68 | 3.00 | 145 |
| 11000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.388628 | 0.009716 | 0.398344 | 0.369 | 0.388922 | 0.009723 | 0.398645 | - | 3.00 | 3.00 | 75 |
| 13000 | 600 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.388628 | 0.009716 | 0.398344 | 0.369 | 0.388922 | 0.009723 | 0.398645 | - | 2.24 | 3.00 | 220 |
| 13000 | 600 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.388628 | 0.009716 | 0.398344 | 0.369 | 0.388922 | 0.009723 | 0.398645 | - | 3.00 | 3.00 | 110 |
| 13000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.388628 | 0.009716 | 0.398344 | 0.369 | 0.388922 | 0.009723 | 0.398645 | - | 3.00 | 3.00 | 110 |
| 13000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.388628 | 0.009716 | 0.398344 | 0.369 | 0.388922 | 0.009723 | 0.398645 | - | 3.00 | 3.00 | 56 |
| 15000 | 600 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.388628 | 0.009716 | 0.398344 | 0.369 | 0.388922 | 0.009723 | 0.398645 | - | 2.58 | 3.00 | 170 |
| 15000 | 600 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.388628 | 0.009716 | 0.398344 | 0.369 | 0.388922 | 0.009723 | 0.398645 | - | 3.00 | 3.00 | 90 |
| 15000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.388628 | 0.009716 | 0.398344 | 0.369 | 0.388922 | 0.009723 | 0.398645 | - | 3.00 | 3.00 | 85 |
| 15000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.388628 | 0.009716 | 0.398344 | 0.369 | 0.388922 | 0.009723 | 0.398645 | - | 3.00 | 3.00 | 56 |
| 20000 | 600 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.388628 | 0.009716 | 0.398344 | 0.369 | 0.388922 | 0.009723 | 0.398645 | - | 3.00 | 3.00 | 90 |
| 20000 | 600 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.388628 | 0.009716 | 0.398344 | 0.369 | 0.388922 | 0.009723 | 0.398645 | - | 3.00 | 3.00 | 56 |
| 20000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.388628 | 0.009716 | 0.398344 | 0.369 | 0.388922 | 0.009723 | 0.398645 | - | 3.00 | 3.00 | 56 |
| 20000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.388628 | 0.009716 | 0.398344 | 0.369 | 0.388922 | 0.009723 | 0.398645 | - | 3.00 | 3.00 | 56 |

## Results, pot 2 eth

| ceilBps | idleStepSeconds | idleLoosenBps | ask book: credits first hour | ask book: credits/h steady | asks follow the bid: credits first hour | with 35/h organic: credits/h | dump seller eth 6 h | dump royalty eth | dump total pot eth | worst minute seller eth | collapse seller eth | collapse royalty eth | collapse total pot eth | recovery min | idle rate x open at 2 h | at 6 h | min to 3x |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 11000 | 600 | 600 | 19.7 | 23.2 | 5.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 2.02 | 3.00 | 250 |
| 11000 | 600 | 1200 | 20.3 | 23.3 | 6.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 2.94 | 3.00 | 130 |
| 11000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 2.94 | 3.00 | 125 |
| 11000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 65 |
| 13000 | 600 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 2.39 | 3.00 | 190 |
| 13000 | 600 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 100 |
| 13000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 95 |
| 13000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |
| 15000 | 600 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 2.75 | 3.00 | 150 |
| 15000 | 600 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 80 |
| 15000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 75 |
| 15000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |
| 20000 | 600 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 80 |
| 20000 | 600 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |
| 20000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |
| 20000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |

## Results, pot 10 eth

| ceilBps | idleStepSeconds | idleLoosenBps | ask book: credits first hour | ask book: credits/h steady | asks follow the bid: credits first hour | with 35/h organic: credits/h | dump seller eth 6 h | dump royalty eth | dump total pot eth | worst minute seller eth | collapse seller eth | collapse royalty eth | collapse total pot eth | recovery min | idle rate x open at 2 h | at 6 h | min to 3x |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 11000 | 600 | 600 | 20.3 | 23.3 | 6.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 80 |
| 11000 | 600 | 1200 | 20.3 | 23.3 | 6.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |
| 11000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |
| 11000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |
| 13000 | 600 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 60 |
| 13000 | 600 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |
| 13000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |
| 13000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |
| 15000 | 600 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |
| 15000 | 600 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |
| 15000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |
| 15000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |
| 20000 | 600 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |
| 20000 | 600 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |
| 20000 | 300 | 600 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |
| 20000 | 300 | 1200 | 20.3 | 23.3 | 7.0 | 33.5 | 0.789411 | 0.019735 | 0.809146 | 0.369 | 0.761359 | 0.019034 | 0.780393 | 95 | 3.00 | 3.00 | 56 |

## Probe: what moves the ask book

Launch ceiling values (11000 / 600 / 600); throughput at pot 0.5, dump and collapse at pot 2 (the dump empties a 2 eth pot to the reserve at climb 800 and at drop 70 with climb 500 or more; those rows are pot bound).

| dropPer100PointsBps | climbPerMinBps = recoveryClimbPerMinBps | ask book credits first hour (pot 0.5) | ask book credits/h (pot 0.5) | dump seller eth 6 h (pot 2) | dump total pot eth | dump credits | worst minute seller eth | collapse seller eth | recovery min |
|---|---|---|---|---|---|---|---|---|---|
| 115 | 200 | 19.3 | 23.3 | 0.789 | 0.809 | 115 | 0.369 | 0.761 | 95 |
| 115 | 300 | 29.7 | 34.7 | 1.031 | 1.056 | 163 | 0.369 | 0.980 | 61 |
| 115 | 500 | 47.7 | 57.3 | 1.599 | 1.639 | 276 | 0.374 | 1.495 | 489 |
| 115 | 800 | 75.3 | 90.4 | 1.850 | 1.896 | 325 | 0.374 | 1.851 | - |
| 70 | 200 | 31.3 | 38.6 | 1.341 | 1.375 | 199 | 0.605 | 1.310 | 119 |
| 70 | 300 | 47.7 | 57.6 | 1.824 | 1.869 | 295 | 0.605 | 1.757 | 380 |
| 70 | 500 | 79.0 | 95.1 | 1.851 | 1.897 | 300 | 0.610 | 1.852 | - |
| 70 | 800 | 123.7 | 150.0 | 1.849 | 1.896 | 299 | 0.610 | 1.850 | - |
## Reading

1. All 16 cells sell 23.3 credits an hour against the ask book at steady state (19.3 to 20.3 in the first hour), none near 60 an hour. The pace is the climb over the drop, 60 x 2% / 4.98% = 24 an hour for a 433 point credit, and the ceiling sits above the bid whenever the next ask is within 15.8% of the dropped bid, so it changes the first hour of the anchored book by one credit. When asks follow the bid at 10 to 25% above the dropped bid, the book sells 5 (launch) to 7 credits in the first hour with the other cells adding 1 to 2.
2. Dump and collapse spend are identical in all 16 cells of a pot: fills reset the ceiling every block, so the 2% a minute climb sets the pace and the ceiling is not reached. At a 0.5 eth pot the pot less the 0.1 eth reserve funds 35 credits: 0.388628 eth to the seller, 0.009716 eth royalty, 0.398344 eth total pot spend. At 2 and 10 eth the dump pays the seller 0.789411 eth for 115 credits, royalty 0.019735 eth, total 0.809146 eth, with a worst minute of 0.369 eth to the seller. The earlier 0.499 eth figure counted the whole pot with no reserve and no royalty.
3. Only the idle column moves. At 0.5 eth the rate reaches 3x after 290 min at launch values and after 56 to 220 min in the other cells; the cells at 120 min or more are 11000/600/600 (290), 11000/600/1200 (150), 11000/300/600 (145), 13000/600/600 (220) and 15000/600/600 (170). At 2 eth the same five pass (250, 130, 125, 190, 150). At 10 eth none passes, the launch cell reaches 3x in 80 min because the 4x multiplier applies.
4. Recommendation: keep ceilBps 11000, idleStepSeconds 600, idleLoosenBps 600; the cells that pass the idle bar buy at most one credit in the first hour. Throughput is set by dropPer100PointsBps and climbPerMinBps, which trade against the dump one for one: climb 300 gives 34.7 an hour for a 1.03 eth seller dump (1.056 eth total) on 2 eth (+31%), and 57 an hour needs climb 500 or drop 70 with climb 300 at 1.6 to 1.8 eth to the seller (+103% to +131%), so 60 an hour inside +20% is out of reach for this rule family.
