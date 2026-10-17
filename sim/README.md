# Credits engine simulator

`engine.js` models Core, CoreLib and ControllerV1. Current intent is recorded in `docs/SPEC.md`; contract execution and simulator output are evidence. Node reads launch settings from `script/config/mainnet.json`, and `build.mjs` embeds that same configuration in the browser page. The page derives its initial settings from the model defaults.

## Run and verify

```sh
node sim/engine.test.mjs          # focused model checks and integer vectors
node sim/build.mjs                # regenerate tracked index.html
node sim/page.ui.test.js          # control mapping, validation and built script
node sim/market.mjs --spendcap     # 12 bounded exposure scenarios, JSON to stdout
node sim/grid.mjs out.json         # drop, climb, recovery and pot grid over the dump, collapse, steady and launch-wave cases; markdown table to stdout
node sim/value.mjs out.json        # value referenced pricing study (docs/reviews/DESIGN-value-pricing-f1101cb.md): the shared percentage bid under organic flow, a dump, the return loop, a patient seller, a manipulated reference, the sale split, processing payments
node sim/value.test.mjs            # focused checks of that study
```

The browser source is `page.ui1.js` through `page.ui4.js`, `page.body.html`, and `page.css`. Open the generated `index.html` to explore the model. Changing a setting updates the inputs; the owner-change controls schedule one mid-run patch. Invalid economic settings are rejected instead of silently clipped to old slider ranges.

## Spend cap and timing

At launch, `spendCapBps` is 100 and `bucketSeconds` is 60: ETH purchases, including listing keeper payment, share 1% of the opening buying pot per fixed bucket. The snapshot begins with the first successful purchase and excludes separate reserves. New deposits do not increase an active bucket's snapshot. The first purchase of a bucket always passes whatever its cost, and later purchases need spent plus cost at or below the budget. Exact equality is accepted. A failed purchase or ETH batch restores its previous state.

10,000 bps bypasses enforcement while purchases continue to count. Cap edits retain used spending and reprice against the original snapshot. Duration edits retain active spending and both bid instances' active drop floors; expired floors restart on the next fill. Balance purchases are outside this ETH budget.

A cap whose budget is under one credit limits a bucket to its first purchase. The cap does not ensure the bid converges to market. Adjacent fixed buckets can each spend their budget near a boundary. The measured bounded study and frozen assumptions are in [REVIEW-129-spendcap.md](../docs/reviews/REVIEW-129-spendcap.md) (its table predates the first-purchase rule; `docs/reviews/EXPOSURE-129-spendcap.json` has the current runs): none of its twelve reference bids crossed below 0.005 ETH during the six-hour selling window, so market recovery was N/A.

The page defaults to 60-second steps from the first hour. Steps must be integer divisors of 3,600 seconds. The calibrated first-hour volume bins are prorated to the requested execution step. Coarse runs retain a 120-second first-hour warmup ceiling. A step longer than a bucket skips spending opportunities; even a 60-second step remains approximate for shorter or differently aligned buckets. Smaller steps increase runtime, especially over 90 or 180 days. The separate `--spendcap` study uses 12-second modeled blocks throughout, with bucket-opening and boundary-adjacent starts.

## Other current rules

The bid climbs per 60 seconds with a separate recovery speed below the decayed peak. `idleStepSeconds` controls ceiling-loosening intervals without changing those climb units. The last fill rate determines the pages multiplier, capped by `climbMultiplierCapBps`; the multiplier scales ceiling loosening only. `hourlyBound` and `multiplierScalesClimb` are historical experiment switches and do not describe the shipped rule.

The balance bid is a posted price, `10000 - balanceDiscountBps` bps of par per point, flat: no climb while idle and no drop on a fill, bounded by the module holding alone (decision 164). The shared instance (`balanceBidMarginBps`, `balanceBidCapBps`) is value mode's eth price state, read with `sharedRate` and driven by eth fills.

The controller uses `max(cost, valueOf(score))` for credit pricing and the corresponding rating reference for statements. `anchorMoveBps` determines the fraction of a qualifying sale gap that moves the anchor, rounded down; zero preserves the anchor clock. Artist and operator cuts come from sale payments. The artist royalty on every purchase (`buyToArtistBps`, decision 163) rides on top of each eth and balance purchase and is counted in `royaltyPaid` and `royaltyPaidBalance`; the eth clamp divides the room by `1 + buyToArtistBps / 10000`.

`sniperSeconds` controls when the Core payee latch can activate. `payeePpm` is zero at launch. The hook skim window is a separate launch input, `skimSeconds`; editing the payee latch does not change it. Market supply, fee volume, score mix and buyer behavior remain separate model assumptions.

## Precision and coverage

Bucket accounting and the standalone balance-conversion vectors use BigInt. Market prices, rate trajectories, page controls and totals use JavaScript Number. Inputs above 2^53 may lose integer precision, and converting a rounded Number to BigInt cannot restore it. Widened numeric controls allow the supported settings to be explored, but do not provide exact uint64 or uint128 endpoint evidence.

`engine.test.mjs` exercises explicit model promises and shared integer inputs. These are not an executed EVM differential test. Solidity boundary, overflow and transaction tests remain necessary. The model does not replace release gates or deployment rehearsal.

The pool price is represented by `balancePoolMult`; the balance module returns the configured per-point value. Every modeled composer passes the coin minimum. Migration, successors, rescues, ownership and real adapter execution are outside the economic simulation. Caller payments that are zero at launch are not modeled; listing and buyback gas payments use configured gas estimates.

`sim/data/` contains historical calibration pulls. `run.mjs` and the default `market.mjs` command perform broader historical grids; they were not rerun for decision 129. Previous headline totals and historical `out/` or `results/` reports predate the cap and updated launch settings and must not be treated as measurements of the current configuration.

## Decision 129 browser integration verification

The focused engine file passed 1,960 checks after the execution-step and hook-window fixes. The browser integration check builds the controls with a minimal DOM, verifies every initial contract setting against model defaults, exercises all seven new numeric controls and scheduled changes, rejects invalid settings, runs one day of the economic model, and compiles the generated page script. It does not measure browser painting or 90-day interactive latency. One measured Node integration run took 105 ms for the one-day economic simulation; longer horizons and finer steps require more work.
