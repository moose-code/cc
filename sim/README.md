# simulation of the credits engine

`sim/engine.js` is a deterministic model of `src/Core.sol`, `src/lib/CoreLib.sol` and `src/ControllerV1.sol`. It reads every launch value from `script/config/mainnet.json` (node reads the file, `build.mjs` inlines it for the browser), so the launch settings cannot drift from the config. The contracts are the authority. `sim/engine.test.mjs` checks the port against hand computed cases and against the config.

## what the model covers

The rules follow the contracts. Names are the Core and controller names.

- **eth bid (`CoreLib.climb`, `CoreLib.drop`).** A fill drops the bid by `dropPerCreditBps` of the price state. Within one minute the bid stays at or above `dropFloorBps` of the bid at that minute's first fill. The price state climbs `climbPerMinBps` a minute, or `recoveryClimbPerMinBps` while it sits more than `recoveryGapBps` under the remembered peak. The peak halves every `peakHalfLife` seconds. The ceiling is `ceilBps` of the larger of the last fill rate and the peak, grown by `idleLoosenBps` for each full 10 idle minutes. The read bid is also held to `rateCap` and to the pot: `ethRate` is the price state lowered to `ethPot`.
- **fee income (`Core._book`).** Each door books fee eth before it reads a rate. The first book with income at or after the anti sniper window takes no payee share and sets `payeeOn`. From then on each book pushes `payeePpm` of its income to the payee (decision 123, a push, tracked in `payeePaid`); `payeePpm` is 0 at launch. `feeToRedeemBurnBps` of the rest fills the redeem burn reserve, and the rest fills the pot. `fund()` adds eth to the pot whole, with no split.
- **nft sale cuts (decision 123).** A statement or credit sale pays `saleToArtistBps` to the artist and `saleToOperatorBps` to the payee off the top of the payment, pushed out (tracked in `artistPaid`, `operatorPaid`). The rest splits as below.
- **doors.** `sellForEth` (one credit at the bid). `buyListing` (a listing at its ask, the caller paid from the bid less the ask). `compose` (the 80 oldest credits, past their window while the credit sale is on). `sellTo` (a statement at the controller's price, never below `saleFloorBps` of cost; after the cuts, `saleToBuybackBps` of the rest to the buyback). `sellCreditTo` (after the cuts, `creditCostToPotBps` of cost to the pot, the rest to the buyback). `swapCredit` (swaps a pile credit for one of equal or higher score, the caller burning `swapFeeCc` coins; the incoming credit inherits the node). `buyback` (one slice per `buybackDelay` blocks, the caller paid, the unspent reserve back to the buyback pot). `redeemStatement` (`redeemOn`, at the floor, `redeemSlippageBps`, `redeemBurnBps` of the reserve to the buyback). `sellForBalance` (`balanceBidOn`, the rising balance bid below). `releaseRedeemBurn`, `setPaused` (the pause clock and each statement's `pauseMark`), `setSettings` (checkpoints first, checks `src/lib/SettingsBounds.sol`, and restates the peak when `peakHalfLife` changes), `setRate`.
- **rising balance bid (decision 122).** A second price state in bps of par (par is `score * unitPerPoint`), with the same climb and drop settings as the eth bid. Its floor is `10000 - balanceBidMarginBps`, its cap 10000 (par, so a payout never exceeds the score value), its clamp the module's `available()` as bps of par. It opens at the floor and resets to it when the bid turns on; `balanceRate` reads the floor while off or with no usable module. `sellForBalance` pays `score * unit * rate / 10000` per credit and refuses the batch with `PotTooSmall` when the available clamp falls below the floor.
- **controller.** `valueOf` (the rate term, and the pool term once the pool key and the module are set), the reference `max(cost, valueOf(rating))`, the anchor and its half life, the single rate linear ask falling from `startBps` to `saleFloorBps` over `decayHours` (12 at launch), and the credit window (`creditPrice`, `pastWindow`).
- **balance module.** `unitPerPoint` is read at each use. A `moduleUnit` patch in a schedule changes it.

Not modeled:

- the pool price. `balancePoolMult` stands in for the pool price against the unit.
- the coin supply effect of `swapCredit` beyond the `swapFeeCc` burn count; the swap is not driven in whole runs.
- statement formats, `composerOf`, and the coin minimum `minCcToChoose`. Every composer passes the minimum.
- the other adapters, migration, successors, rescues and ownership.
- the `callerFee` and `callerMaxBaseFee` payments, which are zero at launch. The buyback and listing payments use the counted gas at `basefeeGwei`.
- the hook skim, the coin market and the buyers are model inputs: the skim ramp (`sniperStartBps` to `sniperEndBps` over `sniperSeconds`), the daily volume, and the buyers.

## how to run

```
node sim/engine.test.mjs     # prints "ok, N checks passed"
node sim/run.mjs q1          # writes sim/results/q1.json, about two minutes
node sim/build.mjs           # rebuilds sim/index.html from engine.js and the page files
```

`simulate(params)` in `sim/engine.js` returns `{ S, T, stats, at, core }`: `S` the hourly series, `T` the totals, `stats` the run statistics and accounting checks, `at(day)` one day's snapshot, and `core` the final Core state. `params` takes any key of `DEFAULTS`: every Core setting, the controller and credit settings, and the market inputs. `schedule: [{ day, patch }]` changes settings mid run through `setSettings`, with the same bounds. `stepSec` must divide 3600. The stepped rule depends on the step: an hourly step gives 16,782 credits in 30 days against 23,384 at 5 minutes (seed 1, the test's `LEGACY` config), so use 60 or 300 seconds.

## calibration

The constants are in `sim/engine.js`. The sources below are the ones each constant was fit to.

| piece | model value | source |
|---|---|---|
| credit price | flat median 0.0089 eth per credit (`priceP0`) | `sim/data/notes.md`, last 24 hours: median 0.0089 eth, p10 0.0069, p90 0.0138. the price is flat in score from 80 to 650 points |
| score premium | 1.12 above 740 points, 2.0 from 790 | earlier calibration, source outside `sim/data` |
| credit sellers | scores uniform 80 to 800 points, asks lognormal with sigma 0.27, 150 offers an hour, 5 percent of resting offers leave an hour, float 96,800 credits | 109,914 live credits less the 13,132 held by the strategy (96,782), `sim/data/notes.md`. score census: 122,154 credits |
| CreditStrategy listings | 13,132 listings, counts and prices as `STRAT_LISTINGS`, score deciles as `STRAT_SCORE_Q` | `sim/data/notes.md`, strategy holds 13,132 |
| coin volume | `122.6 * exp(-0.286 d)` eth a day from day one, floor 0.5 eth. day one 1,557 eth, 58.6 percent of it in the first hour | fit to the observed daily volume (`COMPARABLE`) |
| buy share | 0.526 on day one, 0.46 after | earlier calibration |
| anti sniper skim | 9,000 bps falling to the 1,000 bps (10 point) baseline over 1,800 seconds. `bountyBps` 9,000 of the baseline goes to the Core, the other 1,000 is the protocol leg (decision 120) | launch block of `script/config/mainnet.json` |
| coin price | 4.51e-7 eth at the end of day one | model output. the earlier calibration observed 4.44e-7 |
| market feedback | engine spend lifts the flat price by elasticity 0.12 per eth over `impactHalfLifeHours` 48, capped at 3 times | assumption |
| statement buyers | 8 a day, decaying to 2 with a 21 day half life. willingness to pay as a multiple of the market cost of 80 credits: p10 0.48, p25 0.71, median 0.84, p75 1.07, 21 percent at 1.2 or more, max 1.32 | fixed price statement sales, earlier calibration |
| credit buyers | 40 a day while `creditSaleOn` is true, willingness to pay around the market price times the ask spread | assumption, unmeasured |
| balance side | the module returns rating times the per point value, the balance token bid pays score times that value less the margin | assumption, unmeasured |

## headline

`node sim/run.mjs q1` at the launch configuration with the launch rules, the credit sale on and the balance bid off (decision 119). Each cell is the mean of five seeds (1 to 5) over 90 days. The steady state is the last 30 days of each run, when the pot is spent.

| | comparable | sustained 17 eth a day | sustained 50 eth a day | dead week one |
|---|---|---|---|---|
| credits acquired, day 30 | 33,010 | 34,900 | 42,260 | 32,510 |
| credits acquired, day 90 | 40,440 | 56,720 | 83,030 | 39,690 |
| statements created, day 90 | 469 | 675 | 1,007 | 461 |
| statements sold, day 90 | 157 | 199 | 172 | 158 |
| average sale price over cost, day 90 | 1.04 | 1.03 | 1.02 | 1.04 |
| statements waiting for the balance side, day 90 | 312 | 476 | 835 | 303 |
| eth to buy and burn, day 90 | 33.3 | 35.7 | 35.8 | 33.3 |
| day the launch pot is spent | 20.5 | 20.2 | 26.3 | 20.1 |
| steady state credits a day after the pot | 110 | 358 | 676 | 114 |
| steady state statements sold a day after the pot | 1.1 | 1.8 | 1.5 | 1.2 |

The full run, with the daily series of seed 1, is in `sim/results/q1.json`.

## files

- `engine.js`: the model. `engine.test.mjs`: the checks.
- `run.mjs`: the headline run. `build.mjs`: builds `index.html`.
- `page.*`: the page source (`page.body.html`, `page.css`, `page.ui1.js` to `page.ui4.js`). `index.html`: the built page.
- `data/`: the calibration pulls. `notes.md` describes them.
- `results/`: written by `run.mjs`, ignored by git through `sim/.gitignore`.
