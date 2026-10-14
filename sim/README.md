# simulation of the credits engine

`sim/engine.js` is a deterministic model of `src/Core.sol`, `src/lib/CoreLib.sol` and `src/ControllerV1.sol`, with the launch values of `script/config/mainnet.json`. The contracts are the authority. `sim/engine.test.mjs` checks the port against hand computed cases and against the config.

## what the model covers

The rules follow the contracts. Names are the Core and controller names.

- **eth bid (`CoreLib.climb`, `CoreLib.drop`).** A fill drops the bid by `dropPerCreditBps` of the price state. Within one minute the bid stays at or above `dropFloorBps` of the bid at that minute's first fill. The price state climbs `climbPerMinBps` a minute, or `recoveryClimbPerMinBps` while it sits more than `recoveryGapBps` under the remembered peak. The peak halves every `peakHalfLife` seconds. The ceiling is `ceilBps` of the larger of the last fill rate and the peak, grown by `idleLoosenBps` for each full 10 idle minutes. The read bid is also held to `rateCap` and to the pot: `ethRate` is the price state lowered to `ethPot`.
- **fee income (`Core._book`).** Each door books fee eth before it reads a rate. The first book with income at or after the anti sniper window takes no payee share and sets `payeeOn`. From then on each book sends `payeePpm` of its income to `payeeOwed`. `feeToRedeemBurnBps` of the rest fills the redeem burn reserve, and the rest fills the pot. `fund()` adds eth to the pot whole, with no split.
- **doors.** `sellForEth` (one credit at the bid). `buyListing` (a listing at its ask, the caller paid from the bid less the ask). `compose` (the 80 oldest credits, past their window while the credit sale is on). `sellTo` (a statement at the controller's price, never below `saleFloorBps` of cost, with `saleToBuybackBps` to the buyback). `sellCreditTo` (`creditCostToPotBps` of cost to the pot, the rest to the buyback). `buyback` (one slice per `buybackDelay` blocks, the caller paid, the unspent reserve back to the buyback pot). `redeemStatement` (`redeemOn`, at the floor, `redeemSlippageBps`, `redeemBurnBps` of the reserve to the buyback). `sellForBalance` (`balanceBidOn`, `balanceBidMarginBps`, cost basis floor times score over `refScore`). `releaseRedeemBurn`, `setPaused` (the pause clock and each statement's `pauseMark`), `setSettings` (checkpoints first, checks `src/lib/SettingsBounds.sol`, and restates the peak when `peakHalfLife` changes), `setRate`.
- **controller.** `valueOf` (the rate term, and the pool term once the pool key and the module are set), the reference `max(cost, valueOf(rating))`, the anchor and its half life, the two stage ask and its floor, the royalty added on top of every sale, and the credit window (`creditPrice`, `pastWindow`).
- **balance module.** `unitPerPoint` is read at each use. A `moduleUnit` patch in a schedule changes it.

Not modeled:

- the payee and royalty claims (`claimPayee`, `claimRoyalty`). The owed amounts are tracked, nothing is paid out.
- the pool price. `balancePoolMult` stands in for the pool price against the unit.
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
| anti sniper skim | 9,000 bps falling to the 690 bps baseline over 1,800 seconds. 9,638 bps of the baseline goes to the Core | launch block of `script/config/mainnet.json` |
| coin price | 4.51e-7 eth at the end of day one | model output. the earlier calibration observed 4.44e-7 |
| market feedback | engine spend lifts the flat price by elasticity 0.12 per eth over `impactHalfLifeHours` 48, capped at 3 times | assumption |
| statement buyers | 8 a day, decaying to 2 with a 21 day half life. willingness to pay as a multiple of the market cost of 80 credits: p10 0.48, p25 0.71, median 0.84, p75 1.07, 21 percent at 1.2 or more, max 1.32 | fixed price statement sales, earlier calibration |
| credit buyers | 40 a day while `creditSaleOn` is true, willingness to pay around the market price times the ask spread | assumption, unmeasured |
| balance side | the module returns rating times the per point value, the balance token bid pays score times that value less the margin | assumption, unmeasured |

## headline

`node sim/run.mjs q1` at the launch configuration with the launch rules, the balance side off. Each cell is the mean of five seeds (1 to 5) over 90 days. The steady state is the last 30 days of each run, when the pot is spent.

| | comparable | sustained 17 eth a day | sustained 50 eth a day | dead week one |
|---|---|---|---|---|
| credits acquired, day 30 | 26,350 | 27,730 | 33,330 | 25,660 |
| credits acquired, day 90 | 30,540 | 41,570 | 62,690 | 29,410 |
| statements created, day 90 | 381 | 519 | 783 | 367 |
| statements sold, day 90 | 140 | 168 | 163 | 131 |
| average sale price over cost, day 90 | 1.13 | 1.03 | 1.02 | 1.11 |
| statements waiting for the balance side, day 90 | 242 | 351 | 620 | 237 |
| eth to buy and burn, day 90 | 42.7 | 44.2 | 46.6 | 40.0 |
| day the launch pot is spent | 16.3 | 15.8 | 18.4 | 16.1 |
| steady state credits a day after the pot | 64 | 225 | 489 | 61 |
| steady state statements sold a day after the pot | 1.0 | 1.4 | 1.6 | 1.0 |

The full run, with the daily series of seed 1, is in `sim/results/q1.json`.

## files

- `engine.js`: the model. `engine.test.mjs`: the checks.
- `run.mjs`: the headline run. `build.mjs`: builds `index.html`.
- `page.*`: the page source (`page.body.html`, `page.css`, `page.ui1.js` to `page.ui4.js`). `index.html`: the built page.
- `data/`: the calibration pulls. `notes.md` describes them.
- `results/`: written by `run.mjs`, ignored by git through `sim/.gitignore`.
