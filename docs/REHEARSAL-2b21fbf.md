# rehearsal of docs/DEPLOY.md at the frozen candidate 2b21fbf (branch tip fe73fd5)

- candidate: 2b21fbfed17f35786962f4e8f31366ae67e48233. clone `/private/tmp/cand-2b21fbf` at the tip fe73fd5 (candidate plus
  `director: freeze candidate 2b21fbf`), submodules initialised, `out/` and `cache/` copied from the original worktree
  (read only), `cache/fuzz/failures` and `cache/invariant/failures` emptied, `forge clean` not run. `git status` clean for
  every step of this part (run logs were kept outside the tree); `git checkout foundry.lock lib/solady` updated 0 paths
- chain: mainnet through https://ethereum-rpc.publicnode.com. latest block 26176197 for check-preflight, Preflight and the
  Deploy dry run (the Resume, Postflight and Lock dry forms ran at the latest block of each call); the rehearsal test forked
  26176201 (timestamp 1791805787)
- config: `LAUNCH_CONFIG=script/config/rehearsal.json` (placeholder image and description, by design)
- sent nothing. no `cast send`, no `--broadcast`, no key, no ledger, no `.env`. variables exported inline
- tooling: forge 1.8.1

## live state read on the run (block 26176197)

| item | value |
|---|---|
| owner 0xCB43...17F9 nonce | 3846 (latest and pending equal; unchanged since the rehearsal of cb7cb9d) |
| owner balance | 126,387,510,785,373,739 wei = 0.126388 eth (unchanged since block 26171300) |
| owner code | 0xef0100612373d7003d694220f7800eeaf8e3924c0951d3 (the pinned 7702 delegation) |
| factory `minProtocolSkimShareBps` | 1000 (step 3 still open) |
| factory `deployFee()` | 0.069 eth |
| base fee | 156,678,945 wei = 0.1567 gwei at the end of the run (preflight's need row used 0.150 gwei) |

## result per step

| step | command (dry form) | result |
|---|---|---|
| 1 | `LAUNCH_CONFIG=script/config/rehearsal.json` | works. CONFIG_HASH 0xc9a92044001de4817ce0acfd1e7c5f6c103ae8d7317b37b82c0f04e228806859 (equals the `0xc9a92044...` in DEPLOY.md step 4) |
| 2 | `LAUNCH_CONFIG=script/config/rehearsal.json MAINNET_RPC_URL=<publicnode> REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv` | PASS (8.6 s, gas 109,466,680). numbers below. the same test also passed inside the whole suite run (Tenderly rpc) |
| 3 | `setMinProtocolSkimShareBps(362)` | not sent (owner step). the rehearsal test applies it as the impersonated owner |
| 4 | `FORK_BLOCK=26176197 MAINNET_RPC_URL=<publicnode> script/tools/check-preflight.sh script/config/rehearsal.json` | `ok: git tree clean, HEAD fe73fd5 contains the frozen candidate 2b21fbf`, 113 of 116, CONFIG_HASH as step 1, CONTROLLER_NONCE=3847, `ok: failed rows are exactly the expected ones` (the placeholder row and the two factory rows). exit 0 |
| 4b | `Preflight.s.sol --fork-block-number 26176197 --sender` the owner | exit 1 `ChecksFailed`, 116 rows: 112 ok, 1 WARN, 3 FAIL. CONFIG_HASH as step 1, CONTROLLER_NONCE=3847 |
| 4c | check-preflight with the tracked `mainnet.json` (empty metadata) | fails by design: got the metadata row plus the two factory rows, expected the two factory rows. CONFIG_HASH 0x78648e0f0d15cd6a8e93569f848d3bf9e117ceefbf73545baf39f35802a3f5e3 (equals the `0x78648e0f...` in DEPLOY.md step 4) |
| 5 | `Deploy.s.sol --rpc-url <publicnode> --sender $DEPLOYER` with `CONFIG_HASH`, `CONTROLLER_NONCE=3847` | runs its preflight (113 of 116, the same 3 rows) and stops with `ChecksFailed("rule: image and description are filled and are not placeholders, factory: min protocol skim share leaves room for the bounty, factory: deployTokenAsOwner accepts the config (simulated)")`. no gas estimate printed |
| 6 | `git checkout foundry.lock lib/solady`, then `python3 script/director.py check --gate deploy` at fe73fd5 | checkout updates 0 paths. the gate exits 1 with 53 WARN and 11 ERROR lines, see "director gate" |
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
- balance row ok: `balance 126387510785373739 need 71880357945600000` (0.1264 eth against 0.0719 eth)
- six `build:` rows ok: Core 0xaf44690e..., CoreLib 0x5d31b8fb..., ControllerV1 0x8262813d..., FeeRouter 0x72bc8fb8...,
  CoreLens 0xea2e6029..., CoreLib creation 0x78fe9a74... (identical to the cb7cb9d values; the candidate changed no pinned
  contract bytes)
- owner rows ok: 7702 code, Calibur hash 0xff0357b5..., keyCount 0. `settings inside the bounds` ok (27 fields)
- predicted addresses (owner nonce 3846): library 0xd40a13980cf638F6eb95f396Ea808B79dAFC8F6D (create2, not deployed, takes
  3846), controller 0x78374d54104B8F534c70788A097aaa2749cC79aF (3847), router 0x7a3f3967cBB63E8d56e3f093069C62A25eebBda6,
  core 0xFeee6d2DC9F6901Ad38Eef20A9b73F539852137C, coin 0x58515D262b821a08030db19EC956F5D335A4850C. CONTROLLER_NONCE=3847.
  the rehearsal test deployed the same core, router and coin
- after the owner command (rehearsal test): 115 of 116, the only failed row is the placeholder row

## postflight rows

- rehearsal test, after the launch: 96 of 96 pass, 1 WARN (`warn: coin fee recipients are not locked yet`)
- rehearsal test, after the lock step: 96 of 96 pass
- standalone Postflight and Lock on the predicted core before any deploy: 1 of 2 and 0 of 1, `FAIL code: core` (no code),
  expected
- trading smoke: sold credit 1 for 8,900,000,000,000,000 wei

## Deploy dry run balance row

- Preflight (step 4b): 126,387,510,785,373,739 wei (0.1264 eth), need 71,880,357,945,600,000
- Deploy dry run (step 5): 291,522,482,155,990,431 wei (0.2915 eth), need 71,963,203,238,400,000
- the dry run reads 0.1651 eth above the chain balance (cb7cb9d: +0.0717, 97c1866: +0.0739, 50cec6f: +0.0810,
  c02435e: +0.0806). the gap grew and is no longer in the 0.07 to 0.08 eth range DEPLOY.md states. only the step 4 row
  reflects the real balance

## gas per transaction (rehearsal test, block 26176201, execution plus intrinsic, calldata and code deposit)

| tx | gas | change from DEPLOY.md |
|---|---|---|
| 1 library CoreLib (create2 deployer) | 4,398,657 | -74 |
| 2 controller | 1,696,100 | 0 |
| 3 router | 1,017,652 | 0 |
| 4 core | 4,152,512 | -4 |
| 5 lens | 1,918,834 | -73 |
| 6 launch through the factory (`deployTokenAsOwner`, value 0.069 eth) | 3,597,503 | -10 |
| 7 router `setEngine` | 80,542 | 0 |
| 8 router `setPayees` | 177,303 | 0 |
| 9 router `setSplitStart` (Resume) | 60,964 | -1 |
| total, nine transactions | 17,100,067 | -162 |

the nine figures sum to the printed total. per transaction cap 16,777,216; the largest transaction is the library
(4.40 million). `DEPLOY_GAS_ESTIMATE` 19,200,000 stays above the total by 2.1 million. the gas of the candidate equals
the cb7cb9d table to within 74 gas per transaction.

## owner funding (balance 0.126388 eth, fee 0.069 eth, margin 20 percent over gas plus fee)

| base fee | gas cost | gas plus fee | with 20 percent margin | balance minus need | balance minus need with margin |
|---|---|---|---|---|---|
| 1 gwei | 0.01710 eth | 0.08610 eth | 0.10332 eth | +0.04029 | +0.02307 |
| 5 gwei | 0.08550 eth | 0.15450 eth | 0.18540 eth | -0.02811 | -0.05901 |
| 20 gwei | 0.34200 eth | 0.41100 eth | 0.49320 eth | -0.28461 | -0.36681 |

- at the base fee of 0.1567 gwei the measured gas costs 0.00268 eth and the need is 0.07168 eth; the balance covers it
- the balance covers the fee plus the measured gas up to a base fee of 3.36 gwei (2.12 gwei with the 20 percent margin).
  above that the owner needs more eth. at 5 gwei the shortfall is 0.0281 eth (0.0590 eth with the margin)

## director gate (`python3 script/director.py check --gate deploy` at fe73fd5)

exit 1. 53 WARN lines. the 11 ERROR lines, verbatim (long scope lists are cut by the tool with `...`):

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
ERROR: gate independentReview: evidence E-REVIEW-CARRY-483be30 invalid: scope changed after verification: docs/ARCHITECTURE.md, docs/DEEP-RUN-cb7cb9d.log, docs/DEPLOY.md, docs/FLOW.md, docs/INTEGRATION.md, ...
ERROR: gate deploymentRehearsal: evidence E-REHEARSAL-CARRY-483be30 invalid: scope changed after verification: docs/DEPLOY.md, script/Checks.sol, script/LaunchConfig.sol, script/SetSettings.s.sol, script/SettingsFields.sol, ...; depends on invalid E-TARGETED-483be30
```

- no line `non-state files changed after candidate`: the tip-only rule holds at fe73fd5
- every evidence error is a carry from 483be30 invalidated by later scope; the gate holds no record for 2b21fbf yet (the
  suite, Deep run and this rehearsal are the records it needs)
- `E-REVIEW-CARRY-483be30` carries the kinds `analysis, review` and the gate accepts only `review`: a records defect
  independent of scope, still present
- the 11 lines are the same set as the cb7cb9d rehearsal except the scope list of the independentReview line, which now
  names `docs/DEEP-RUN-cb7cb9d.log`

## runbook lines wrong or unclear, with the corrected text

1. section 0, `eth` row (`docs/DEPLOY.md:54`) and the gas cap section (`docs/DEPLOY.md:230`): the gas figures and the block
   are from the cb7cb9d rehearsal. corrected text: "17,100,067 gas in total at block 26176201 (candidate 2b21fbf).
   library 4,398,657, controller 1,696,100, router 1,017,652, core 4,152,512, lens 1,918,834, launch 3,597,503,
   setEngine 80,542, setPayees 177,303, setSplitStart 60,964". line 230: "the sum is 17,100,067 over nine
   transactions, block 26176201". the 0.0861, 0.1545 and 0.4110 eth figures and the 3.36 gwei break-even are unchanged
2. section 0, `the signer` row (`docs/DEPLOY.md:53`): add "0.1264 eth at block 26176197, the rehearsal of 2b21fbf (the
   need was 0.0719 eth at the base fee of 0.150 gwei; nonce 3846, unchanged since 26171300)"
3. step 4 (`docs/DEPLOY.md:92`): "the Deploy dry run of step 5 reads the owner balance 0.07 to 0.08 eth too high". at
   2b21fbf the dry run read 0.2915 eth against 0.1264 eth, 0.165 eth too high. corrected text: "reads the owner balance
   0.07 to 0.17 eth too high" with the new data point "2b21fbf, block 26176197: 0.1264 and 0.2915 eth, need 0.0719
   eth"
4. step 5 (`docs/DEPLOY.md:93`), recorded check: names the rehearsal of cb7cb9d at 588d70f, block 26173858 and the dry
   run balance 0.1981 eth. corrected text: "recorded check (rehearsal of 2b21fbf at fe73fd5, block 26176197, placeholder
   config): ... the Deploy dry run reads the owner balance 0.2915 eth against 0.1264 eth on chain". the library
   address list gains nothing (0xd40a...8F6D is unchanged at 2b21fbf)
5. step 5 (`docs/DEPLOY.md:93`): the sentence on `CONTROLLER_NONCE` ("is right in both") appears once. no change
6. step 2: the predicted addresses printed inside the rehearsal test are still shifted by one nonce against the
   standalone preflight (in test: router 0x78374d54..., controller 0x93543E6c..., core 0x7a3f3967..., coin 0x30F9F8F7...;
   standalone and in the test after the deploy: router 0x7a3f3967..., controller 0x78374d54..., core 0xFeee6d2D...,
   coin 0x58515D26...). DEPLOY.md already carries a note about the shift (one match); it stays correct
7. DEPLOY.md hashes for step 4 (`0xc9a92044...` for rehearsal.json, `0x78648e0f...` for the tracked mainnet.json) equal
   the values measured in this run: no change
8. step 4 `check-preflight` on the tracked `mainnet.json` fails by design while `image` and `description` are empty (got the
   metadata row plus the two factory rows). unclear to a reader who runs it before step 1: say in step 4 that the
   launch run uses `local.json` with the real strings, the tracked file is expected to fail this script

## launch day surprises

- the Deploy dry run balance gap grew to +0.165 eth (was +0.072 at cb7cb9d); the dry run cannot be used to check funding
- until the owner sets 362 the broadcast would revert `BountyBpsTooHigh(9638, 9000)` in the launch transaction after the
  library, controller, router and core went out
- the director gate still fails on evidence only (no record for 2b21fbf) plus the `kind` defect of
  `E-REVIEW-CARRY-483be30`
- base fee moved from 0.0624 to 0.1567 gwei across this run; funding margin is unaffected at these levels
