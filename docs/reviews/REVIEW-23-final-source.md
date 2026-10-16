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
