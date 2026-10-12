# rehearsal of docs/DEPLOY.md at the frozen candidate cb7cb9d (branch tip 588d70f)

- candidate: cb7cb9d6c10382f2239b6c5acf622ee5298a68db. clone `/private/tmp/rev-cb7cb9d` at the tip 588d70f (candidate
  plus `director: freeze candidate cb7cb9d`), submodules initialised, `out/` and `cache/` copied from the original
  worktree, `forge clean` not run. `git status` was clean for every step of this part (the review PoC was removed first)
  and `git checkout foundry.lock lib/solady` updated 0 paths
- chain: mainnet through https://ethereum-rpc.publicnode.com. latest block 26173855 for preflight and check-preflight,
  26173858 for the Deploy dry run, the latest block at each run for Resume, Postflight and Lock; the rehearsal test forked
  26173861 (timestamp 1791777683)
- config: `LAUNCH_CONFIG=script/config/rehearsal.json` (placeholder image and description, by design)
- sent nothing. no `cast send`, no `--broadcast`, no key, no ledger, no `.env`. variables exported inline
- tooling: forge 1.8.1

## live state read on the run (block 26173855)

| item | value |
|---|---|
| owner 0xCB43...17F9 nonce | 3846 (latest and pending equal, unchanged since the rehearsal of 97c1866) |
| owner balance | 126,387,510,785,373,739 wei = 0.126388 eth (unchanged since block 26171300) |
| owner code | 0xef0100612373d7003d694220f7800eeaf8e3924c0951d3 (the pinned 7702 delegation) |
| factory `minProtocolSkimShareBps` | 1000 (step 3 still open) |
| factory `deployFee()` | 0.069 eth |
| base fee | 65,863,431 wei = 0.0659 gwei |

## result per step

| step | command (dry form) | result |
|---|---|---|
| 1 | `LAUNCH_CONFIG=script/config/rehearsal.json` | works. CONFIG_HASH 0xaa13cddf8293243e3572a8406222e7365b649c7757b17c805085d6fcf0f39988 |
| 2 | `LAUNCH_CONFIG=script/config/rehearsal.json MAINNET_RPC_URL=<publicnode> REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv` | PASS (7.6 s). numbers below |
| 3 | `setMinProtocolSkimShareBps(362)` | not sent (owner step). the rehearsal test applies it as the impersonated owner |
| 4 | `FORK_BLOCK=26173855 MAINNET_RPC_URL=<publicnode> script/tools/check-preflight.sh script/config/rehearsal.json` | `ok: git tree clean, HEAD 588d70f contains the frozen candidate cb7cb9d`, 113 of 116, `ok: failed rows are exactly the expected ones` (the placeholder row and the two factory rows). the balance row is compared and passes |
| 4b | `Preflight.s.sol --fork-block-number 26173855 --sender` the owner | exit 1 `ChecksFailed`, 116 rows: 112 ok, 1 WARN, 3 FAIL. CONFIG_HASH as step 1, CONTROLLER_NONCE=3847 |
| 4c | check-preflight with the tracked `mainnet.json` (empty metadata) | fails by design: got the metadata row plus the two factory rows, expected the two factory rows. CONFIG_HASH 0x3fb811ba0593f744a2867635ff7a2c625ff2bf1f5e7a08bd2b9cc7362e40f902 (not a launch value) |
| 5 | `Deploy.s.sol --rpc-url <publicnode> --sender $DEPLOYER` with `CONFIG_HASH`, `CONTROLLER_NONCE=3847` | runs its preflight (113 of 116, the same 3 rows) and stops with `ChecksFailed("rule: image and description are filled and are not placeholders, factory: min protocol skim share leaves room for the bounty, factory: deployTokenAsOwner accepts the config (simulated)")`. no gas estimate printed. the first line of output is `Error: Failed to decode return value: 0x2ef9eadf...` (the same revert, `ChecksFailed(string)`, printed before the traces) |
| 6 | `git checkout foundry.lock lib/solady`, then `python3 script/director.py check --gate deploy` at 588d70f | checkout updates 0 paths. the gate exits 1 with 53 WARN and 11 ERROR lines, see "director gate" |
| 7 | `Resume.s.sol --sender $DEPLOYER` with `CORE` = the predicted core 0xFeee...137C | `CoreMismatch("no code at the core address, run Deploy instead")`, the correct refusal before the launch |
| 8 | etherscan verify | not run (nothing deployed) |
| 9 | `Postflight.s.sol` with `CORE`, `DEPLOYER`, `CONFIG_HASH` | `FAIL code: core ... code 0`, 1 of 2 checks. the full postflight is in the rehearsal test |
| 10 | `Lock.s.sol` (no `SEND`) | runs postflight first, `FAIL code: core`, 0 of 1 checks. the rehearsal test lock step passes |

## preflight rows (step 4b; the same table inside the Deploy dry run and the rehearsal test)

- 116 rows: 112 ok, 1 WARN (`warn: owner differs from creator`), 3 FAIL. 113 of 116 pass
- the 3 FAIL rows, all expected:
  1. `rule: image and description are filled and are not placeholders` (a value contains placeholder)
  2. `factory: min protocol skim share leaves room for the bounty` (minProtocolSkimShareBps is 1000, above the 362 the
     bounty 9638 leaves)
  3. `factory: deployTokenAsOwner accepts the config (simulated)`, reverts `BountyBpsTooHigh(9638, 9000)`
     (0x55dd302a, 0x25a6, 0x2328)
- balance row ok: `balance 126387510785373739 need 70264577875200000` (0.1264 eth against 0.0703 eth)
- six `build:` rows ok: Core 0xaf44690e..., CoreLib 0x5d31b8fb..., ControllerV1 0x8262813d..., FeeRouter 0x72bc8fb8...,
  CoreLens 0xea2e6029..., CoreLib creation 0x78fe9a74... (each equals the constant in `script/Checks.sol` at cb7cb9d)
- three owner rows ok: 7702 code, Calibur hash 0xff0357b5..., keyCount 0. the stranger `deployToken` row ok
  (`Deprecated()`). `settings inside the bounds` ok (27 fields, `recoveryGapBps` 1000)
- predicted addresses (owner nonce 3846): library 0xd40a13980cf638F6eb95f396Ea808B79dAFC8F6D (create2, not deployed,
  takes 3846), controller 0x78374d54104B8F534c70788A097aaa2749cC79aF (3847), router
  0x7a3f3967cBB63E8d56e3f093069C62A25eebBda6, core 0xFeee6d2DC9F6901Ad38Eef20A9b73F539852137C, coin
  0x58515D262b821a08030db19EC956F5D335A4850C. CONTROLLER_NONCE=3847. the rehearsal test deployed the same core, router
  and coin
- after the owner command (rehearsal test): 115 of 116, the only failed row is the placeholder row

## postflight rows

- rehearsal test, after the launch: 96 of 96 pass, 1 WARN (`warn: coin fee recipients are not locked yet`)
- rehearsal test, after the lock step: 96 of 96 pass
- standalone Postflight and Lock on the predicted core before any deploy: 1 of 2 and 0 of 1, `FAIL code: core`
  (no code), expected
- trading smoke: sold credit 1 for 8,900,000,000,000,000 wei

## Deploy dry run balance row

- Preflight (step 4b): 126,387,510,785,373,739 wei (0.1264 eth), need 70,264,577,875,200,000
- Deploy dry run (step 5): 198,064,440,826,585,655 wei (0.1981 eth), need 70,286,180,083,200,000
- the dry run reads 0.0717 eth above the chain balance (97c1866: +0.0739, 50cec6f: +0.0810, c02435e: +0.0806). only the
  step 4 row reflects the real balance. cause still unknown

## gas per transaction (rehearsal test, execution plus intrinsic, calldata and code deposit)

| tx | gas | change from the runbook figure |
|---|---|---|
| 1 library CoreLib (create2 deployer) | 4,398,731 | +475,839 |
| 2 controller | 1,696,100 | +12,336 |
| 3 router | 1,017,652 | 0 |
| 4 core | 4,152,516 | +47,693 |
| 5 lens | 1,918,907 | +11,540 |
| 6 launch through the factory (`deployTokenAsOwner`, value 0.069 eth) | 3,597,513 | +1,537 |
| 7 router `setEngine` | 80,542 | 0 |
| 8 router `setPayees` | 177,303 | 0 |
| 9 router `setSplitStart` (Resume) | 60,965 | +24 |
| total, nine transactions | 17,100,229 | +548,969 |

the nine figures sum to the printed total. per transaction cap 16,777,216; the largest transaction is now the library
(4.40 million), above the core (4.15 million). `DEPLOY_GAS_ESTIMATE` 19,200,000 stays above the total by 2.1 million.
the runbook figures (16,551,260, library 3,922,892, core 4,104,823) are from block 26171514 and predate decision 74 and
this fix; CoreLib grew from 16,639 to 17,089 runtime bytes since 97c1866.

## owner funding (balance 0.126388 eth, fee 0.069 eth, margin 20 percent over gas plus fee)

| base fee | gas cost | gas plus fee | with 20 percent margin | balance minus need | balance minus need with margin |
|---|---|---|---|---|---|
| 1 gwei | 0.01710 eth | 0.08610 eth | 0.10332 eth | +0.04029 | +0.02307 |
| 5 gwei | 0.08550 eth | 0.15450 eth | 0.18540 eth | -0.02811 | -0.05901 |
| 20 gwei | 0.34200 eth | 0.41100 eth | 0.49321 eth | -0.28462 | -0.36682 |

- at the live base fee of 0.0659 gwei the measured gas costs 0.00113 eth and the need is 0.07013 eth. preflight's
  estimate (19,200,000 gas times the base fee plus the fee) is 0.07026 eth, and the balance covers it
- the balance covers the fee plus the measured gas up to a base fee of 3.36 gwei (2.12 gwei with the 20 percent margin).
  above that the owner needs more eth. at 5 gwei the shortfall is 0.0281 eth (0.0590 eth with the margin)

## director gate (`python3 script/director.py check --gate deploy` at 588d70f)

exit 1. 53 WARN lines. the 11 ERROR lines, verbatim:

```
ERROR: objective OBJ-LAUNCH-1 status is active, not complete
ERROR: gate independentReview: evidence E-REVIEW-CARRY-483be30 has kind analysis, review; gate accepts review
ERROR: gate productRules: evidence E-ACCEPT-0c3ecd2 invalid: scope changed after verification: script/LaunchConfig.sol, script/SetSettings.s.sol, script/SettingsFields.sol, script/config/mainnet.json, src/interfaces/Interfaces.sol, ...
ERROR: gate focusedTests: evidence E-SUITE-CARRY-483be30 invalid: scope changed after verification: script/Checks.sol, script/LaunchConfig.sol, script/SetSettings.s.sol, script/SettingsFields.sol, script/config/mainnet.json, ...; depends on invalid E-TARGETED-483be30
ERROR: gate focusedTests: evidence E-DEEP-CARRY-483be30 invalid: scope changed after verification: script/Checks.sol, script/LaunchConfig.sol, script/SetSettings.s.sol, script/SettingsFields.sol, src/Core.sol, ...; depends on invalid E-TARGETED-483be30
ERROR: gate localLifecycle: evidence E-SUITE-CARRY-483be30 invalid: scope changed after verification: script/Checks.sol, script/LaunchConfig.sol, script/SetSettings.s.sol, script/SettingsFields.sol, script/config/mainnet.json, ...; depends on invalid E-TARGETED-483be30
ERROR: gate localLifecycle: evidence E-DEEP-CARRY-483be30 invalid: scope changed after verification: script/Checks.sol, script/LaunchConfig.sol, script/SetSettings.s.sol, script/SettingsFields.sol, src/Core.sol, ...; depends on invalid E-TARGETED-483be30
ERROR: gate fullSuite: evidence E-SUITE-CARRY-483be30 invalid: scope changed after verification: script/Checks.sol, script/LaunchConfig.sol, script/SetSettings.s.sol, script/SettingsFields.sol, script/config/mainnet.json, ...; depends on invalid E-TARGETED-483be30
ERROR: gate fullSuite: evidence E-DEEP-CARRY-483be30 invalid: scope changed after verification: script/Checks.sol, script/LaunchConfig.sol, script/SetSettings.s.sol, script/SettingsFields.sol, src/Core.sol, ...; depends on invalid E-TARGETED-483be30
ERROR: gate independentReview: evidence E-REVIEW-CARRY-483be30 invalid: scope changed after verification: docs/ARCHITECTURE.md, docs/DEPLOY.md, docs/FLOW.md, docs/INTEGRATION.md, docs/NEXT.md, ...
ERROR: gate deploymentRehearsal: evidence E-REHEARSAL-CARRY-483be30 invalid: scope changed after verification: docs/DEPLOY.md, script/Checks.sol, script/LaunchConfig.sol, script/SetSettings.s.sol, script/SettingsFields.sol, ...; depends on invalid E-TARGETED-483be30
```

the tip-only rule holds at 588d70f: the gate prints no `non-state files changed after candidate`. every evidence error is
a carry from 483be30 invalidated by the cb7cb9d scope; the suite, the Deep run, this review and this rehearsal are the
records cb7cb9d needs. the second line is a records defect independent of scope: `E-REVIEW-CARRY-483be30` carries the
kinds `analysis, review` and the gate accepts only `review`.

## runbook lines wrong or unclear, with the corrected text

1. section 0, `eth` row (`docs/DEPLOY.md:54`): the gas figures are from block 26171514. corrected text: "measured by the
   rehearsal (`REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv`): 17,100,229 gas in total at block 26173861
   (candidate cb7cb9d). library 4,398,731, controller 1,696,100, router 1,017,652, core 4,152,516, lens 1,918,907,
   launch 3,597,513, setEngine 80,542, setPayees 177,303, setSplitStart 60,965. with the fee that is 0.0861 eth at
   1 gwei, 0.1545 at 5 gwei, 0.4110 at 20 gwei. ... the 0.1264 eth balance covers the fee plus the measured gas up to a
   base fee of 3.36 gwei". delete "the figures are unchanged at candidate 97c1866"
2. section 0, `the signer` row (`docs/DEPLOY.md:53`): add "0.1264 eth at block 26173855, the rehearsal of cb7cb9d (the
   need was 0.0703 eth at the base fee of 0.0659 gwei; nonce 3846, unchanged since 26171300)"
3. gas cap section (`docs/DEPLOY.md:230`): "(the largest is the core at 4.10 million, the sum is 16,551,260 over nine
   transactions)". corrected text: "library 4,398,731, controller 1,696,100, router 1,017,652, core 4,152,516, lens
   1,918,907, launch 3,597,513, setEngine 80,542, setPayees 177,303, setSplitStart 60,965 (the largest is the library at
   4.40 million, the sum is 17,100,229 over nine transactions, block 26173861)"
4. step 1 (`docs/DEPLOY.md:89`) and step 4 (`docs/DEPLOY.md:92`): the metadata rule names only `ipfs://`, `https://`
   and `ar://`. the rule at cb7cb9d (`script/Checks.sol:358-362`) also accepts `data:`, matches the scheme in any letter
   case and after leading whitespace. corrected text for both: "or while `image`, trimmed, does not start with
   `ipfs://`, `https://`, `ar://` or `data:` (any letter case) followed by content. the value goes on chain exactly as
   written, so write the scheme in lower case with no leading whitespace" (see I3 of REVIEW-cb7cb9d.md)
5. step 4 (`docs/DEPLOY.md:92`): "rehearsal.json 0x72c098c5..., the tracked mainnet.json with empty metadata
   0x2c6738da...". corrected text: "rehearsal.json 0xaa13cddf..., the tracked mainnet.json with empty metadata
   0x3fb811ba... (candidate cb7cb9d; every settings change moves both)"
6. step 5 (`docs/DEPLOY.md:93`): the sentence "`CONTROLLER_NONCE` (the live owner nonce plus 1) is right in both" is
   written twice in a row. delete the second copy. the library address example "0x85A2...1d0 at 97c1866, 0x78eC...1d52
   at 50cec6f" gains "0xd40a...8F6D at cb7cb9d"
7. step 5, recorded check: names the rehearsal of 97c1866. corrected text: "recorded check (rehearsal of cb7cb9d at
   588d70f, block 26173858, placeholder config): preflight 113 of 116 before `setMinProtocolSkimShareBps(362)`, 115 of
   116 after it, postflight 96 of 96 after the launch and after the lock; the Deploy dry run reads the owner balance
   0.1981 eth against 0.1264 eth on chain"
8. step 5: the dry run prints `Error: Failed to decode return value: 0x2ef9eadf...` as its first line, before the traces,
   and the readable `Error: script failed: ChecksFailed(...)` at the end. add: "a first line `Failed to decode return
   value: 0x2ef9eadf...` is the same `ChecksFailed` revert; read the table and the last line"
9. step 2: the rehearsal test's own preflight prints predicted addresses one owner nonce lower than the deploy it then
   runs (in test: controller 0x93543E6c..., router 0x78374d54..., core 0x7a3f3967..., coin 0x30F9F8F7...; deployed: core
   0xFeee6d2D..., router 0x7a3f3967..., coin 0x58515D26..., equal to the standalone step 4 prediction). in the test the
   library is linked by forge (0x5615dEB7...), so its preflight row reads "on chain, takes no deployer nonce". the
   `predicted ... is empty` rows of the in-test preflight check the wrong addresses. add to step 2: "the predicted
   addresses printed inside the rehearsal test are shifted by one nonce; the addresses to compare are the ones step 4
   prints and the `core`, `router` and `coin` lines the test prints after the deploy"

## launch day surprises

- the deploy needs 548,969 more gas than the runbook says, and the break-even base fee for the 0.1264 eth balance fell
  from 3.47 to 3.36 gwei. at 5 gwei the owner is 0.028 eth short (0.059 eth with the margin)
- the director gate fails at this tip on evidence only (no record yet for cb7cb9d), plus the `kind` defect of
  `E-REVIEW-CARRY-483be30`
- the Deploy dry run still passes the balance row with a balance 0.072 eth above the chain balance. only the step 4 row
  reflects the real balance
- CONFIG_HASH moved with the settings change (rehearsal.json 0xaa13cddf..., tracked mainnet.json 0x3fb811ba...). the
  launch hash comes from the real file at step 4
- until the owner sets 362 the broadcast would revert `BountyBpsTooHigh(9638, 9000)` in the launch transaction after the
  library, controller, router and core went out
