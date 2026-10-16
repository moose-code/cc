# Issue 23 implementation evidence

## Identity and scope

Branch: `codex/issue-23-spend-cap`, based on merged PR 21 at `3a9491e424c209e08f757c602739ce36f0119e47`. Authority: owner approval recorded as decisions 129/130. Core implementation commit: `7d08b1ecb3e241906c0b3cefcd4bbc7e1a04ca69`. Independent review is `REVIEW-23-final-source.md`, including its exact reviewed patch identities and followup commits.

Implementation covers shared ETH purchase accounting, preserved spending across owner edits, configurable clocks/caps/anchor movement, the complete widened-bound inventory, arithmetic and zero-floor repairs, ABI/config/storage/build consumers, owner CLI, web quote/error consumers, simulator and generated browser page. The Core budget is bypassed at 10,000 bps while recording outflow. Cap edits immediately reprice the original opening-pot snapshot. A duration edit expires using the old duration before translating active state. Keeper payment is included; balance-token purchases are excluded.

Settings has 34 fields in five packed slots. The ETH anchor starts at slot 28, balance rate at 32, and appended Spend at 39 through 41. Spend contains a uint64 bucket, initialization flag, uint128 budget and cumulative outflow, and uint256 opening-pot snapshot. Checked uint128 narrowing rejects impossible-domain accounting instead of truncating. Exact bounds/defaults are maintained in SPEC section 3 and RUNBOOK section 4.

## Environment and method

Foundry 1.8.1, solc 0.8.30, default project build with enforced via-IR production artifacts (optimizer 200, Cancun, no metadata hash). This was not a production release-profile gate. Runtime bytes measured from `out/<name>.sol/<name>.json`:

| Contract | Runtime bytes | EIP-170 headroom |
|---|---:|---:|
| Core | 24,038 | 538 |
| CoreLib | 20,579 | 3,997 |
| ControllerV1 | 12,037 | 12,539 |

A task-owned Anvil on port 8600 forked mainnet block 26,158,000 and loaded the checked-in master-stack overlay, whose head is 26,158,028. Fork tests therefore used `STACK=master MAINNET_RPC_URL=http://127.0.0.1:8600 FORK_BLOCK=26158028` and `--chain-id 1`. This is a synthetic deployment fixture over a pinned mainnet fork, not a claim that the master stack is deployed on mainnet. The owner's node on 8545 was not changed. No secrets or deployment records are committed.

## Focused checks

- `forge build`: passed on the combined code, then again with the final model repairs. Final log `/tmp/issue23-complete-build.log`.
- Affected unit files: BalanceBid, BalanceFloor, BidRule, CoreLayout, CreditSale, FeeShare, BuildIdentity, GasCap, PostflightSlots, Recovery, ReviewDeploy, ReviewMatrix, SetSettings and SpendCap. Final combined evidence is 128 unique passing tests, assembled from the initial affected-file run and a repair run of the five failing/changed consumers. Initial run had six failures; those were repaired and all 53 tests in the repair group passed. Commands below. Logs `/tmp/issue23-final-focused.log` and `/tmp/issue23-repaired-focused.log`.
- Config/CoreUnit/Flow/Sale packet: 116 passed, one skipped. Config and CoreUnit were rechecked against the repaired gas, identity and postflight inputs, including capped and bypassed keeper reimbursement. Controller/Sale runtime is unchanged since its passing packet. Flow was additionally rerun on the final parent implementation: 15 passed. Worker receipts: `/private/tmp/cc-issue23-bounds-repair-tests.log`, `/private/tmp/cc-issue23-bounds-final-build.log`; parent Flow log `/tmp/issue23-final-flow.log`.
- `forge test --match-path test/ScriptLint.t.sol -vv`: one passed. Final BuildIdentity rerun: five passed, confirming compiled byte identities and linked artifacts after source comment cleanup.
- The deterministic low-rate and purchase-budget ghost regressions passed in both phase-one start states: six passed. They cover a one-wei rate whose later batch payout rounds to zero, inherited prefill spending and a nonvacuous enforced fill plus exhausted-budget refusal.
- Affected normal-depth invariant result: eight variants passed, 46 tests/groups, zero failures, 209.41 seconds. The five checked invariants are rate model (06), expected refusals (11), qualified bid liveness (16), rate bounds (19) and independent purchase-budget accounting (20). Handler success/max-seed checks are included. No Deep variant ran.
- `script/tools/gen-interfaces.sh --check`: passed. Generated ABIs match all five production interfaces.
- `npm --prefix web run check`: all three selfchecks passed; TypeScript `--noEmit --incremental false --project web/tsconfig.json` passed. Includes width-safe BigInt cases, new tuple/event/error decoding, storage offsets and configurable quote math.
- `node sim/engine.test.mjs`: 1,960 checks passed. `node sim/page.ui.test.js`: control mapping, validation, one-day simulation and generated-script compilation passed; the one-day sample took about 108 ms in that run. Syntax checks passed. This is not a browser painting or long-horizon latency measurement.
- `node sim/market.mjs --spendcap`: twelve bounded scenarios passed. Their price/spend/count trajectories are unchanged after the final repairs; final machine-readable output is saved in `EXPOSURE-129-spendcap.json` with the requested whole-point totals. The 221,600-point inventory is conserved in all twelve rows. Assumptions and modeled results are in `REVIEW-129-spendcap.md`. The historical 108-case grid was not run.
- `git diff --check`: passed.

Reproduction commands for the verified unit file groups (each with the fork environment above):

```sh
forge test --chain-id 1 --match-path 'test/{SpendCap,BalanceBid,CoreLayout,SetSettings,FeeShare,GasCap,BuildIdentity,PostflightSlots,ReviewDeploy,ReviewMatrix,BidRule,BalanceFloor,Recovery,CreditSale}.t.sol' -j 1 -vv
forge test --chain-id 1 --match-path 'test/{PostflightSlots,ReviewDeploy,ReviewMatrix,SpendCap,BidRule}.t.sol' -j 1 -vv
forge test --chain-id 1 --skip script --match-path 'test/{Config,CoreUnit}.t.sol' -j 1 -vv
forge test --chain-id 1 --match-path 'test/{Sale,Flow}.t.sol' -j 1 -vv
forge test --chain-id 1 --match-path test/Flow.t.sol -j 1 -vv
forge test --chain-id 1 --match-path test/BuildIdentity.t.sol -j 1 -vv
```

Affected invariant command:

```sh
forge test --chain-id 1 --match-path 'test/invariant/{Invariants,InvariantsPhase2,InvariantsSale}.t.sol' --no-match-contract '.*Deep' --match-test 'invariant_(06|11|16|19|20)|test_purchaseBudgetGhostIsNotVacuous|test_lowRateBatchZeroRefusalMatchesModel|test_.*(EverySucceed|SurviveMaxSeeds|everyActionSucceeds|theBidCheckFindsASeller)' -j 1 -vv
```

## Findings repaired during implementation

Keeper metering omitted the larger post-meter first-bucket storage work; listing overhead is now 350,000 gas, with final capped and bypassed reimbursement tests. The owner CLI had an obsolete manual tuple, destructive preview state and setter-order dependencies; it now carries 34 fields, caches changes, restores its exact batch preview and chooses a valid Core/controller order. Deployment consumers were updated for nine Core immutables and ten linked library sites.

Independent review found simulator drop anchors lost across duration edits and listing tips missing the remaining-pot clamp. Both are repaired. Independent test ghosts were corrected for above-par balance caps, keeper pot room, cleared drop anchors, configurable idle steps, inherited prefill spending and reachable zero-rounded batch payouts. Liveness only accepts budget refusal when its independent ledger justifies it. Earlier failing campaigns were stopped and their concrete cases became deterministic regressions before rerunning.

The generated simulator browser copy was stale. Its current bundle derives defaults from the launch config and exposes every new setting. Finer simulation steps now apply from launch and prorate calibrated 120-second volume bins, preserving first-hour volume. The Core payee timer is independent of the immutable hook skim window. Independent review reconstructed the bundle byte for byte.

## Economic result and completion boundary

At the approved 100 bps default, the bounded flat-market model bought 343 of 500 credits over six hours and left 157 unsold; its reference bid did not cross below the assumed 0.005 ETH market. A cap limits aggregate outflow but can prevent enough fills to lower the bid, while idle climbing continues. This is a disclosed limitation of the approved rule. The default remains 100 bps. Market trajectories use JavaScript Number approximations; exact BigInt vectors and Solidity boundary tests do not establish a full cross-runtime differential proof.

Implementation completion requires the focused checks and independent review above. Release acceptance remains open: freeze the exact candidate and run the configured full suite, deep campaigns, production release build and local lifecycle/rehearsal once with `CANDIDATE_RUN=1`. Historical freeze results do not accept this change. No push, merge, deployment or external transaction was performed.

## Focused commit ledger

- `ce1bae7`: owner decisions 129/130 and active scope.
- `a412547`: web ABI, quote and cap error consumers.
- `2e8330c`, `7dcd4af`: simulator budget/exposure implementation and reviewed duration/payment repairs.
- `936fed9`: widened-bound and controller movement tests.
- `3a0670d`, `6b95743`: operating docs and reconciled product intent.
- `7b427b0`, `1e8bb0f`: simulator timing/volume repair and current browser bundle.
- `7d08b1e`: verified contracts, scripts, configuration, interfaces and parent test/model repairs.
- `72e5688`, `026f0bd`, `ac46371`: immutable independent reviews and closure.
- `e7b02e4`: requested exposure point totals and saved twelve-row JSON.

The task-owned Anvil on port 8600 was stopped after verification. The owner's 8545 node was not modified. Temporary web dependency linkage was removed; toolchain lock and tracked dependency pins are unchanged. No unrelated dirty work was present at task start or included in these commits.
