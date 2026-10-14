# rehearsal of docs/RUNBOOK.md at the frozen candidate 267139b (branch tip 55a44ad)

- candidate: 267139b. clone `/private/tmp/cand-267139b` at the tip 55a44ad (candidate plus `director: freeze candidate 267139b`), submodules initialised, `out/` and `cache/` copied from the original worktree (read only), `cache/fuzz/failures`, `cache/invariant/failures` and `cache/test-failures` removed, `forge clean` not run. `git status` clean for check-preflight and the director gate (run logs kept outside the tree during those steps); `git checkout foundry.lock lib/solady` updated 0 paths
- chain: mainnet through https://ethereum-rpc.publicnode.com. rehearsal test forked block 26176766 (timestamp 1791812591). check-preflight at 26176937. Preflight, Deploy, Resume, Postflight and Lock dry forms at the latest block of each call (about 26176941)
- config: `LAUNCH_CONFIG=script/config/rehearsal.json` (placeholder image and description, by design)
- sent nothing: no `cast send`, no `--broadcast`, no key, no ledger, no `.env`
- tooling: forge 1.8.1

## live state read on the run

| item | value |
|---|---|
| owner 0xCB43...17F9 nonce | 3846 (latest) |
| owner balance | 126,387,510,785,373,739 wei = 0.126388 eth (unchanged since block 26171300) |
| factory `minProtocolSkimShareBps` | 1000 (step 3 open) |
| factory `deployFee()` | 0.069 eth |
| CoreLib 0xd40a...8F6D | no code on chain |
| base fee | 0.4724 gwei at block 26176941 (484,060,604 wei a few blocks later); preflight need row used about 0.455 gwei |

## result per step

| step | command (dry form) | result |
|---|---|---|
| 1 | `LAUNCH_CONFIG=script/config/rehearsal.json` | works. CONFIG_HASH 0xaa13cddf8293243e3572a8406222e7365b649c7757b17c805085d6fcf0f39988 (RUNBOOK.md step 4 still lists 0xc9a92044..., see wrong lines) |
| 2 | `CANDIDATE_RUN=1 REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv` (publicnode) | PASS (7.29 s, gas 109,471,584). the same test passed inside the whole suite run (Tenderly rpc) |
| 3 | `setMinProtocolSkimShareBps(362)` | not sent. the rehearsal test applies it as the impersonated owner |
| 4 | `FORK_BLOCK=26176937 script/tools/check-preflight.sh script/config/rehearsal.json` | `ok: git tree clean, HEAD 55a44ad contains the frozen candidate 267139b`, 113 of 116, CONFIG_HASH as step 1, CONTROLLER_NONCE=3847, `ok: failed rows are exactly the expected ones` (the placeholder row and the two factory rows). exit 0 |
| 4b | `Preflight.s.sol --sender` the owner, latest block | exit 1 `ChecksFailed`, 116 rows: 112 ok, 1 WARN, 3 FAIL, 113 of 116. CONFIG_HASH as step 1, CONTROLLER_NONCE=3847 |
| 4c | check-preflight with the tracked `mainnet.json` | exit 1 by design: got the metadata row plus the two factory rows, expected the two factory rows. CONFIG_HASH 0x3fb811ba0593f744a2867635ff7a2c625ff2bf1f5e7a08bd2b9cc7362e40f902, CONTROLLER_NONCE=3847 |
| 5 | `Deploy.s.sol --rpc-url <publicnode> --sender $DEPLOYER` with `CONFIG_HASH`, `CONTROLLER_NONCE=3847` | preflight inside it: 113 of 116, the same 3 rows. exit 1 `ChecksFailed("rule: image and description are filled and are not placeholders, factory: min protocol skim share leaves room for the bounty, factory: deployTokenAsOwner accepts the config (simulated)")`. no gas estimate printed |
| 6 | `git checkout foundry.lock lib/solady`, `python3 script/director.py check --gate deploy` at 55a44ad | checkout updates 0 paths. gate exit 1: 53 WARN, 11 ERROR, see "director gate" |
| 7 | `Resume.s.sol --sender $DEPLOYER` with `CORE` = predicted core 0xFeee6d2DC9F6901Ad38Eef20A9b73F539852137C | exit 1 `CoreMismatch("no code at the core address, run Deploy instead")`, the correct refusal before the launch |
| 8 | etherscan verify | not run (nothing deployed) |
| 9 | `Postflight.s.sol` with `CORE`, `DEPLOYER`, `CONFIG_HASH` | exit 1 `ChecksFailed("code: core")`, `FAIL code: core ... code 0`, 1 of 2 checks. the full postflight is in the rehearsal test |
| 10 | `Lock.s.sol` (no `SEND`) | exit 1, runs postflight first, `FAIL code: core`, 0 of 1 checks. the rehearsal test lock step passes |

## preflight rows (step 4b; the same table inside the Deploy dry run and the rehearsal test)

- 116 rows: 112 ok, 1 WARN (`warn: owner differs from creator`), 3 FAIL, 113 of 116 pass
- the 3 FAIL rows, all expected:
  1. `rule: image and description are filled and are not placeholders`
  2. `factory: min protocol skim share leaves room for the bounty` (minProtocolSkimShareBps is 1000, above the 362 the bounty 9638 leaves)
  3. `factory: deployTokenAsOwner accepts the config (simulated)`, reverts 0x55dd302a with 0x25a6 (9638) as first argument (BountyBpsTooHigh)
- balance row ok: `balance 126387510785373739 need 77736137529600000` (0.1264 eth against 0.0777 eth)
- six `build:` rows ok: Core 0xaf44690e..., CoreLib 0x5d31b8fb..., ControllerV1 0x8262813d..., FeeRouter 0x72bc8fb8..., CoreLens 0xea2e6029..., CoreLib creation 0x78fe9a74... (identical to the 2b21fbf values)
- owner rows ok: 7702 code, Calibur hash 0xff0357b5..., keyCount 0
- predicted addresses (standalone, owner nonce 3846 as the library takes it): library 0xd40a13980cf638F6eb95f396Ea808B79dAFC8F6D, controller 0x78374d54104B8F534c70788A097aaa2749cC79aF, router 0x7a3f3967cBB63E8d56e3f093069C62A25eebBda6, core 0xFeee6d2DC9F6901Ad38Eef20A9b73F539852137C, coin 0x58515D262b821a08030db19EC956F5D335A4850C (the rehearsal test deployed the same core, router and coin). CONTROLLER_NONCE=3847
- rehearsal test after the owner command: 115 of 116, only the placeholder row fails

## postflight rows

- rehearsal test, after the launch: 96 of 96 pass, 1 WARN (`warn: coin fee recipients are not locked yet`)
- rehearsal test, after the lock step: 96 of 96 pass
- standalone Postflight and Lock before any deploy: 1 of 2 and 0 of 1, `FAIL code: core` (no code), expected
- trading smoke: sold credit 1 for 8,900,000,000,000,000 wei

## Deploy dry run balance row

- Preflight (step 4b): 126,387,510,785,373,739 wei (0.1264 eth), need 77,736,137,529,600,000
- Deploy dry run (step 5): 626,475,137,896,251,597 wei (0.6265 eth), need 77,973,636,921,600,000
- the dry run reads 0.5001 eth above the chain balance (2b21fbf: +0.1651, cb7cb9d: +0.0717). the gap grew again; only the step 4 row reflects the real balance
- the rehearsal test funds the owner with 5 eth, so its balance row (`balance 5000000000000000000`) says nothing about launch funding

## gas per transaction (rehearsal test, block 26176766)

| tx | gas | change from RUNBOOK.md |
|---|---|---|
| 1 library CoreLib (create2 deployer) | 4,398,715 | +58 |
| 2 controller | 1,696,100 | 0 |
| 3 router | 1,017,652 | 0 |
| 4 core | 4,152,515 | +3 |
| 5 lens | 1,918,891 | +57 |
| 6 launch through the factory (`deployTokenAsOwner`, value 0.069 eth) | 3,597,511 | +8 |
| 7 router `setEngine` | 80,542 | 0 |
| 8 router `setPayees` | 177,303 | 0 |
| 9 router `setSplitStart` (Resume) | 60,964 | 0 |
| total, nine transactions | 17,100,193 | +126 |

the nine figures sum to the printed total. per transaction cap 16,777,216; the largest transaction is the library (4.40 million). `DEPLOY_GAS_ESTIMATE` 19,200,000 stays above the total by 2.1 million.

## owner funding (balance 0.126388 eth, fee 0.069 eth)

| base fee | gas cost | gas plus fee | with 20 percent margin | balance minus need | balance minus need with margin |
|---|---|---|---|---|---|
| 1 gwei | 0.01710 eth | 0.08610 eth | 0.10332 eth | +0.04029 | +0.02307 |
| 5 gwei | 0.08550 eth | 0.15450 eth | 0.18540 eth | -0.02811 | -0.05901 |
| 20 gwei | 0.34200 eth | 0.41100 eth | 0.49320 eth | -0.28461 | -0.36681 |

- the balance covers the fee plus the measured gas up to a base fee of 3.36 gwei (2.12 gwei with the 20 percent margin). at 5 gwei the shortfall is 0.0281 eth (0.0590 eth with the margin)
- at 0.455 gwei (the preflight need row) the need is 0.0777 eth; the balance covers it

## director gate (`python3 script/director.py check --gate deploy` at 55a44ad)

exit 1. 53 WARN lines. 11 ERROR lines, the same set as the 2b21fbf rehearsal (verbatim in the run output; long scope lists are cut by the tool):

- `objective OBJ-LAUNCH-1 status is active, not complete`
- `gate independentReview: evidence E-REVIEW-CARRY-483be30 has kind analysis, review; gate accepts review`
- `gate productRules: evidence E-ACCEPT-0c3ecd2 invalid: scope changed after verification: ...`
- `gate focusedTests`, `gate localLifecycle` and `gate fullSuite`: `evidence E-SUITE-CARRY-483be30` and `E-DEEP-CARRY-483be30` invalid: scope changed after verification (each lists `depends on invalid E-TARGETED-483be30`), 6 lines
- `gate independentReview: evidence E-REVIEW-CARRY-483be30 invalid: scope changed after verification: docs/SPEC.md, DEEP-RUN-2b21fbf.log (git history before packet 0), DEEP-RUN-cb7cb9d.log (git history before packet 0), docs/RUNBOOK.md, docs/DECISIONS.md, ...`
- `gate deploymentRehearsal: evidence E-REHEARSAL-CARRY-483be30 invalid: scope changed after verification: docs/RUNBOOK.md, script/Checks.sol, ...; depends on invalid E-TARGETED-483be30`

- no line `non-state files changed after candidate`: the tip-only rule holds at 55a44ad
- every evidence error is a carry from 483be30; the gate holds no record for 267139b yet (this suite, Deep run and rehearsal are the records it needs)
- `E-REVIEW-CARRY-483be30` carries the kinds `analysis, review` and the gate accepts only `review`: a records defect independent of scope, still present

## runbook lines wrong or unclear, with the corrected text

1. section 0 `eth` row (`docs/RUNBOOK.md:54`) and the gas cap section (`docs/RUNBOOK.md:230`): gas figures are from the 2b21fbf rehearsal. corrected text: "17,100,193 gas in total at block 26176766 (candidate 267139b). library 4,398,715, controller 1,696,100, router 1,017,652, core 4,152,515, lens 1,918,891, launch 3,597,511, setEngine 80,542, setPayees 177,303, setSplitStart 60,964". line 230: "library 4,398,715, ... lens 1,918,891, launch 3,597,511 ..., the sum is 17,100,193 over nine transactions, block 26176766". the 0.0861, 0.1545 and 0.4110 eth figures and the 3.36 gwei break-even are unchanged
2. section 0 `the signer` row (`docs/RUNBOOK.md:53`): add "0.1264 eth at block 26176937, the rehearsal of 267139b (the need was 0.0777 eth at the base fee of 0.455 gwei; nonce 3846, unchanged since 26171300)"
3. step 4 (`docs/RUNBOOK.md:92`), config hashes: "rehearsal.json 0xc9a92044..., the tracked mainnet.json with empty metadata 0x78648e0f..., at the launch gap 200" is stale since `recoveryGapBps` is 1000. corrected text: "rehearsal.json 0xaa13cddf..., the tracked mainnet.json with empty metadata 0x3fb811ba..., at the launch gap 1000"
4. step 4 (`docs/RUNBOOK.md:92`): "the `Deploy` dry run of step 5 reads the owner balance 0.07 to 0.17 eth too high". at 267139b the dry run read 0.6265 eth against 0.1264 eth, 0.50 eth too high. corrected text: "reads the owner balance 0.07 to 0.50 eth too high" with the data point "267139b, block 26176941: 0.1264 and 0.6265 eth, need 0.0777 eth"
5. step 5 (`docs/RUNBOOK.md:93`) recorded check: names the rehearsal of 2b21fbf at fe73fd5, block 26176197 and a dry run balance of 0.2915 eth. corrected text: "recorded check (rehearsal of 267139b at 55a44ad, block 26176941, placeholder config): ... the Deploy dry run reads the owner balance 0.6265 eth against 0.1264 eth on chain"; preflight 113 of 116 before `setMinProtocolSkimShareBps(362)` (the same three failed rows), 115 of 116 after it, postflight 96 of 96 after the launch and after the lock
6. `CONTROLLER_NONCE`: the standalone check-preflight, Preflight and Deploy print 3847 (live nonce 3846 plus one, the library is not on chain); the rehearsal test signoff row prints 3846 because the test deploys the library first. RUNBOOK.md gives the "plus one while the library is not on chain" rule; the rehearsal test value 3846 should not be exported for the real run
7. step 4: check-preflight on the tracked `mainnet.json` fails by design (metadata row); behaviour unchanged from 2b21fbf, the launch run uses `local.json`

## launch day surprises

- the Deploy dry run balance gap is now +0.50 eth; the dry run cannot be used to check funding
- the owner is funded for the fee and gas only up to a base fee of 3.36 gwei; at 5 gwei it is 0.0281 eth short
- until the owner sets 362 the broadcast would revert `BountyBpsTooHigh(9638, 9000)` in the launch transaction after the library, controller, router and core went out
- the rehearsal config hash changed with the gap 1000 setting; every operator-held copy of 0xc9a92044... or 0x78648e0f... is stale
