# review of 02453e1..c8892a2 (NEXT 29, FLOW 55 and 56)

reviewer: read only, own clone at c8892a2. archive checks used b3f545c and 84ac86f in a throwaway worktree.

## findings, most severe first

1. HIGH, correctness defect (runbook), docs/DEPLOY.md:424 and :429. The settings struct lost 4 fields, the prose and the awk
   index did not follow. Text says "field 14 is saleFloorBps, 28 rateCap, 29 exitLaneToBuybackBps, 30 feeToBuybackBps". In the
   26 field tuple `T` they are fields 10, 24, 25, 26. Field 14 is `exitToBuybackBps`. Counterexample: the documented
   `awk '{$14=8000; ...}'` leaves `saleFloorBps` (live 7500) unchanged and writes `exitToBuybackBps` 8000 (live 5000). 8000 is
   inside that bound, so `setSettings` accepts it; the owner changes the exit share of every eth lane exit instead of the
   sale floor. `T` itself is right (`cast sig` of the tuple equals the Core selector 0x31a3365a).
2. MEDIUM, operational, docs/DEPLOY.md:106. The launch day helper `awk ... printf "%.0f", m, 10*m` runs in doubles. Per credit
   rates are now above 2^53 (9.007e15), the per point values were below it. Counterexample: M=10843444566111580 prints
   rateStart 10843444566111580, rateCap 108434445661115808, but 10*M is 108434445661115800. In 188 of 300 random medians in
   [9.1e15, 1.2e16] the two differ. Preflight row "rateCap is 10 times rateStart" then fails (fails closed at step 4, but the
   documented command produces an unusable pair for most real inputs). The default 0.0089 eth is exact only because 8.9e15 is
   below 2^53 and 8.9e16 has factor 2^15. Related: `jq` older than 1.7 rounds integers above 2^53 in the `RATE_START` and
   `SETTINGS` exports (rateCap 8.9e16 is above it); jq 1.7.1 here preserves them. Fix: integer arithmetic (`python3 -I` or `bc`).
3. MEDIUM, intent mismatch (docs), stale text in scope of "docs describe the code exactly":
   docs/ARCHITECTURE.md:176 "the relist after an overprint"; :350 gas row names `overprint` (1.37 million); :65 "buyback slice at
   most 2 ether" (bound is 1 ether, SettingsBounds.sol, pre existing); docs/INTEGRATION.md:151 retired Core "keeps `exitStatement`,
   `overprint`"; :229 event table still lists `XRateSet` (event and `setXRate` are gone, `ICore` has neither). At c8892a2 the
   section 1 rows 9, 17, 20, 25, 42, 46, 55 also named `flatBps`, hourly room, overprint, `wants`, CreditScore; at 84ac86f only
   line 9 still says "score can matter later through `flatBps`" (director owned).
4. LOW, missing evidence, test/invariant/Invariants.t.sol invariant_07 and invariant_19. Mutation in a copy: remove the pot
   clamp (`read = price` in `CoreLib.climb`) and the `PotTooSmall` check in `Core._spend`. In the default campaign (32 runs, depth
   64) invariant_07_noSpendAboveThePot and invariant_19_bidBounds still PASS; only invariant_06 fails. Invariant 19's clause
   `rate <= pot || rate == price` is true by construction under that mutation. Invariant 7 as written (HandlerBase.sol:757
   `_recordSpend`, costs from events against the ghost pot) is redundant with the checked `ethPot = p - x` and V_POT. It is
   meaningful as a statement and replaces the window invariant as FLOW 56 asked, but it did not exercise a thin pot in the default
   run. invariant_02 is not weakened: mutating `_sellForEth` to pay `ethRate() * 101 / 100` fails it ("sellForEth above the read
   taken before"). Code numbers shift consistently (g1..g13 all decremented past the removed code 18; checked pairwise).
5. LOW, behavior beyond a unit change (FLOW 56 consequences, not defects):
   a. clamp is the whole pot. Old clamp was `pot * spendCapBps / avgScore` per point, so at launch (`spendCapBps` 10_000, avgScore
      4_330_000) it equaled the pot per credit; same numbers. The owner's runtime brake (spendCapBps 100 to 10_000) is gone: one
      transaction can sell until `ethPot` is 0.
   b. dust pot. Old: pot of 1 wei read 0, `sellForEth` reverted `ZeroAmount` (deleted test_tinyPotSellsNothingAndBuysNothing). New:
      read is `min(price, pot)`, a pot of 1 wei pays 1 wei per credit and each such sale still drops the price state 0.5 percent.
      Old threshold for the same behavior was a pot under 433 wei, so the class is unchanged. Covered by
      `test_clampHoldsAtThePotWhenItAffordsLessThanOneCredit`; no test pins the 1 wei case.
   c. rate bounds are [1e13, 1e18], not the old bounds times 433 (4.33e13 to 4.33e17): lower edge 4.3x looser, upper 2.3x looser.
      Launch values (8.9e15, 8.9e16) sit inside both.
6. LOW, operational, archive moves (b3f545c): `project/evidence.json` record E-REVIEW-SALE-a3e2fa3 keeps
   `report.path` docs/REVIEW-sale.md (now docs/archive/); `director.py check --gate working` adds "report ... is not a regular
   tracked file" (the record was already invalid by scope). docs/FLOW.md:196 and :220 cite docs/V2-PORT.md; docs/HANDOFF.md:16 lists
   SPEC.md, docs/V2-PORT.md, BID-STUDY.md, V2-REQUESTS.md at old paths; docs/REVIEW-director-repair.md:29 cites docs/REVIEW-v2port.md;
   test/V2Stack.t.sol:239 cites V2-PORT; docs/SIMULATION.md:543 says results live at docs/archive/sim/results while `sim/run.mjs`
   still writes `sim/results/`. These files are outside the packet's ownership (FLOW, HANDOFF, project/).
7. CLEANUP, stale comments after the unit change: test/Redeem.t.sol:325 "opening rate and the average score";
   test/ReviewPort.t.sol:275 "`SUPPLY * 1e18 / (20 * AVG_SCORE * unit)`"; test/ReviewFlowCore.t.sol:491 "exit bid at 100 percent of score".

## verified correct

- Units: old per credit price was `avgScore * rate / 1e4` = 433 x rate at flatBps 10_000 and bonus 0 (ControllerV1.wants returned 0).
  Launch values convert exactly: rateStart 2.0554e13 x 433 = 8.89988e15 (new 8.9e15), rateCap 10x. Test fixtures converted by
  the same factor: OPEN_RATE 4e12 x 433 = 1.732e15, UNIT 1e10 x 4_330_000 = 4.33e16.
- No scale left: `climb`, `drop`, `adopt` (`price.max(1)`), `_notionalCap` (`PAGE * RATE_START`), `xRateOf` (`pot * BPS / unit`),
  `xFundedOf` (`pot * BPS >= r * unit`), `sellForExitToken` (`r * unit / BPS`), `_fullSlice` (`exitSliceCredits * unit`), lens
  `ethRate`/`ethPrice`. No overflow: rate <= 1e18 (uint64), unit <= uint128 and in practice <= 5e31 by the opening price check
  (`SUPPLY * 1e18 / slice >= 1e12`), loosened ceiling <= 1e31. Drop of 0.5 percent at the 1e13 bound is 5e10 wei, no rounding to zero.
- Unchanged math: `drop`, minute floor, `climb`, ceiling, idle loosening, `setRate`, `buyListing` (value, tip, `_spend(cost + tip)`),
  `migrate` (window reset removed only), buyback, sale pricing (`ControllerV1.statementPrice` untouched). BidModel (independent) changed
  only in `clamp`; BidRule (33), RateFuzz (6), Econ pass.
- Removals: grep of src, script, test finds no `HourlyCap`, `hourlyRoom`, window words, `overprint`, `nextOverprint`, `setXRate`,
  `XRateSet`, `ceilingOf`, `pileHead`, `pileNext`, `bidFor`, `scoreOf`, `CREDIT_SCORE`, `avgScore`, `flatBps`, `spendCapBps`
  (the only hits are intentional probes that `overprint` on the live Statements token is refused for strangers).
  `gen-interfaces.sh --check` passes. CoreState matches Core declaration order slot by slot (slots 0 to 21, retired at 21:29);
  CoreLayout (3) passes. Settings: 26 fields, three words 256/256/112 bits, pack, unpack, setSettings, SettingsFields, SettingsBounds,
  LaunchConfig, mainnet.json, `defaultSettings`, SetSettings TUPLE all agree (Flow.t.sol write/read fuzz passes).
- Phase 2: `exitStatement` requires `creditsOf * unitPerCredit` as a balance delta, computed before the transfer; Core `compose`
  forces `creditsOf == 80`. A dust, huge or lying `unitPerCredit` can only starve its own exit (`Underpaid`, `BadModule`, or
  `ZeroAmount` in `sellForExitToken` when `r * unit < 10_000`); a dust module taking statements is the case the section 10 trust
  note already admits. Opening price floor uses the same rule on the new slice.
- Script/preflight: `script/tools/check-preflight.sh` on the pin block: 110 of 113 pass, failed rows equal the 3 expected.
  `node sim/engine.test.mjs`: 529 checks pass; `sim/build.mjs` reproduces `sim/index.html` byte for byte.
- Sizes (forge build --sizes, runtime / init): Core 21,285 / 24,483, CoreLib 15,608 / 15,640, CoreLens 7,479 / 8,032,
  ControllerV1 4,282 / 4,997.
- Tests I ran (MAINNET_RPC_URL tenderly, FORK_BLOCK 26158000): Adopt, BidRule, BuildIdentity, Config, Econ, GasCap, Lens, Phase2Flex,
  ReviewPhase2Flex, SetSettings: 206 pass 1 skip (GasCap). CoreUnit, Flow, Lifecycle, Migrate, Redeem, ReviewEcon, ReviewFlowCore,
  ReviewMatrix, Seaport, Sale, ReviewSale, Gate, OwnerPowers, CoreLayout, PullFees and others matched by one glob: 38 suites, 449
  pass 0 fail. RateFuzz 6 pass. Invariants.t.sol InvariantsPhase1 and InvariantsPhase1Window, default runs: 12 pass.
- Archive (b3f545c): every moved path in README, ARCHITECTURE, SIMULATION, NEXT, sim and test comments resolves to docs/archive;
  `docs/archive/README.md` lists all 20 entries.

## not examined

full suite, Deep invariants, InvariantsPhase2 and hostile variants, Rehearsal, the combined 1013 count at c8892a2; sim figures in
SIMULATION.md (stated as not rerun); docs/FLOW.md and NEXT.md text; FeeRouter and hook paths (unchanged); whether the live Statements
`overprint` access control is as the probe tests assume beyond those tests; a real exit module (only the stand in exists); config
hash value; line by line review of the 3,000 changed test lines (read the diffs of Invariants, HandlerBase sell and listing paths,
Econ, Fees, Lifecycle, Migrate, BidModel, Fixture, MockExitModule).
