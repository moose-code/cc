# rehearsal of docs/DEPLOY.md at the frozen candidate 50cec6f

- candidate: 50cec6fbdd93b048a2d619153af2d4bf91173b83 (clean clone of the worktree at /private/tmp/rehearsal-50cec6f, submodules init, `out/` and `cache/` copied read only from the original worktree). the director gate ran from the branch tip efd4656 (`director: freeze candidate 50cec6f`)
- chain: mainnet, latest block through https://ethereum-rpc.publicnode.com (blocks 26171299 to 26171312 across the runs). `Rehearsal.t.sol` forked block 26171308, timestamp 1791746963. the fallback https://gateway.tenderly.co/public/mainnet also answered (same head) and served the pin block 26158000 for the default `check-preflight.sh` run
- config: `script/config/rehearsal.json` (placeholder image and description, by design)
- nothing was broadcast. no `cast send`, no key, no ledger. the original worktree has no `.env`, so none was copied and none exists in the clone. env vars were exported inline (`MAINNET_RPC_URL`, `LAUNCH_CONFIG`, `DEPLOYER`, `CONFIG_HASH`, `CORE`)
- tooling: forge 1.8.1, jq 1.7.1. `git status` stayed clean through every build and run (the builds did not rewrite `foundry.lock` or `lib/solady` this time; `git checkout foundry.lock lib/solady` updated 0 paths)

## live state read on the run

| item | value |
|---|---|
| owner 0xCB43...17F9 nonce | 3846 (latest and pending equal; pin block 26158000: 3822; c02435e rehearsal: 3835) |
| owner balance | 0.126388 eth (doc step 0: 0.068 at the pin, 0.0163 at c02435e). the owner was funded since the last rehearsal |
| factory `minProtocolSkimShareBps` | 1000 (step 3 still open) |
| factory `deployFee()` | 0.069 eth |
| base fee | about 0.078 gwei (`cast gas-price` 78,169,161 wei) |
| private rpc https://rpc.mevblocker.io | `cast code $FACTORY` prints `0x60c060405260...`, `owner()` prints 0xCB43...17F9 |
| stack premise (`stack` equals `v2-mainnet.json`, nine code hashes) | held: every stack and code hash row passed |

## result per step

| step | command (dry form) | result |
|---|---|---|
| 0 | private rpc test | passes. prefix `0x60c0...` matches the doc's "0x60c0 on the live factory" |
| 1 | `LAUNCH_CONFIG=script/config/rehearsal.json` | works. CONFIG_HASH 0x2bdf8ccf69d771632ce326dde1f7b1f59a8a23f0cef75982760667e3afd3ade6 |
| 2 | `REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv` | PASS (7.3 s). numbers below |
| 3 | `setMinProtocolSkimShareBps(362)` | not sent (owner step). the rehearsal test applies it as the impersonated owner and passes afterwards |
| 4 | `script/Preflight.s.sol` (1,244 lines of output, the doc's grep prints the table) | exit 1 with `ChecksFailed`, 116 rows, 113 pass (112 ok, 1 WARN), 3 FAIL. hash and nonce printed |
| 4b | `script/tools/check-preflight.sh script/config/rehearsal.json` | see "check-preflight.sh" below |
| 5 | `Deploy.s.sol --sender $DEPLOYER` with `CONFIG_HASH`, `CONTROLLER_NONCE=3847` | runs its preflight, the same 113 of 116, stops with `ChecksFailed(...)` of the same 3 rows. no gas estimate is printed because the script stops before it |
| 6 | `git checkout foundry.lock lib/solady`, then `python3 script/director.py check --gate deploy` at efd4656 | checkout works. the gate exits 1, see "director gate" |
| 7 | `Resume.s.sol --sender $DEPLOYER` with `CORE` = the predicted core | `CoreMismatch("no code at the core address, run Deploy instead")`, the correct refusal before the launch |
| 8 | etherscan verify | not run (nothing deployed) |
| 9 | `Postflight.s.sol` on the predicted core | `FAIL code: core ... code 0`, 1 of 2 checks. the full postflight pass is in the rehearsal test |
| 10 | `Lock.s.sol` (no `SEND`) | runs postflight first, `FAIL code: core`, 0 of 1. the rehearsal test lock step passes |

## preflight rows (step 4, and the same table inside the Deploy dry run and the rehearsal test)

- 116 rows: 112 ok, 1 WARN (`warn: owner differs from creator`), 3 FAIL. 113 of 116 pass
- the 3 FAIL rows:
  1. `rule: image and description are filled and are not placeholders` (a value contains PLACEHOLDER). expected, placeholder config
  2. `factory: min protocol skim share leaves room for the bounty` (factory minProtocolSkimShareBps is 1000, above the 362). expected
  3. `factory: deployTokenAsOwner accepts the config (simulated)`, reverts `BountyBpsTooHigh(9638, 9000)` (0x55dd302a, 0x25a6, 0x2328). expected
- the owner balance row PASSES, not fails: `balance 126387510785373739 need 70433650924800000`. the owner holds 0.1264 eth and the need at the live base fee is 0.0704 eth. this is the one deviation from the expected failing rows (a finding, below)
- six `build:` rows ok (Core 0x27023254..., CoreLib 0x85ed1807..., ControllerV1 0x08dfd5f7..., FeeRouter 0x72bc8fb8..., CoreLens 0xea2e6029..., CoreLib creation 0x76b0eda2...), three owner 7702 rows ok (code 0xef0100612373d7003d694220f7800eeaf8e3924c0951d3, Calibur hash 0xff0357b5..., keyCount 0)
- after the owner command (rehearsal test): 115 of 116, the only failed row is the placeholder row
- predicted addresses (owner nonce 3846): library 0x78eC7c2Aa7f020AB61f97D4F2937FA795Ca31d52 (create2, takes 3846), controller 0x78374d54104B8F534c70788A097aaa2749cC79aF (3847), router 0x7a3f3967cBB63E8d56e3f093069C62A25eebBda6 (3848), core 0xFeee6d2DC9F6901Ad38Eef20A9b73F539852137C (3849), coin 0x58515D262b821a08030db19EC956F5D335A4850C. CONTROLLER_NONCE=3847. the rehearsal test deploys the same router, core and coin addresses as the script

## postflight rows

- rehearsal test, after the launch: 96 of 96 pass, 1 WARN (`warn: coin fee recipients are not locked yet`)
- rehearsal test, after the lock step: 96 of 96 pass
- trading smoke: sold credit 1 for 8,900,000,000,000,000 wei

## gas per transaction (rehearsal test, execution plus intrinsic, calldata and code deposit)

| tx | gas |
|---|---|
| 1 library CoreLib (create2 deployer) | 4,023,362 |
| 2 controller | 1,691,996 |
| 3 router | 1,017,652 |
| 4 core | 4,098,939 |
| 5 lens | 1,909,578 |
| 6 launch through the factory (`deployTokenAsOwner`, value 0.069 eth) | 3,596,291 |
| 7 router `setEngine` | 80,542 |
| 8 router `setPayees` | 177,303 |
| 9 router `setSplitStart` (Resume) | 61,249 |
| total, nine transactions | 16,656,912 |

per transaction cap 16,777,216 (largest tx: library, 4.02 million). `DEPLOY_GAS_ESTIMATE` 19,200,000 stays above the total. the sum of the nine figures equals the printed total.

## owner funding (the test's own table, fee included)

| base fee | gas cost | plus fee 0.069 | with 20 percent margin on the gas and fee |
|---|---|---|---|
| 1 gwei | 0.01665 eth | 0.08565 eth | about 0.1028 eth |
| 5 gwei | 0.08328 eth | 0.15228 eth | about 0.1827 eth |
| 20 gwei | 0.33313 eth | 0.40213 eth | about 0.4826 eth |

the live balance 0.1264 eth covers 1 gwei (0.0857) and the live 0.078 gwei base fee (preflight need 0.0704). it is short at 5 gwei by 0.026 eth (0.056 eth with the 20 percent margin).

## check-preflight.sh

- `FORK_BLOCK=<latest> script/tools/check-preflight.sh script/config/rehearsal.json`: fails with "failed rows differ from the expected ones". got: placeholder row, the two factory rows. expected: those plus `deployer: balance covers the deploy fee and the gas`. cause: the script hard codes the balance row as expected, and the owner is funded at the latest block. with `EXPECT_FAIL` set to the three rows it prints ok
- `FORK_BLOCK=<latest> script/tools/check-preflight.sh` (tracked `mainnet.json`, empty metadata): fails the same way. got: the image and description row plus the two factory rows. expected: the balance row plus the two factory rows. the empty metadata fails the metadata row by design, and the balance row passes
- defaults (pin block 26158000 through the Tenderly gateway, `rehearsal.json`): ok. 112 of 116, failed rows exactly the four expected (placeholder, balance, the two factory rows), CONFIG_HASH 0x2bdf8ccf..., CONTROLLER_NONCE 3822

## director gate (`python3 script/director.py check --gate deploy` at efd4656)

exit 1. 32 WARN lines (stale evidence entries listed as invalid by scope change) and 10 ERROR lines:

1. objective OBJ-LAUNCH-1 status is active, not complete
2. gate productRules has no evidence
3. gate independentReview has no evidence
4. gate deploymentRehearsal has no evidence
5. to 10. gates focusedTests, localLifecycle and fullSuite each: evidence E-SUITE-CARRY-14c6306 and E-DEEP-CARRY-14c6306 invalid, scope changed after verification (script/Checks.sol, script/LaunchConfig.sol, script/PostflightChecks.sol, script/PostflightV2.sol, script/SetSettings.s.sol, ...) and depends on invalid E-TARGETED-14c6306

the state file at efd4656 records candidate 50cec6f. items 1 to 4 are the expected open items (this rehearsal produces the deploymentRehearsal evidence). items 5 to 10 are outside what the c02435e report listed: three more gates (focusedTests, localLifecycle, fullSuite) have only carried evidence from candidate 14c6306, which the changes since then invalidated. they need evidence recorded for 50cec6f (the targeted tests, the local lifecycle and the full suite on the frozen candidate).

## runbook lines that are wrong or unclear, with the corrected text

1. section 0, `eth` row: the gas table is stale. replace "16,862,800 gas in total at block 26165132 (candidate c02435e). library 4,023,725, controller 989,225, router 1,017,652, core 4,716,981, lens 2,199,400, launch 3,597,013, setEngine 80,542, setPayees 177,303, setSplitStart 60,959" with "16,656,912 gas in total at block 26171308 (candidate 50cec6f). library 4,023,362, controller 1,691,996, router 1,017,652, core 4,098,939, lens 1,909,578, launch 3,596,291, setEngine 80,542, setPayees 177,303, setSplitStart 61,249". the eth figures change to "0.0857 eth at 1 gwei, 0.1523 at 5 gwei, 0.4021 at 20 gwei". the controller figure rose by 700,000 gas since c02435e (the sale controller of decision 68), the core and lens figures fell
2. section 0, `the signer` row: balance "0.068 eth at block 26158000 and 0.0163 eth at the rehearsal of c02435e" gets a third reading: "0.1264 eth at block 26171300 (rehearsal of 50cec6f)". with that balance the preflight balance row passes
3. section "mainnet gas cap per transaction": the deploy figures "library 4,668,226, controller 1,028,565, router 1,146,936, core 5,338,277, lens 2,528,828, launch 3,553,754, setEngine 80,586, setPayees 160,258, setSplitStart 60,892" are older than c02435e. use the table of item 1
4. step 4: the sentence naming the expected failures of `check-preflight.sh` ("the deployer balance and the two factory rows of step 3 on the pin block") needs "the balance row fails only while the owner holds less than the need. at a fork block after the owner was funded it passes and the script's default expectation fails; pass `EXPECT_FAIL` without the balance row". better, make the script read the balance row from the output and expect it only when the balance is below the need (script/tools/check-preflight.sh, `owner_rows`)
5. step 4 text "the balance row of this step is the one to trust: the Deploy dry run of step 5 reads a different balance and passes it" is confirmed again, with numbers: at block 26171300 Preflight (step 4) read balance 126387510785373739 wei (0.1264 eth) and the Deploy dry run read 207427478381606251 wei (0.2074 eth) with the same need (about 0.0704 eth). the Deploy dry run balance is 0.0810 eth above the chain balance (at c02435e: 0.0969 against 0.0163, +0.0806). keep the advice, and add the numbers: "the Deploy dry run reads the owner balance about 0.081 eth too high; only the step 4 row is real"
6. step 5, the recorded check ("rehearsal of c02435e ... 119 of 121 ... 121 of 121 preflight rows and 102 of 102 postflight rows"): replace with "rehearsal of 50cec6f, block 26171308, placeholder config: preflight 113 of 116 before `setMinProtocolSkimShareBps(362)` (failed rows: the placeholder row and the two factory rows), 115 of 116 after it (failed row: the placeholder row), postflight 96 of 96 after the launch and after the lock."
7. step 9: "95 rows on the fixture" is 96 in the rehearsal test (96 of 96 with the placeholder config, one WARN before the lock). correct to 96, or state which config the 95 refers to
8. step 5: "forge prints 'Estimated amount required'" cannot appear in the rehearsal while a preflight row fails, because Deploy stops at its own preflight. add: "while any preflight row fails the dry run ends with ChecksFailed and prints no estimate; the gas figures come from the rehearsal test"
9. step 7 (dry form): "the dry form of Resume, Postflight and Lock drops `--broadcast` and `--ledger` and takes `--sender $DEPLOYER`" is correct for Resume. Postflight and Lock take no `--sender` and ran without it. state "Resume takes `--sender $DEPLOYER`; Postflight and Lock need only the rpc"
10. step 6 gate sentence: add that the gate also lists invalid carried evidence for focusedTests, localLifecycle and fullSuite when the suite has not been re-recorded for the candidate
11. `script/Checks.sol:401` (code comment, not the runbook): "the deploy order is router, controller, Core ... the router takes the deployer nonce after the library, the controller the next" is wrong. the code and the runbook use controller (n), router (n+1), Core (n+2) after the library, as `_prePredictions` computes. the comment should read "controller, router, Core"

## launch day surprises

- the Deploy dry run balance anomaly of c02435e reproduced: the balance row passes with 0.2074 eth in the Deploy dry run while the chain holds 0.1264 eth (Preflight reads 0.1264). the cause is still not found. the dry run does not prove the owner is funded
- the library row text differs between commands. in Preflight (step 4) it reads "0x78eC...1d52 not deployed, the first transaction deploys it and takes one deployer nonce". in the Deploy dry run it reads "on chain, the broadcast skips it and takes no deployer nonce", because forge deploys the linked library in its simulation before `run`. `cast code 0x78eC7c2Aa7f020AB61f97D4F2937FA795Ca31d52` is empty on mainnet. an operator reading the dry run output could believe the library exists. the nonce arithmetic (CONTROLLER_NONCE = live nonce + 1 = 3847) is right in both
- the owner key is active: nonce 3822 (pin) to 3835 (c02435e) to 3846 (now), balance 0.068 to 0.0163 to 0.1264 eth. CONTROLLER_NONCE and every predicted address move with each owner transaction, so take both fresh from step 4 immediately before step 5 and again before step 6
- `check-preflight.sh` at a post-funding fork block reports a false mismatch on the balance row (see above). on launch day, with the owner funded, the expected failed rows at step 4 are the two factory rows only (plus the metadata row until the real strings are filled)
- the Deploy dry run cannot show a gas estimate or a postflight while the two factory rows fail. the first full pass of the Deploy script is the broadcast itself, after step 3
- `forge` prints "Detected artifacts built from source files that no longer exist" (test/Window.t.sol, test/invariant/HandlerHouse.sol, src/interfaces/AuctionHouse.sol, test/attackers/StatementBuyers.sol, test/audit/FloorRaiseRace.t.sol, test/ReviewFlowHouse.t.sol, ...) from the copied `out/`. harmless, `forge clean` was not run, the build rows passed
- the placeholder config and the filled config give different CONFIG_HASH values (and different predicted coins). the hash above is for `rehearsal.json` only. the launch hash comes from the real `mainnet.json` or `local.json` at step 4: `mainnet.json` with empty metadata gave CONFIG_HASH 0xdbef47d97e8751e95392c88c18e50dc1479fe05caba90e5c7daed5597cde3cad at nonce 3847 (not a launch value)
- step 3 is still open on chain (`minProtocolSkimShareBps` 1000). until the owner sets 362, preflight and the Deploy dry run stop on the two factory rows and the broadcast would revert `BountyBpsTooHigh(9638, 9000)` in the launch transaction after the library, controller, router and core had gone out
- the director gate will not print OK at the branch tip until the objective is closed and evidence exists for productRules, independentReview, deploymentRehearsal, focusedTests, localLifecycle and fullSuite
