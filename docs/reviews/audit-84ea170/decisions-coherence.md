# Review of every owner decision (1 to 187) for coherence, main 84ea170

Sources: docs/DECISIONS.md in full (sections 1 to 11, decisions 1 to 187 and the mechanism notes), docs/SPEC.md in full,
docs/RUNBOOK.md sections 0 to 8, docs/AGENTS.md, src/** (read in full), script/config/*.json, script/Lock.s.sol,
test/utils/Fixture.sol and V2Stack.sol, and the deployed token deployer and hook bytecode on the fork at block 26222700
(selector probe). No prior review in docs/reviews was read.

Method. For every decision: (1) is it still live, superseded, or superseded without a marker (the log's own rule in its
preamble: "superseded text is marked in place"); (2) does the latest live decision agree with SPEC; (3) with the runbook;
(4) with the code; (5) do the variants it creates (mode switches, config files, fixtures) cohere with each other.
A finding needs two of these sources to disagree. Severity is about launch and owner risk, not style.

## A. Live decisions that the code or the docs contradict

### DC-01 (High, launch readiness) The phase two parameter set is undecided and partly impossible
- 153 fixes the switch spread at 200 bps; 162 fixes `tolBps` 100 and records that the loop closure minimum at that
  tolerance is 203; `ControllerV1._checkLoopClosure` (src/ControllerV1.sol:260 to 266) refuses spread 200 at tol 100;
  155(e) still says the 200 spread is applied in the switch transaction.
- `referenceMaxStale` and `minLiquidity` have no decided value (148: "tuned once the pool's depth is known"; runbook step 2
  leaves them as placeholders; script/dev/E2EReal.s.sol:507 rehearses 3,600 s). `spendCapBps` must be under 10,000 in
  value mode (src/lib/CoreLib.sol:272) and no decision picks a value; the runbook example uses 9,999, the e2e uses 1,000.
- docs/RUNBOOK.md:113 (value switch step 4) sets `saleFloorBps` 5,000 and both climbs 100. No decision authorizes
  `saleFloorBps` 5,000 (every held statement becomes sellable at half its cost at once); 155(a) kept the climb at 200
  "revisit after the first day", so the runbook reintroduces the value of 151 that 155 reversed.
- fix: one dated row "the value switch set" (cap, spread, tol, rate, step, stale, minLiquidity, spendCap, saleFloor,
  climb, ageEligibilityOn), a tracked `SETTINGS_PATCH` json the SetSettings script loads, pinned by a Config test.

### DC-02 (High, economic, to be confirmed by test) The value mode quote fallback (159 C02) removes the per fill drop
- 154 built value mode "fail closed to `NoQuote`". 159 C02 reversed it: `ethRate`, `bidOf` and `sellForEth` fall back to
  "the last good value rate kept in the eth instance checkpoint". 170 repeats "keep using the last good eth bid".
- code: in value mode `spend()` drops only the shared instance (src/lib/CoreLib.sol:375 to 389) and the fallback read is
  `c.rateAtCheckpoint` (CoreLib:549), which no fill changes. While the quote is unusable every credit is paid the same
  rate; the pot room and the spend cap are the only limits. A quote outage (liquidity under `minLiquidity`, a stalled
  keeper past `referenceMaxStale`, a pool key whose token no longer matches) therefore turns the bid into a fixed price.
  With the runbook's `spendCapBps` 9,999 example the cap is void. 159's text ("degrades pricing instead of halting") does
  not say that the degraded bid no longer falls with volume; the owner approved it on that text.
- fix: store the last good value per point and keep pricing off the shared instance (so its drop and climb still bind), or
  fail closed for `sellForEth` and leave only views on the fallback. Decide `spendCapBps` for value mode with this in view.

### DC-03 (Medium) Balance bid activation has two stances; the wiring runbook follows the superseded one
- 164: the 10 percent discount "is the buffer that keeps the engine's bid from being the binding arbitrage"; SPEC
  section 9: the bid opens whenever the owner turns it on. 170 (later the same day): the bid stays off until value mode is
  on; the hazard state is `balanceBidOn && !valueModeOn && poolKeySet`.
- docs/RUNBOOK.md "Wiring the production balance module (decision 144)" step 3 turns `balanceBidOn` on after setting the
  pool key, with no value mode: the hazard state the dev seed and `check-post.sh` refuse. The "the balance side" row of
  section 4 and "the value switch" follow 170. 155(f) (`feeToRedeemBurnBps` 1,000 "in the same transaction as
  `setBalanceModule`") is a third order; `setBalanceModule` and `setSettings` are two calls.
- the hazard condition is incoherent after 170 itself: with value mode off the key prices nothing (170), so the round trip
  (buy at the curve ask, sell for par tokens, sell tokens in the pool) exists whether or not the controller holds the key.

### DC-04 (Medium) SPEC still carries the pool term of `valueOf` in mode off, removed by 170
- docs/SPEC.md:211, :313 (14.19), :305 (14.11) describe `valueOf = max(rate term, pool value)` and `getSlot0` reads at
  launch. `ControllerV1._valueOf` (src/ControllerV1.sol:470 to 477) reads no pool with value mode off. Decisions 87, 88,
  91, 94 and 96(d), which define that pool floor, carry no supersession marker; 170 says it "amends 104 and 105" only.

### DC-05 (Medium) The hard rule bounds the balance payout by `balanceBidCapBps`, which 164 removed from that route
- docs/SPEC.md:39 and :253. After 164 the route pays `score * unit * (10,000 - balanceDiscountBps) / 10,000`
  (CoreLib:1218); `balanceBidCapBps` can be raised to uint32.max and bounds no token outflow; `available()` and the discount do.
- SPEC section 3 says `balanceBidCapBps` is "value mode only", but `floorMultBps()` multiplies the credit ask in both
  modes (ControllerV1:566 to 569, used by `_creditPrice` with value mode off). Raising the cap to 11,000 at the switch
  (152) raises every mode-off credit ask to 12,100 bps of value as well.

### DC-06 (Medium) Value mode balance clamp text predates 167 and 168
- docs/SPEC.md:158: "min(posted, bidForScore(score) * 1e18 / P_sell)" and "the Core keeps `posted` when ... the
  reference is unusable". Code: `balanceClampFor` uses `CORE.ethPrice()` (168) and returns `(0, true)` so the fill
  reverts `ZeroAmount` (167). 165 is not marked amended in place.

### DC-07 (Medium) Fee arithmetic in SPEC section 5 is the decision 120 split
- docs/SPEC.md:183 "1.0 eth to the protocol, 9.0 eth to the Core ... 0.9 eth to the reserve, 8.1 eth to the pot" per 100 eth.
  At 186 it is 0.69 and 6.21; at 155(f) nothing goes to the redeem burn pot. The same stale pattern sits in 10.9's table
  (9,638 bounty, 112,778 ppm) and in decisions 38, 59 and 112, none marked.

### DC-08 (Medium) The coin admin vocabulary of the superseded v2 revision survives in live text
- bytecode probe of the deployed token deployer 0x99EB38d6 at block 26222700: `lock()`, `locked()`, `unrestrict()`,
  `setAllowed`, `renounceAdmin()`, `setMetadataRenderer`, `updateImage`, `updateDescription` exist; `lockRecipients()` and
  `lockAllowlist()` do not. The hook has `setBountyRecipient`, `lowerBaselineSkim`, `setReferralBps`; no `setRewardRecipient`.
- live text naming the missing calls: docs/SPEC.md:251 (coin admin row), :298 (14.4); docs/RUNBOOK.md:30 (step 10), :81,
  :145 (lock table); decisions 40, 83, 109 unmarked. script/Lock.s.sol is correct (`lock()`), and it also freezes
  `lowerBaselineSkim`, which 126 says the owner wants to keep: the runbook pairing "lockRecipients with lockSuccessor"
  therefore describes a trade the owner has not been shown.
- docs/SPEC.md:259 "the factory owner lowers `minProtocolSkimShareBps` to 1,000" contradicts docs/RUNBOOK.md:23 and 126
  (the setter does not exist on the deployed factory; decisions 31 and 39 unmarked).
- docs/RUNBOOK.md:32 and :82 name `CoinRenderer` as the launch renderer; 160 names `LogoCoinRenderer` (127 unmarked);
  test/Config.t.sol:531 and :560 and the postflight row text say "CoinRenderer of the config".

### DC-09 (Medium) Return lock purpose (155c, SPEC 14.19) versus its buyer keyed design
- SPEC 14.19: the lock gives "time for the pool to move back after a manipulation". 155(c) keys it to the engine's buyer;
  167 notes that a credit "moved to a second wallet is not held by the return lock". One ERC721 transfer ends the lock.
  The log records a protection and, twelve rows later, that it does not protect. Key the lock to the credit id for every
  counterparty, or rewrite 14.19 to claim only the lazy round trip.

### DC-10 (Medium) Decision 158 versus 176 and the code
- 158: `adopt`, `_moveEth` and `_ethFloorNow` "clamp the eth price state to the pages pot less the reserve" and
  test/ClampDifferential.t.sol "pins the new numbers with pending income". 176 removed pending income from the climb
  target (booked room only). Code: all three read `_ethPrice`/`_ethClimb` (CoreLib:899, :1011, :1188), the price state
  climbed toward booked room, not lowered to any clamp (SPEC section 6 `adopt` and Core.sol:1305 say so). 158 is not marked;
  the test's promise line now reads "booked funded climb limit", so the test was retargeted while the decision was not.

### DC-11 (Low) Decision 178 "neither bid clock earns paused time" is not what the unpause does
- src/lib/CoreOpsLib.sol:55 to 69 shifts `peakTime`, `climbRestartTime` and `balance.lastFillTime` by the pause length but
  not the eth `lastFillTime`. `_ethClimb` anchors idle loosening on `max(lastFillTime, climbRestartTime)` (CoreLib:616);
  when the last fill is later than the last funded restart, the shifted restart overtakes the unshifted fill time and the
  ceiling gains up to `min(pause, lastFillTime - climbRestartTime)` of idle steps at resume. To confirm by test.

### DC-12 (Low) Decision 143's rationale is false at the integer floor
- `_drop` (CoreLib:806, :821) floors at `minuteStartRate * dropFloorBps / 10,000`, which is 0 under 10,000 wei, and
  `mulDiv` rounds to 0 at a few wei; `_climb` never climbs from `r == 0` (CoreLib:729). The rate can reach the absorbing
  zero after hundreds of fills across four buckets; `setRate` is the only way back. The claim is repeated at
  src/lib/SettingsBounds.sol:11. A `max(1)` on the dropped rate makes 143 true.

### DC-13 (Low) Decision 159 C02 says the refresh door pays "on the exact compose basis (`_payCaller`)"
- CoreLib.refreshReference (:509 to 511) pays `min(gas + 50,000, 200,000) * basefee + callerFee`; `_payCaller` counts up
  to 13,700,000. The keeper mirrors 200,000. Separately, once the quote triple is set any caller earns `callerFee` plus
  gas every `referenceMinSeconds` (about 0.13 eth a day at 3 gwei and 600 s); no decision prices that standing outflow.

### DC-14 (Low) Successor forbidden list (33, SPEC 11) versus `CoreLib.setSuccessor`
- SPEC: the successor "must pass the forbidden list". Code (CoreLib:963 to 969) refuses the Core, ever selected balance
  targets, the coin, Credits and Statements only; the hook, pool manager, factory, locker, escrow and Permit2 pass.
  Owner only, so a doc mismatch, but `migrate` to the escrow or pool manager strands the pot.

### DC-15 (Low) Gas bounds and sizes quoted in live text predate 169 and 178
- docs/SPEC.md:158 `valuePerPoint` "200,000 gas" (code 2,000,000); :190 adapter quote "300,000 gas" (code 2,000,000);
  SPEC 14.16 "about 91 credits" versus 169's measured 87; STATUS section 5 "538 bytes of headroom" (now 902; Core 23,674,
  CoreLib 23,635 at this build); 172's abort note says sells revert `ZeroAmount` (with the reserve: `PotTooSmall`, Core.sol:699).

## B. Supersessions the log does not mark in place (its own rule)

| decision | superseded by | what changed |
|---|---|---|
| 10.2, 10.3, 10.4 router steps, 10.8 (pullFees, FEE_SOURCE, flush gas tables) | 109 | FeeRouter removed; the Core is the bounty recipient |
| 10.9 table, 38, 59, 112 (bounty 9,638, payee 112,778 / 75,185 ppm) | 120, 186 | bounty 9,000, payee 0, skim 690 |
| 22 (`deployTokenAsOwner`), 29 (coin address a function of the router) | 126, 109 | `deployToken` on the deprecated factory; the Core is the bounty recipient |
| 31, 39 (`setMinProtocolSkimShareBps`) | 126 | setter removed from the stack |
| 34 and "mechanism of 34" (CoreLens) | 136 era | no lens exists in src/; the keeper reads through packages/engine |
| 40, 83, 109 (`lockRecipients`, `lockAllowlist`, `renounceAdmin` freezes recipients) | 126 | one `lock()` on the token |
| 44 (ceiling still loosens on an empty pot) | 176 | an underfunded interval adds no steps |
| 46 (keeper tip), 50 (idle 2,000), 69 (idle 200, drop floor 5,000, `tipSavingsBps`) | 71, 128, 146 | 600 / 1 / gas refund |
| 51 (slice bound 1 eth), 61 (fee 0.0005, 10 gwei, bound 0.005) | 119, 130 | 0.0003 / 5 gwei / uint widths |
| 52 (xToBuyback stays on migrate) | 117 | no balance pots in the Core |
| 55, 80 (flat per credit bid) | 116, 145 | per point |
| 58 (115 credits per batch, 20 percent minute floor) | 146, 169 | 87 credits, floor 1 bps |
| 62, 65 (knee, two decay rates) | 121 | one straight line over `decayHours` |
| 73 (no Seaport adapter) | 100 | adapters |
| 81 (pause in the sale controller) | 97, 178 | pause on the Core |
| 84 (eligible at cost, 20 percent exit margin), 86 (exitMode, 10 percent fee to reserve, 50 percent to buyback), 87, 88, 91, 94, 96(d) (pool backed floors in mode off) | 105, 107, 119, 155(f), 164, 170 | see DC-04 |
| 104 (pointValue with the live pool) | 170 | rate term only in mode off |
| 120 (10 percent skim), 121 (decayHours 12), 122 (rising balance bid), 127 (CoinRenderer at launch), 148 (eth routes halt on an unusable reference), 151 (climb 100), 158, 165 | 186, 154, 164, 160, 159, 155, 176, 167/168 | as above |

Two rows contradict each other on the same day without a marker: 128 says "`climbPerMinBps` stays 50" while the 128
amendment appended to 119 says "`climbPerMinBps` 100 (was 50)"; 141 then set 200.

## C. Decisions whose numbers were never pinned anywhere a test or script reads
- 148/157: reference rate 1,200, step 200, cadence 600 (runbook prose only); `referenceMaxStale`, `minLiquidity` (none).
- 152/153/162: switch cap 11,000, spread 200 (impossible at tol 100), tol 100 (config has tol 100 and spread 1,000 only).
- 154/157: `spendCapBps` under 10,000 in value mode (no value).
- 155(d): `ageEligibilityOn` "turned on with the value switch" (runbook step 4 does not set it).
- 155(f): `feeToRedeemBurnBps` 1,000 at phase two (wiring section omits it).
- 187: `rateStart` deploy day refresh (recorded as pending; preflight checks only the 3x ratio).

## D. Variants

### D1. Mode matrix (valueModeOn x balanceBidOn x module x pool key x ageEligibilityOn x paused x retired)
- coherent in code: pause scope (178); retired engine keeps `sellTo`, `redeemStatement`, `buyback`, `book`, `fund`,
  `setHeldFormat`; value mode forces an active spend cap; turning value mode on resets the shared instance; turning it
  off reseeds the eth instance from the quote or the last good rate.
- incoherent: value mode with an unusable quote (DC-02); balance bid on with value mode off (DC-03: allowed by code and by
  one runbook section, refused by the seed and another section); `balanceBidCapBps` described as value mode only while
  it moves mode-off asks (DC-05); the return lock as a manipulation defense (DC-09).
- not reachable by design but unguarded: value mode on with no module or key (the bid freezes at the last mode-off rate,
  the special case of DC-02); `setSettings` lets the owner do it in one call.

### D2. Launch config variants
- mainnet.json, anvil.json and rehearsal.json differ only in `image` and `description`: coherent. rehearsal.json carries
  PLACEHOLDER values that fail its own preflight by design (docs/RUNBOOK.md signer drill), so the shipped rehearsal
  variant never passes without a hand edited copy.
- `.env.example` pins `FORK_BLOCK` 26158000, before the live factory existed (26202473); the default fixture
  (`V2Stack.attach()` on v2-mainnet.json) cannot run at that block. test/utils/CreditIds.sol is also pinned to 26158000.

### D3. STACK=master
- 126 justified the master fork fixture because "the stack is not yet on mainnet". v2-mainnet.json records the live stack
  at the same launcher commit `6d099486`, deployed 2026-10-15. The master dump (script/config/stack-master-26158000.hex),
  v2-master.json, `STACK=master` in anvil.sh, Fixture, V2Stack, local.sh, keeper e2e and the runbook are a second code
  path that no release gate needs and that pins a pre-launch block. test/utils/V2Stack.sol:31 calls the live record "the
  superseded live record", the inverse of the truth. Retire the variant or state why it is kept.

### D4. Fixture settings variant (test/utils/Fixture.sol:181 to 189)
- the general suite runs with `reserveWei` 0 (launch 1e17), credit sale off (launch on), opening rate 1.732e15 (launch
  4.9e15), mock module unit 1e10 (production 1e14), spend cap 10,000 with a comment written when launch was 100. The
  reserve, the funded clock boundary (0.1050225 eth) and the four hour compose wait are exercised only by the suites that
  override these. Whether that leaves a gap is for the test audit; the decisions do not record that the invariants run on
  a non launch configuration.

## E. Decisions whose rationale rests on an estimate the log later disowns or on no measurement
- 74 quoted "about 35 minutes and 1.75 hours"; 75 records those were estimates, not measurements, and gives 47 and 134.
- 43 (the engine must not push the floor down): the director note says the simulator models no competing bidders, so the
  effect is unproved; no later decision closes it.
- 42 (never locks while credits are listed): the guarantee as built is "at or below `rateCap`" plus, now, the reserve
  (`PotTooSmall`), the return lock, the funded clock, and the zero rate of DC-12; the SPEC guarantee row lists the first
  three, not the fourth.
- 164's "at 90 the engine keeps about 6 percent per cycle" and 163's "about 2 eth per 1,000 eth of volume" are prose
  figures with no sim or test cited.

## F. What coheres (checked)
- climb 200 (141 -> 151 -> 154 -> 155a), spend cap 10,000 (129 -> 146), tol 100 (153 -> 161 -> 162), drop 115 per 100
  points (141 -> 145), rateStart 0.0049 / cap 3x (145, 187), skim 690 / 9,000 / 1,800 (186), artist and operator cuts
  (123, 163), flat balance bid at 9,000 bps of par (164), ownerless module with `migrateReserve` (144, 171): config,
  `Mainnet.default*`, SPEC sections 1 and 3 and the code agree.
- funded clock (176) versus pending income clamp (147): code climbs the stored state toward booked room and clamps the
  read to the pages pot; SPEC section 4 states the same.
- one pile, per point pricing, cost basis with royalty (116, 145, 163): code and SPEC agree.
- the module (144, 166, 171): code matches each clause, including `available()` gates and the owed ledger.
