# rehearsal of docs/DEPLOY.md at the frozen candidate 97c1866 (branch tip 9ce8542)

- candidate: 97c1866fada6afe79c798e92cdc05fc40503a1f3. the clone is at the branch tip 9ce85423a074ae78393667497b7d8004d81e80ba (candidate plus 2c92931 `director: freeze candidate 97c1866` plus the preflight-script and docs fix), in /private/tmp/rehearsal-97c1866, submodules initialised, `out/` and `cache/` copied from the original worktree. `forge clean` was not run. `git status` stayed clean through every build and run, and `git checkout foundry.lock lib/solady` updated 0 paths
- chain: mainnet through https://ethereum-rpc.publicnode.com. latest block 26171749 for the preflight, Deploy, Resume, Postflight and Lock runs (the rehearsal test forked 26171754, timestamp 1791752339). https://gateway.tenderly.co/public/mainnet and https://mainnet.gateway.tenderly.co both answered and served the pin block 26158000
- config: `script/config/rehearsal.json` (placeholder image and description, by design)
- sent nothing. no `cast send`, no key, no ledger, no `.env` (none in the clone). variables were exported inline
- tooling: forge 1.8.1, jq 1.7.1

## live state read on the run

| item | value |
|---|---|
| owner 0xCB43...17F9 nonce | 3846 (latest and pending equal, unchanged since the rehearsal of 50cec6f) |
| owner balance | 126,387,510,785,373,739 wei = 0.126388 eth (same as the rehearsal of 50cec6f) |
| factory `minProtocolSkimShareBps` | 1000 (step 3 still open) |
| factory `deployFee()` | 0.069 eth |
| base fee | 58,413,575 wei = 0.0584 gwei (`cast gas-price`) |
| owner 7702 delegation, stack premise | held: every stack, code hash and owner row passed |

## result per step

| step | command (dry form) | result |
|---|---|---|
| 1 | `LAUNCH_CONFIG=script/config/rehearsal.json` | works. CONFIG_HASH 0x72c098c5ad8c4c289a5f0560ccc99b549b42101124ba108df68897bfc3d8e9c8 |
| 2 | `REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv` | PASS (8.6 s). numbers below |
| 3 | `setMinProtocolSkimShareBps(362)` | not sent (owner step). the rehearsal test applies it as the impersonated owner and passes afterwards |
| 4 | `script/Preflight.s.sol` with `--fork-block-number 26171749 --sender` the owner | exit 1 `ChecksFailed`, 116 rows, 113 pass (112 ok, 1 WARN), 3 FAIL. hash and nonce printed |
| 4b | `LAUNCH_CONFIG=script/config/rehearsal.json FORK_BLOCK=26171749 script/tools/check-preflight.sh script/config/rehearsal.json` | `ok: failed rows are exactly the expected ones` (placeholder row, the two factory rows). the balance row is compared and passes. details below |
| 5 | `Deploy.s.sol --sender $DEPLOYER` with `CONFIG_HASH`, `CONTROLLER_NONCE=3847` | runs its preflight (the same 113 of 116) and stops with `ChecksFailed(...)` naming the same 3 rows. no gas estimate is printed |
| 6 | `git checkout foundry.lock lib/solady`, then `python3 script/director.py check --gate deploy` at 9ce8542 | checkout works. the gate exits 1 with 32 WARN and 11 ERROR lines, see "director gate" |
| 7 | `Resume.s.sol --sender $DEPLOYER` with `CORE` = the predicted core | `CoreMismatch("no code at the core address, run Deploy instead")`, the correct refusal before the launch |
| 8 | etherscan verify | not run (nothing deployed) |
| 9 | `Postflight.s.sol` on the predicted core | `FAIL code: core ... code 0`, 1 of 2 checks. the full postflight pass is in the rehearsal test |
| 10 | `Lock.s.sol` (no `SEND`) | runs postflight first, `FAIL code: core`, 0 of 1 checks. the rehearsal test lock step passes |

## preflight rows (step 4, and the same table inside the Deploy dry run and the rehearsal test)

- 116 rows: 112 ok, 1 WARN (`warn: owner differs from creator`), 3 FAIL. 113 of 116 pass
- the 3 FAIL rows, all expected:
  1. `rule: image and description are filled and are not placeholders` (a value contains PLACEHOLDER)
  2. `factory: min protocol skim share leaves room for the bounty` (minProtocolSkimShareBps is 1000, above the 362 the bounty 9638 leaves)
  3. `factory: deployTokenAsOwner accepts the config (simulated)`, reverts `BountyBpsTooHigh(9638, 9000)` (0x55dd302a, 0x25a6, 0x2328)
- the owner balance row PASSES and is compared by `check-preflight.sh`: Preflight (step 4) `balance 126387510785373739 need 70121540640000000` (0.1264 eth against 0.0701 eth)
- six `build:` rows ok (Core 0x0d4b7801..., CoreLib 0xef0cafa2..., ControllerV1 0xefc7a0c1..., FeeRouter 0x72bc8fb8..., CoreLens 0xea2e6029..., CoreLib creation 0x204fce18...). three owner 7702 rows ok (code 0xef0100612373d7003d694220f7800eeaf8e3924c0951d3, Calibur hash 0xff0357b5..., keyCount 0). the stranger `deployToken` row ok (`Deprecated()`)
- after the owner command (rehearsal test): 115 of 116, the only failed row is the placeholder row
- predicted addresses (owner nonce 3846): library 0x85A210E6AEdC4d4F4d2296892bcF3E27EB7AC1d0 (create2, takes 3846), controller 0x78374d54104B8F534c70788A097aaa2749cC79aF (3847), router 0x7a3f3967cBB63E8d56e3f093069C62A25eebBda6 (3848), core 0xFeee6d2DC9F6901Ad38Eef20A9b73F539852137C (3849), coin 0x58515D262b821a08030db19EC956F5D335A4850C. CONTROLLER_NONCE=3847. the rehearsal test deploys the same router, controller, core and coin addresses. the library address differs from the 50cec6f rehearsal (0x78eC...1d52) because the CoreLib creation code changed (hash 0x204fce18...)

## postflight rows

- rehearsal test, after the launch: 96 of 96 pass, 1 WARN (`warn: coin fee recipients are not locked yet`)
- rehearsal test, after the lock step: 96 of 96 pass (`coin: fee recipients are locked` ok)
- standalone Postflight and Lock on the predicted core before any deploy: 1 of 2 and 0 of 1, `FAIL code: core` (no code), expected
- trading smoke: sold credit 1 for 8,900,000,000,000,000 wei

## Deploy dry run balance row

- Preflight (step 4): balance 126387510785373739 wei (0.1264 eth), need 70121540640000000
- Deploy dry run (step 5): balance 200256800247542164 wei (0.2003 eth), need 70325023584000000 (the block moved by one)
- the dry run reads the owner balance 0.0739 eth above the chain balance (50cec6f: +0.0810, c02435e: +0.0806). the dry run passes the row whatever the real balance is. cause still unknown

## gas per transaction (rehearsal test, execution plus intrinsic, calldata and code deposit)

| tx | gas |
|---|---|
| 1 library CoreLib (create2 deployer) | 3,922,892 |
| 2 controller | 1,683,764 |
| 3 router | 1,017,652 |
| 4 core | 4,104,823 |
| 5 lens | 1,907,367 |
| 6 launch through the factory (`deployTokenAsOwner`, value 0.069 eth) | 3,595,976 |
| 7 router `setEngine` | 80,542 |
| 8 router `setPayees` | 177,303 |
| 9 router `setSplitStart` (Resume) | 60,941 |
| total, nine transactions | 16,551,260 |

the nine figures sum to the printed total. per transaction cap 16,777,216 (largest: core, 4.10 million). `DEPLOY_GAS_ESTIMATE` 19,200,000 stays above the total. every figure and the total equal section 0 and the gas cap section of docs/DEPLOY.md (block 26171514 there, 26171754 here).

## owner funding

owner balance 0.126388 eth. the fee is 0.069 eth. margin is 20 percent over gas plus fee, as the runbook advises.

| base fee | gas cost | gas plus fee 0.069 | with 20 percent margin | balance minus need | balance minus need with margin |
|---|---|---|---|---|---|
| 1 gwei | 0.01655 eth | 0.08555 eth | 0.10266 eth | +0.04084 | +0.02373 |
| 5 gwei | 0.08276 eth | 0.15176 eth | 0.18211 eth | -0.02537 | -0.05572 |
| 20 gwei | 0.33103 eth | 0.40003 eth | 0.48003 eth | -0.27364 | -0.35364 |

- at the live base fee of 0.0584 gwei the measured gas costs 0.00097 eth and the need is 0.06997 eth. preflight's estimate (19,200,000 gas times the base fee plus the fee) is 0.0701 eth, and the balance covers it
- the balance covers the fee plus the measured gas up to a base fee of 3.47 gwei. above that the owner needs more eth. at 5 gwei the shortfall is 0.0254 eth (0.0557 eth with the margin)

## check-preflight.sh (new behaviour at 9ce8542: the balance row is compared unless IGNORE_BALANCE=1)

| run | result |
|---|---|
| latest block 26171749, `rehearsal.json`, no `IGNORE_BALANCE` | ok. 113 of 116, failed rows exactly the expected three. the balance row passes (owner funded), so nothing is expected for it |
| latest block, `IGNORE_BALANCE=1` | ok, same rows |
| default pin block 26158000, `rehearsal.json`, no `IGNORE_BALANCE` | FAILS. 112 of 116. got the three expected rows plus `deployer: balance covers the deploy fee and the gas`. the owner held 0.068 eth at the pin, below the need |
| default pin block 26158000, `IGNORE_BALANCE=1` | ok. 112 of 116, failed rows the placeholder row and the two factory rows |
| latest block, tracked `mainnet.json` (empty `image` and `description`) | fails by design: got the metadata row plus the two factory rows, expected only the two factory rows. CONFIG_HASH 0x2c6738da8e02be211e71a35eba4cea41e141bf470c4cd073e19a9ad562df9cf5 (not a launch value) |

so the script as committed does not pass in its default form (pin block, no env) because the pin block balance is below the need. the header comment of the script says the default expectation is the two factory rows "which fail on the pin block", and omits the balance row that also fails there. on launch day (owner funded, latest block) the default form passes with the real metadata filled and the factory rows open.

## director gate (`python3 script/director.py check --gate deploy` at 9ce8542)

exit 1. 32 WARN lines (evidence entries invalid by scope change or assumption change) and 11 ERROR lines (one more than at 50cec6f):

1. non-state files changed after candidate: docs/DEPLOY.md, docs/NEXT.md, script/tools/check-preflight.sh. NEW. the state file names candidate 97c1866 and `stateOnlyPaths` is `docs/HANDOFF.md`, `project/director-state.json`, `project/evidence.json`. commit 9ce8542 (after the freeze) changed three other files, so the gate fails at the tip until a new candidate is frozen or those changes are reverted
2. objective OBJ-LAUNCH-1 status is active, not complete
3. gate productRules has no evidence
4. gate independentReview has no evidence
5. gate deploymentRehearsal has no evidence
6. to 11. gates focusedTests (2 lines), localLifecycle (2 lines) and fullSuite (2 lines): evidence E-SUITE-CARRY-14c6306 and E-DEEP-CARRY-14c6306 invalid, scope changed after verification, depends on invalid E-TARGETED-14c6306

items 2 to 5 are the open items this rehearsal feeds. items 6 to 11 need evidence recorded for 97c1866 (the untracked docs/SUITE-97c1866.log and docs/DEEP-RUN-97c1866.log in the original worktree are not recorded in `project/evidence.json` at the tip). item 1 is outside what the previous report listed.

## runbook lines wrong or unclear, with the corrected text

1. step 6, gate sentence: add the rule that the tip may differ from the candidate only in `stateOnlyPaths`. corrected text: "run from the branch tip. the tip may differ from the candidate only in `docs/HANDOFF.md`, `project/director-state.json` and `project/evidence.json`; any other changed file (a runbook or script fix after the freeze) fails the gate with `non-state files changed after candidate` until a new candidate is frozen." as of 9ce8542 this error is live: docs/DEPLOY.md, docs/NEXT.md and script/tools/check-preflight.sh changed after 97c1866
2. step 4, `check-preflight.sh` sentences: the parenthetical after "`IGNORE_BALANCE=1` leaves that row out" attaches the expected-rows list to the wrong clause. corrected text: "`IGNORE_BALANCE=1` leaves the balance row out of the comparison on both sides. the expected failed rows are then the two factory rows of step 3, and with `script/config/rehearsal.json` also the metadata row, which fails by design while a value holds `PLACEHOLDER`. the balance row reads the owner balance at the fork block and fails only while the owner holds less than the need."
3. step 4 and the script header: the default run (pin block 26158000, no env) fails because the owner held 0.068 eth there, below the need, and the default `EXPECT_FAIL` omits the balance row. corrected text for the runbook: "at the default pin block the balance row fails (the owner held 0.068 eth); run the script with `FORK_BLOCK=<latest block>` (the owner is funded) or with `IGNORE_BALANCE=1`." corrected header of `script/tools/check-preflight.sh`: "EXPECT_FAIL default: the two factory rows of DEPLOY step 3 (and the metadata row for a config holding PLACEHOLDER). the balance row is compared; on the pin block it fails, so pass IGNORE_BALANCE=1 or a FORK_BLOCK after the owner was funded."
4. step 4, "the balance row of this step is the one to trust ... the `Deploy` dry run of step 5 reads the owner balance about 0.081 eth too high (rehearsal of 50cec6f at block 26171300: this step read 0.1264 eth, the dry run 0.2074 eth ...)": add the reading of this run. corrected text: "the dry run reads the owner balance 0.07 to 0.08 eth too high (50cec6f, block 26171300: step 4 read 0.1264 eth, the dry run 0.2074 eth; 97c1866, block 26171749: 0.1264 and 0.2003 eth, need 0.0701 eth in both)"
5. section 0, `the signer` row: add the reading "0.1264 eth at block 26171749, the rehearsal of 97c1866 (the need was 0.0701 eth at the base fee of 0.0584 gwei)". the balance has not changed since 26171300
6. section 0, `eth` row and the gas cap section: the figures are confirmed unchanged at candidate 97c1866 (block 26171754 here, 26171514 there). "after the rehearsal of 50cec6f with 16,656,912" stays correct. add the break-even: "the 0.1264 eth balance covers the fee plus the measured gas up to a base fee of 3.47 gwei"
7. step 5, recorded check: names "rehearsal of 50cec6f, block 26171308". this run reproduces its counts. corrected text: "rehearsal of 97c1866 at 9ce8542, block 26171749, placeholder config: preflight 113 of 116 before `setMinProtocolSkimShareBps(362)` (failed rows: the placeholder row and the two factory rows), 115 of 116 after it (failed row: the placeholder row), postflight 96 of 96 after the launch and after the lock; the Deploy dry run reads the owner balance 0.2003 eth against 0.1264 eth on chain"
8. step 4 and the "what the scripts do" table: the library row reads "0x85A2...1d0 not deployed" in Preflight and "on chain, the broadcast skips it and takes no deployer nonce" in the Deploy dry run, and the runbook says so. a reader can still take the dry run text as proof the library exists. add to the Deploy dry run text: "the dry run text does not mean the library is on mainnet; `cast code` of the library address is empty before step 6". the address in the runbook examples changes with every CoreLib change (0x85A2... at 97c1866, 0x78eC... at 50cec6f)
9. step 5 / Deploy dry run: the sentence "once every preflight row passes, forge prints 'Estimated amount required'" cannot be exercised before step 3 and a real `image`/`description`. the sentence already says the gas figures come from the rehearsal test while a row fails; no change needed

## launch day surprises

- the director gate fails at this tip for a reason that does not depend on evidence: docs/DEPLOY.md, docs/NEXT.md and script/tools/check-preflight.sh changed after the freeze. a post-freeze runbook or tool fix needs a new freeze commit, or the gate cannot print OK
- `check-preflight.sh` in its default form fails at the pin block (balance row), see above. the launch day form (latest block, funded owner, real metadata) is the one that can pass, and it needs the factory rows open (step 3) to match the expected rows
- the Deploy dry run still passes the balance row with a balance 0.074 eth above the chain balance. only the step 4 row reflects the real balance
- the owner has 0.1264 eth and sends transactions (nonce 3822 at the pin, 3835, 3846 now, unchanged since the last rehearsal). CONTROLLER_NONCE 3847 and every predicted address move with each owner transaction, so take both fresh from step 4 immediately before step 5 and again before step 6
- until the owner sets 362, the Deploy dry run stops at its own preflight and the broadcast would revert `BountyBpsTooHigh(9638, 9000)` in the launch transaction after the library, controller, router and core went out
- forge prints "Detected artifacts built from source files that no longer exist" (test/Window.t.sol, test/invariant/HandlerHouse.sol, test/audit/FloorRaiseRace.t.sol, ...) from the copied `out/`. harmless, `forge clean` was not run, the build rows pass
- the placeholder config and the filled config give different CONFIG_HASH values (0x72c098c5... for `rehearsal.json`, 0x2c6738da... for the tracked `mainnet.json` with empty metadata). the launch hash comes from the real file at step 4
