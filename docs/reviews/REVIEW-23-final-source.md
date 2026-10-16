# Issue 23 independent implementation review

Reviewer: independent `/root/review` agent, using a separate clone and making no implementation edits.

## Reviewed identity

Final source and test snapshot: parent commit `3a0670d41f1d7ef7d8f6e27810c001b203c2147a` plus `/private/tmp/issue23-final-test-delta.patch`, SHA256 `5e8a3be9e4ab1f9103a41436537d9d7c3b81f779aa48e991cf2ad2e0d268e198`. The patch is a complete replacement working diff, applied after resetting the review clone to that commit. It includes the new `test/SpendCap.t.sol`.

Prior snapshots reviewed: `2e8330c` plus source patch SHA256 `8295dd535fb42af4f69f511e79265667ec48fea51371accdf15ef71e59901dd8`, then `72e5688` plus source patch SHA256 `355bef4976b7fa64b2374c50b269d4b692b1871709626378d2c79a0815c7661b`. Original findings and counterexamples are in `REVIEW-23-source-8295dd.md`.

Authority: the owner's implementation approval and decisions 129/130. The review challenged the new purchase budget, settings transitions, configurable balance cap, timing units, keeper payment, anchor movement, storage and ABI consumers, simulator parity, owner tooling and independent test models.

## Findings and dispositions

No unresolved production-code finding was identified in the final snapshot. The following concrete findings were returned to implementers and repaired independently of the reviewer:

1. Combined Core/controller settings preview and broadcast ordering: repaired by preparing changes once, selecting a valid sale/Core order, simulating that exact batch under a snapshot, restoring it, and broadcasting the cached batch. `test_combinedFloorAndMarkupUpdatesBothDirections` covers both dependency directions; the preview regression checks that the change remains planned afterward.
2. Simulator duration changes losing bid-drop floors: repaired in `7dcd4af` by rebasing both ETH and balance floors using old-duration expiration before translation. Active and expired cases are tested, including a numeric bucket collision.
3. Simulator listing keeper payment exceeding remaining pot: repaired in `7dcd4af` with the third payment clamp. Its regression buys a credit using the entire 0.01 ETH pot with a score-scaled 0.02 ETH ceiling and zero keeper payment.
4. Balance invariant picker and payout ceiling retaining a hardcoded par cap: repaired. The picker now uses `balanceBidCapBps`; independent payout bounds sum each credit's `floor(par * configuredCap / 10,000)`.
5. Listing invariant rejecting a legitimate keeper payment limited by remaining pot: repaired. Its permissible gap is the minimum of bid room and pot room, while the payment formula and gas ceiling checks remain.
6. Independent drop model ignoring a zero start left by expired-bucket translation: repaired in `BidModel.startAfter`. A hand-calculated regression establishes that price 1,000, full drop and 50% bucket floor restart at 1,000 and leave 500.

The final test snapshot additionally limits invariant 16's accepted `SpendCapReached` result to a refusal justified by the independently tracked snapshot, active spend, current cap and credit quote. The budget ghost checks successful enforced fills and a deterministic test requires both capped fills and exhausted-budget refusals. The independent idle ceiling uses `idleStepSeconds`, and the sale handler exercises `anchorMoveBps`.

## Material source conclusions

- Both direct sell overloads and listing purchases charge one ledger after booking fee income. Listing costs include the actual keeper payment. Every credit is checked, and a failed budget or minOut check reverts the entire transaction, including ownership, pile, rate and prior fills.
- The first successful fill snapshots the buying pot; normal later income cannot enlarge that snapshot. Bypass at 10,000 bps still counts outflow. Re-enabling enforcement retains it. Cap edits reprice the original snapshot; duration edits preserve active spend and bid-drop floors, with expiration evaluated using the old duration.
- Both balance conversions honor above-par caps. Their saturation threshold derives from the configured bid and multiplier caps; valid field widths and the module unit bound keep the arithmetic within uint256, including a huge reported available balance. The ETH purchase ledger does not account for balance-token purchases.
- Climb retains per-minute units. The new idle step controls ceiling loosening. Sniper activation remains one-way. Zero anchor movement returns without changing the clock, while partial/full movement uses the configured upward-gap fraction with integer rounding.
- Five Settings words move the ETH anchor to slot 28, the balance instance to slot 32, and the purchase ledger to slot 39. Solidity/web settings and event ABIs carry 34 fields. Owner settings fields, launch configuration, generated interfaces and build identities were traced through their consumers.
- Keeper outflow remains capped by both the credit bid and buying pot, and is included in the purchase cap. The library delegation and larger first-fill storage costs are addressed by the increased listing overhead; runtime gas adequacy is a coordinator test claim, not an independently measured claim in this report.

## Evidence and pending work

Direct reviewer execution: `node sim/engine.test.mjs` passed with 1,942 checks on the repaired simulator; `git diff --check` passed on the final snapshot. Early-review simulator counterexamples were executed before their repair. Source and test review used the exact immutable patches above. No Forge build, fork, whole suite, deep campaign, lifecycle, deployment or transaction was run by this reviewer.

Coordinator-reported evidence at report time: production build passed, with Core 24,038 bytes, CoreLib 20,579 bytes and ControllerV1 12,037 bytes. Repaired focused verification reported 53 passes across five files; the owned bounds verification reported 116 passes and one skip. Interfaces check, three web selfchecks, TypeScript checking and simulator 1,942 checks reported passing. These claims are not substitutes for the coordinator's saved command results. The bounded affected invariant gate was still running when this report was written, so its result is pending here.

The source snapshot's `docs/SPEC.md` still carries superseded funded-bid and at-par guarantees and old settings bounds. This was reported to the director for reconciliation against decisions 129/130, alongside the final STATUS update. INTEGRATION and RUNBOOK already describe the revised rules. Closing that document work and recording the pending focused invariant result remain coordinator tasks.

This is independent implementation review, not release acceptance. The full suite, deep campaigns, production release gate and lifecycle remain separate once-per-frozen-candidate work. Existing release evidence predates this change. No push, merge, deployment or mainnet authority is inferred.

## Limits

Budget and cumulative outflow use checked uint128 storage, so bypass does not promise successful accounting above uint128 max; the pot snapshot remains uint256. Simulator budget comparisons use BigInt, but the market trajectories remain documented Number approximations. No exact Solidity-versus-JavaScript differential simulation was performed. Runtime arithmetic conclusions assume valid contract/module field bounds and ordinary chain time, not artificially unbounded ETH supply or impossible timestamps.

## Final follow-up review

This section supersedes the earlier pending-document status and adds review of the repaired test models and browser simulator. Final follow-up identity: parent commit `1e8bb0f4cb340b31fa93505535edc9d86ee71aab` plus `/private/tmp/issue23-verified-model-review.patch`, SHA256 `d0a4240adcc004b43b631500da7e581f192af977395460292f5e00e4adad4342`. The reviewer reset its isolated clone to the parent and applied that complete patch. No implementation file was edited by the reviewer.

The director reconciled SPEC and STATUS in `6b95743`, including budget-dependent bid availability, configurable above-par balance bids, all new settings and widened bounds, and invalidation of old release evidence. The contradictory document claims reported above are closed. The final production changes after the prior source review are explanatory comments; the coordinator reports five BuildIdentity checks confirming unchanged runtime identities.

Normal-depth invariant execution exposed two additional test-model omissions. The final follow-up snapshot repairs them:

- The fixture now measures the buying pot before its real prefill purchases, sums their actual pot outflow and seeds the handler's independent purchase ledger. This preserves bypass-period spending when a later owner edit enables a cap in the same bucket, including the early launch-window fixture. It does not derive the expected values from Core budget storage.
- The handler independently replays each offered credit to justify a `ZeroAmount` result caused by a later integer-rounded payout at a tiny rate. Earlier pot insufficiency or enforced-budget exhaustion terminates that justification before an unreachable later zero. The replay updates only its memory input after a failed call; the caller does not use those fields afterward. A deterministic shrunk regression covers the original failing sequence.

The deterministic purchase-ghost test advances into a fresh bucket, requires a successful enforced fill, lowers the cap while retaining spend, raises the bid through the handler and requires an actual exhausted-budget refusal. The coordinator reports six deterministic regression passes across Phase1 and Window.

The reviewer also examined two bounded committed simulator deltas:

- `7b427b0`: first-hour execution honors finer integer steps. `stepVolume` splits each interval at the calibrated 120-second boundaries and multiplies each bin's volume by its overlap duration divided by 120. Refining the partition therefore conserves first-hour volume. The main loop keeps steps aligned to hours, rejects fractional/non-divisor steps, and distinguishes the fixed launch hook `skimSeconds` from the Core payee-latch `sniperSeconds`. Tests cover 1, 60 and 75 seconds, volume conservation, fractional rejection and latch independence.
- `1e8bb0f`: browser defaults derive from model/configuration defaults, all seven added economic controls and their owner schedules reach the model, the execution step is selectable, and widened numeric inputs are validated instead of silently forced to older slider ranges. The page and README state Number precision limits and the loss of spending opportunities with steps longer than budget buckets. The obsolete royalty control and chart row are removed.

The reviewer independently reconstructed the generated browser page from committed engine/UI files and the reviewed launch configuration. It matches `sim/index.html` byte for byte, SHA256 `1ce9ebc37694b3e61bd2dc20581546d1e782e5175cb1e97065e6267eb8df7df4`. Coordinator-reported engine verification is now 1,960 passing checks; the browser integration check passed, and the twelve bounded exposure results are unchanged. The reviewer did not repeat those already valid checks or claim a visual browser inspection.

The exact final source commit is `7d08b1ecb3e241906c0b3cefcd4bbc7e1a04ca69`. The reviewer fetched that commit and compared its source, script, simulator and test files against the reviewed snapshot. They match, including a separate byte comparison of the new, untracked-in-the-review-clone SpendCap test file. This closes the pending source identity claim.

Final coordinator-reported verification: all eight affected normal-depth invariant variants passed, 46 tests/groups, zero failures, 209.41 seconds, covering five invariants per variant and handler/regression checks. The final build passed; BuildIdentity passed all five tests; Flow passed 15 tests. These results close the earlier pending bounded invariant gate. They are coordinator-executed evidence, not tests rerun by the independent reviewer. Earlier failed model campaigns are superseded by this repaired source and final passing gate.

No unresolved production, simulator, owner-tooling or test-model finding was identified in this final follow-up source review. SPEC reconciliation, source identity and the bounded affected invariant gate are closed. Whole-suite/deep/release/lifecycle gates and owner deployment authority remain separate; no release acceptance is claimed.

## Exposure score deliverable addendum

Independently reviewed immutable commit `e7b02e490243820b862bd9866b9b41d1fe010b13`, limited to study output metadata, its saved twelve-row JSON and the exposure report. `runSpendCapStudy` now adds each successfully purchased credit's whole points before removing it from inventory, records that total at crossing and seller stop, and records the remaining inventory points. Engine rules and trajectory inputs are unchanged. No finding identified.

The reviewer ran cheap consistency checks against the committed artifacts: all twelve unique scenario/cap/start-offset rows conserve 500 credits and 221,600 whole points; stopped and final points-bought values agree; every crossing and recovery is null; stopped ETH spent plus remaining pot equals the opening pot within 1e-10 ETH. All twelve Markdown table rows match the saved JSON at displayed precision. The coordinator reports all twelve bounded runs passing. No Forge, broad simulation grid or release gate was repeated for this metadata-only delta.
