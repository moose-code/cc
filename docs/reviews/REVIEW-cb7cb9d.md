# Security review of cb7cb9d (fix of docs/reviews/REVIEW-security-45cfc62.md)

Reviewer: independent, read only. Clone `/private/tmp/rev-cb7cb9d` at 588d70f (frozen candidate cb7cb9d plus the state
file), submodules initialised, `out/` and `cache/` copied from the original worktree, `forge clean` not run. Fork tests
at `MAINNET_RPC_URL=https://gateway.tenderly.co/public/mainnet FORK_BLOCK=26158000`. Toolchain forge 1.8.1.

## Scope

`git diff 45cfc62 cb7cb9d -- src script test`: the recovery level `levelT = peakT * (10_000 - recoveryGapBps) / 10_000`
in `CoreLib._recover`, the peak checkpoint on a `peakHalfLife` change in `CoreLib.setSettings`, `recoveryGapBps` as field
27 of `Settings` (word d, bits 112 to 127) with bound 0 to 5,000, the metadata scheme rule in `script/Checks.sol`, the
settings scripts and tables (`SettingsFields`, `SetSettings`, `LaunchConfig`, both configs), and `test/RecoveryOracle.t.sol`.

Scratch PoC (removed from the tree before part 2, copy at `poc/SecPocCb7.t.sol.txt`): 12 tests, all pass.
Touched suites by path, all pass: Recovery 8, RecoveryOracle 2, BuildIdentity 5, Config 32, Flow 46, ReviewFlowCore 16,
ReviewMatrix 11, ReviewSale 47, invariant/RateFuzz 6. `script/tools/gen-interfaces.sh --check` exits 0.

## Findings, most severe first

### M1 (medium, owner intent) Recovery after a dump is now slower than the figure the owner rejected

Measured at launch settings (PoC `test_gapTradeoff`, the same scenarios as `test/Recovery.t.sol`): a one minute dump
of 140 credits recovers to the pre dump price in 59 minutes, a three minute dump of 420 credits in 146 minutes
(2.43 hours). Decision 74 in `docs/DECISIONS.md:409` records the owner's words on a 2.3 hour recovery ("still seems too
long, no?") and his approval of the remembered peak rule against the figures "about 35 minutes and 1.75 hours". Those
figures are still in the decision text. The built rule measures 45 and 131 minutes at gap 0 (the 45cfc62 rule), and the
gap of 1,000 adds 14 and 15 minutes. The value 1,000 was set by the director amendment, and the owner has not seen the
recovery times it produces.

The gap needed to close the old M1 is small. Any gap above one drop (50 bps) keeps a single credit sale on the slow
climb:

| recoveryGapBps | 1 min dump, minutes | 3 min dump, minutes | lone seller, credits per hour at >= P | eth per hour | batch seller (k = gap/50 + 1 credits per sale), credits per hour | trickle overpay, first hour (eth) |
|---|---|---|---|---|---|---|
| 0 | 45 | 131 | 188 | 1.673 | 188 | 0.490 |
| 60 | 46 | 132 | 60 | 0.534 | 82 | 0.385 |
| 100 | 46 | 133 | 60 | 0.534 | 78 | 0.379 |
| 200 | 47 | 134 | 60 | 0.534 | 70 | 0.364 |
| 300 | 49 | 135 | 60 | 0.534 | 70 | 0.350 |
| 500 | 52 | 138 | 60 | 0.534 | 66 | 0.322 |
| 1000 | 59 | 146 | 60 | 0.534 | 63 | 0.259 |

P is the launch `rateStart` 0.0089 eth. The trickle column is defined under L1.

Fix (owner decision): show the owner this table and record his choice of `recoveryGapBps`. A gap of 100 to 200 closes
the at peak case as fully as 1,000 and costs 1 to 3 minutes. Recovery inside 1.75 hours for the three minute dump needs
a different lever (`recoveryClimbPerMinBps`), since even gap 0 measures 131 minutes. Update the figures in decision 74.

### L1 (low, residual of the old M1) A trickle seller holds the bid near the decaying recovery level after a market fall

Scenario (PoC `test_M1_trickleOverpay`, launch settings, P = 0.0089 eth): `setRate(P)`, the market falls to M = 0.7 P,
one seller sells one credit every `q` seconds while the read is at least M.

| q | rule | credits in 2 h | overpay over M (eth) | read at 2 h, bps of P |
|---|---|---|---|---|
| 20 s (3 a minute) | launch (gap 1000) | 360 | 0.352 | 7,150 |
| 20 s | gap 0 (45cfc62) | 360 | 1.000 | 10,246 |
| 20 s | recovery = climb (before decision 74) | 191 | 0.136 | 6,984 |
| 30 s | launch | 240 | 0.255 | 7,162 |
| 30 s | gap 0 | 240 | 0.888 | 12,408 |
| 30 s | recovery = climb | 191 | 0.179 | 6,984 |
| 60 s | launch | 120 | 0.319 | 9,970 |
| 60 s | gap 0 | 120 | 0.568 | 15,025 |
| 60 s | recovery = climb | 120 | 0.319 | 9,970 |

Between about 1 and 4 credits a minute the bid sits at the recovery level, which decays with the peak because a fill
below the peak keeps the decayed value. The overpay therefore ends: here the read reaches the market in about 2 hours,
and the total is about 0.35 eth against 0.14 eth under the old rule. At gap 0 it was unbounded (the bid held at or above
P). At 1 credit a minute the launch rule equals the old rule exactly (0.319 eth in 2 h, the bid held at P by the slow
climb), which is the accepted behaviour before decision 74.

Fix: none required. Record the residual with these numbers next to decision 74, or include it in the owner choice of M1.
The keeper's `buyListing` and competing sellers cut it, as before.

### I1 (info) Settings NatSpec for the two recovery fields is stale or ambiguous

- `src/interfaces/Interfaces.sol:112-113`: `recoveryClimbPerMinBps` still reads "while the price state is below the
  remembered peak ... at or above the peak the rate climbs `climbPerMinBps`". Corrected: "climb of the eth rate per
  minute while the price state is below the recovery level `peak * (10_000 - recoveryGapBps) / 10_000`, bps,
  compounded. at or above the level the rate climbs `climbPerMinBps`. at least `climbPerMinBps`".
- `src/interfaces/Interfaces.sol:145` and the `recoveryGapBps` row of `docs/RUNBOOK.md:171`: "below `recoveryGapBps` of
  the remembered peak" reads as "below 10 percent of the peak". Corrected: "while the price state is more than
  `recoveryGapBps` below the remembered peak, bps of the peak".

Comments only. A change of `Interfaces.sol` comments leaves the runtime bytecode and the build pins unchanged.

### I2 (info) Stale figures and comments outside src

- `docs/DECISIONS.md:409`, decision 74: "while the price state is below the remembered peak the bid climbs
  `recoveryClimbPerMinBps`" and "about 35 minutes and 1.75 hours". The appended amendment names the gap; the measured
  figures at the launch gap are 59 minutes and 146 minutes.
- `test/Recovery.t.sol:84-85` (`test_marketFallOvershootBounded`): "the price state is below the peak, so it climbs at the
  fast recovery rate". A 15 credit batch walks the bid about 7 percent, inside the 10 percent gap, so the first steps
  climb at `climbPerMinBps`. The test passes (612 bps); the comment describes the 45cfc62 rule.

### I3 (info) The metadata guard checks a normalised value and the launch stores the raw value

`script/Checks.sol:358-362` lowercases and trims `image` before the scheme match. `script/Builder.sol:40` passes
`l.image` unchanged to the factory, and Postflight compares the raw string. So `"  IPFS://bafy..."` passes preflight and
goes on chain with the leading spaces and the upper case scheme, which some gateways and indexers do not resolve.
`data:x` also passes (any content after `data:`). Fix: require `image` to equal `vm.trim(image)` and the scheme prefix to
be lower case, or write the trimmed value into the launch. Recoverable with `updateImage` until `renounceAdmin`.

### I4 (info) Oracle coverage limits

`test/RecoveryOracle.t.sol` is independent of the closed form: `_stepSim` applies the fast or slow per step growth by
comparing the state with the decaying level each step and never reads `crossWadSec`. Limits: `_peakAt` restates
`Halving.halve` for the starting peak (an input, not the code under test); the fuzz uses 1 s steps with a 0.3 percent
tolerance, justified by one fast step at 1,000 bps a minute (0.17 percent); the `priceCross >= target` branch and the
`levelT <= r` branch are reached only by chance in the fuzz. PoC `test_crossingExactEveryGap` and
`testFuzz_monotoneAnyGap` cover the gap edges explicitly (below).

## Verified correct

- Old M1 closed for the stated case. Lone seller of one credit whenever the read is at least P, polled every 3 s for one
  hour, launch settings at P = 0.0089 eth: 60 credits, 0.5341 eth an hour. Recovery = climb (the old rule): 60 credits,
  0.5341 eth. Gap 0 (45cfc62): 188 credits, 1.673 eth. Gap 5,000: 60 credits. `test_loneSellerFlatPriceThroughput` in the
  suite measures 60 at `OPEN_RATE`.
- Crossing exact. With the level proportional to the peak, the level decays at the peak's rate, so
  `crossWadSec = ln(levelT / r) / (lnFast/60 + ln2/H)` solves `r * fast^(s/60) = levelT * 2^(-s/H)`. Against a 0.1 s step
  simulation at the launch climb, recovery and half life, peak 4 r, elapsed 60 s, crossing minus 1, crossing, crossing
  plus 1, plus 600 s, 3 h and 12 h:

  | gap | analytic crossing (s) | max error, closed form vs simulation | price at the crossing second vs level |
  |---|---|---|---|
  | 0 | 3,828 | 18 ppm | -45 ppm |
  | 1,000 | 3,537 | 4 ppm | -66 ppm |
  | 2,500 | 3,033 | 20 ppm | -260 ppm |
  | 5,000 | 1,914 | 9 ppm | -22 ppm |

  The price at the whole crossing second sits below the level by less than one second of fast climb (333 ppm at
  200 bps a minute), so the legs join without a jump.
- Monotone. `testFuzz_monotoneAnyGap` (256 runs): climb 1 to 1,000, recovery from climb to 1,000, half life 600 to
  604,800, gap 0 to 5,000, peak 1.001 to 50 times the state, eight reads 0 to 30 minutes apart with the ceiling clear: the
  price state never falls. `test_extremeRatioEdges`: r = 1 wei, peak 1e18, gap 0, 1 and 5,000, climb 1 and 1,000, half
  life 600 and 604,800, elapsed 1 s to 200 years: monotone and at most 1e18.
- Revert freedom. `testFuzz_noRevertAnyStateAnyGap` (256 runs, a quarter at gap 0, a quarter at 5,000, the rest uniform):
  the 45cfc62 domains (every legal climb, recovery, half life, ceiling, loosen and rate cap, r, last fill rate and peak 0
  to 1e18, peak zero, pot up to 1e24 wei, elapsed up to 200 years) plus the gap. `ethPrice`, `ethRate`, `skim`, a
  `sellForEth` fill and a following `peakHalfLife` change all succeed. By hand: `levelT <= peakT <= 1e18`, so
  `peakT * 10_000` and `levelT * 1e18` fit; the `lnWad` argument is at least 1e18 on the fast path; the `levelT <= r`
  branch covers `levelT` zero; `denom` and the `expWad` bounds are unchanged from 45cfc62.
- Path independence with a gap. `testFuzz_pathIndependenceGap` (256 runs, gap 0 to 5,000, dump 1 to 140, forced
  checkpoints every 1 to 120 s for 40 minutes, ceiling clear): forced never above lazy, within 0.1 bps.
- I1 checkpoint. `CoreLib.sol:141-147` restates `peakRate` with `Halving.halve(peakRate, now - peakTime, oldHalf)` and
  sets `peakTime` to now, before `s.peakHalfLife` is overwritten (`CoreLib.sol:157`). `testFuzz_halfLifeCheckpoint`
  (256 runs, old and new half life 600 to 604,800, a dump of 1 to 140 credits, age 0 to 30 days): the restated peak
  equals the peak now at the old half life exactly, `peakTime` is now, and `ethPrice` and `ethRate` are unchanged across
  the change. An unchanged half life leaves both words untouched (suite test and PoC). Constructor: the Core writes the
  peak at `Core.sol:306-307` and then calls `CoreLib.setSettings` (`Core.sol:315`) with the stored half life zero, so the
  branch is skipped. The skip is required: `Halving.halve` divides by the half life. After deploy the stored peak is
  `rateStart` (`test_constructorPeak`). Every later half life is at least 600, so the zero guard matches only the
  constructor.
- Storage. Word d: `callerFee` bits 0 to 63, `callerMaxBaseFee` 64 to 111, `recoveryGapBps` 112 to 127.
  `unpack` (`CoreLib.sol:209`), the compiler layout (ReviewFlowCore asserts bits 112 to 127 and the top bits above 128
  clear), `setSettings`, `SettingsFields` (index 26), the `SetSettings` tuple, `ConfigReader` and the DEPLOY `SETTINGS`
  jq and constructor tuple agree on 27 fields. `CoreState` and `RateStore` words are unchanged.
- Bounds. `recoveryGapBps` at most 5,000 (`SettingsBounds.sol:25`), mirrored in the invariant handler and in
  `SettingsFields.hi`; both edges accepted and 5,001 refused (Flow, ReviewSale, ReviewMatrix).
- Behaviour outside the change. `src/Core.sol` changes a comment only. The ABI changes by the appended struct field:
  `setSettings` and `settings()` carry 27 fields, the Core forwards under `CoreLib.setSettings.selector`, ControllerV1
  decodes `settings()` from the same struct and was rebuilt (`BUILD_HASH_CONTROLLER` updated, sizes repinned in
  BuildIdentity). Both configs and `Mainnet.defaultSettings` set the gap to 1,000. Postflight and Resume compare the whole
  struct by hash, so the new field is covered. Gas: `ethPrice` 23,954 at or above the cap, 34,268 below the level past a
  crossing (30,378 at 45cfc62: one more cold load of settings word d), 38,169 ten hours later.
- Metadata rule. Upper case schemes, leading whitespace and `data:` pass, `http://` fails, an empty scheme fails
  (Config 32 pass). See I3 for the stored value.
- L1 of 45cfc62 (the read can fall between fills) is documented in `docs/RUNBOOK.md:435`, docs/SPEC.md and
  docs/INTEGRATION.md.

## Not examined

`sim/` (engine.js, index.html, engine.test.mjs). The full suite and the Deep invariants. The off chain keeper and
frontend handling of the slower in-gap climb. Gas of `buyListing` and `compose` under the new settings word load. Fork
behaviour after the pin block (part 2 covers the latest block for the deploy path only).
