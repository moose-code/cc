# Security review of 45cfc62 (decision 74 and companions)

Reviewer: independent, read only. Clone `/private/tmp/sec-45cfc62` at 45cfc62. Fork tests at
`MAINNET_RPC_URL=https://gateway.tenderly.co/public/mainnet FORK_BLOCK=26158000`.

## Scope

`git diff 483be30 45cfc62 -- src script test`: the remembered peak and dual speed climb (`CoreLib.climb`, `_recover`,
`_climbTo`, `drop`), `RateStore` at 4 words, `Settings` at 26 fields (`peakHalfLife`, `recoveryClimbPerMinBps`, bounds,
pack and unpack, scripts), `setRate` and the constructor restating the peak, `_payCaller` metering the checkpoint
(`COMPOSE_OVERHEAD_GAS` 60k to 50k), the test model `test/utils/BidModel.sol`, and the metadata guard in
`script/Checks.sol`. Launch values from `script/config/mainnet.json` (rateStart 0.0089 eth, drop 50 bps, climb 50 bps,
recovery 200 bps, half life 21,600 s, ceil 11,000, loosen 200, rateCap 0.0267 eth, caller pay 0).

Scratch PoC: `test/SecPoc45.t.sol` (7 tests, all pass). Existing suites run by path: Recovery 5/5, CallerPay 12/12,
Config 32/32, Flow 46/46, CoreLayout 3/3.

## Findings

### M1 (medium, economic, owner decision) The fast climb applies after every fill, so a flat bid absorbs 3.1x the sell volume

`CoreLib.sol:286-287` sets the peak to the fill price on every fill, and the drop leaves the price state 0.5 percent
below it, so `_recover` (`CoreLib.sol:240-260`) climbs at `recoveryClimbPerMinBps` after any sale of one credit. The
0.5 percent per minute climb now governs only above the last fill price. Decision 74 is written as recovery "after a
large sale walks the bid down"; the code makes every sale a recovery.

Sequence (PoC `test_flatPriceThroughput`, launch settings): `setRate(OPEN_RATE)`, then a lone seller sells one credit
whenever `ethRate() >= OPEN_RATE`, checked every 3 s for one hour. Recovery 200: 188 credits at or above the opening
price. Recovery = climb (the old rule): 60 credits. The bid drops 0.5 percent, regains the peak in about 15 s, and the
peak never decays because each fill rewrites it at the fill price. At the launch rateStart this is about 1.67 eth an
hour at a flat price, against 0.53 eth before.

Worst overpay: after a real market fall to M below the held price P, a seller (or a trickle of sellers) below about 3.1
credits a minute keeps the bid at P indefinitely. With P minus M at 30 percent of 0.0089 eth that is about 0.50 eth an
hour of overpay from `ethPot`, against about 0.16 eth an hour under the old rule. Competing sellers and the keeper's
`buyListing` at market prices both cut it, as before; the change is the volume needed to move the bid down (4x).

Fix (owner choice): apply the recovery climb only when the price state is below the peak by more than a gap (for example
`peakT * (10_000 - recoveryGapBps) / 10_000`, a gap of several drops). The crossing stays closed form: replace `peakT`
with the gapped level in `_recover`. Or record the decision as accepted with these numbers.

### L1 (low) The read can now fall with no fill; the monotone read check was removed

The ceiling is `ceilBps` of `max(lastFillRate, peakNow)` (`CoreLib.sol:221-224`), and `peakNow` decays, so the cap falls
between the 10 minute loosen steps and a price state above it is cut to it. `test/CoreUnit.t.sol:1482` replaced "the read
does not fall with time" with "the read is at most the price state". The replacement is correct for the new rule. Sellers
are covered by `sellForEth(ids, minOut)`. The fall is bounded by the peak decay (at most about 0.19 percent a minute at a
6 hour half life) and stops at `ceilBps` of the last fill rate grown by the loosen. Fix: state in docs/DECISIONS.md and the
keeper and frontend notes that the bid can fall between fills.

### I1 (info) Changing `peakHalfLife` rescales decay already elapsed

`peakTime` is not rebased by `setSettings` (`CoreLib.sol:145`). A peak 6 hours old at a 6 hour half life reads 0.5 P; set
the half life to 7 days and it reads 0.976 P, so the ceiling roughly doubles at once. Owner only, the Core checkpoints
before the write. Fix if wanted: have `setSettings` rebase the peak (`peakRate = peakNow`, `peakTime = now`) before
storing a new half life.

### I2 (info) `BidModel._recover` and `_climbTo` are verbatim copies of `CoreLib`

The model mirrors the code: same branch order, same truncations, same `zeroFloorSub` (checked line by line against
`CoreLib.sol:216-269`); it was not bent to pass. It cannot catch a wrong closed form, because a copy agrees with any bug.
The hand arithmetic tests (`BidRule`, `CoreUnit.test_rate_dropAndClockResetOnFill`) set recovery equal to climb, so the
launch climb has only the range checks of `test/Recovery.t.sol`. The PoC adds the missing independent oracle (a 0.1 s
step simulation of "fast below the decaying peak, slow at or above it"). Suggest moving `testFuzz_closedFormMatchesStepSim`
or `test_closedFormLaunchErr` into the suite.

### I3 (info) The metadata guard refuses some real formats

`script/Checks.sol:323-368`. Refused: `data:` URIs (an onchain image within 2,048 bytes), `http://`, an upper case scheme
(`IPFS://`), any leading whitespace before the scheme (`_hasScheme` reads the untrimmed value). Accepted junk:
`https://example.com/cc.png` (the test uses it as the valid case), `N/A`, `test`, a description of one character. No empty
or marker value reaches a mainnet launch: on chain id 1 the row is a `_check`, `Deploy.s.sol:36-38` runs every preflight check
first and reverts on a failure, and the tracked `mainnet.json` has empty `image` and `description`, so it fails until the
owner fills them. Recoverable through `updateImage` and `updateDescription` until `renounceAdmin`.

### I4 (info, outside the diff) The caller payment counts gas the refund returns

At a 10 gwei ceiling, compose counted 10,612,468 gas against a gross of 10,599,937 and a refund of 2,119,987
(`CallerPay` log). The 50k overhead overshoots the gross by about 12.5k gas (inside the suite's 20k bound). Counting the
gross, so paying for refunded gas, is unchanged by this diff. Both caller settings are 0 at launch.

## Verified correct

- Crossing math. `crossWadSec = ln(peakT/r) / (lnFast/60 + ln2/H)` in wad seconds is the solution of
  `r * fast^(s/60) = peakT * 2^(-s/H)`. Against a 0.1 s step simulation at launch settings with the peak at 2r: error 0
  ppm at 60, 600 and 1,800 s, minus 9 ppm past the crossing (discretisation). Fuzzed over every legal climb, recovery
  and half life: within 0.2 percent (`testFuzz_closedFormMatchesStepSim`, 256 runs).
- Path independence. Forced checkpoints (skim with 1 wei, every 1 to 300 s) never raise the price state. With no clamp
  binding they match the lazy read within 0.1 bps (`testFuzz_pathIndependenceNoCap`). With the ceiling binding the forced
  path can be lower (1.47 percent measured): the old idle loosen step behaviour, and it favours the pot.
- Revert freedom and domains. `testFuzz_noRevertAnyState` (256 runs): every legal setting (half life 600 to 604,800,
  recovery equal to climb, climb 1 to 1,000, rateCap 1e13 to 1e18), r, last fill rate and peak from 0 to 1e18, peak below
  or above the price, peak zero, any pot up to 1e24 wei, elapsed up to 200 years. `ethPrice`, `ethRate`, `skim` (a
  checkpoint write) and a `sellForEth` fill all succeed. By hand: `denom` is at least 2.8e12 (climb 1 bps, half life 7
  days); every `lnWad` argument is at least 1e18; `expWad` gets x below `ln(target/base)`, at most 83e18; the largest
  product is about 1.6e44.
- Gas. The climb is constant time: `ethPrice` costs 23,954 gas on the slow path and 30,378 past a crossing. `receive()` runs
  inside the router flush with up to `PULL_GAS` (1,000,000). No door gains a loop.
- Peak manipulation. A fill writes the price state, never the paid cost, so a self dealt `buyListing` at any cost sets the
  peak to at most the current price state. That is bounded by `ceilBps` of the anchor grown by the loosen and by `rateCap`
  (0.0267 eth). The upward ratchet at the ceiling (sell at 1.1 A, climb to 1.21 A) takes about 19.1 minutes, against 20.1
  before. The fast leg only covers the 0.5 percent drop. `setRate` is owner only and resets the peak in both directions.
- `_payCaller` (`Core.sol:654-662`). Both settings zero returns before `_checkpoint` and before metering, so launch pays 0
  and leaves the checkpoint untouched (`test_launchSettingsPayZero`). When paying, the checkpoint comes before the `ethPot`
  debit, so the climb to the old pot is credited first. The payment stays capped by `gasCap` and the pot.
- Storage. `RateStore` words: 0 `lastFillRate`, 1 `minuteStartRate`, 2 `minuteBucket` (bits 0 to 63) and `peakTime` (bits
  64 to 127), 3 `peakRate`. Writers: the constructor, `setRate` and `drop`. Readers: `climb`, `_recover`, and the test
  helpers (which use the same offsets). `peakTime` is at most `checkpointTime` on every path. `CoreState` is unchanged
  (`CoreLayout` passes). Settings word a: `peakHalfLife` at bits 160 to 191, `recoveryClimbPerMinBps` at bits 192 to 207,
  checked by Flow. `unpack`, `setSettings`, `SettingsFields`, the `SetSettings` tuple and `ConfigReader` agree on the
  26 field order. ControllerV1 decodes `settings()` and was rebuilt (`BUILD_HASH_CONTROLLER` updated).
- Bounds. `recoveryClimbPerMinBps` is at least `climbPerMinBps` and at most 1,000; `peakHalfLife` is 600 to 604,800 s.

## Not examined

Off chain keeper and frontend handling of a bid that falls between fills. The deep invariant run. The full suite. The
rehearsal. `adopt` cost basis under the faster recovery (cost basis is the price state, so it is higher more often; it
pays nothing out). Fork behaviour after the pin block.
