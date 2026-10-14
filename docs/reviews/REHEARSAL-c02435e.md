# rehearsal of docs/RUNBOOK.md at the frozen candidate

- commit: c02435e3b70eaeac85510d94707645e5cbe2b793 (clean clone of the worktree, submodules init, out/ and cache/ copied)
- inputs: `git diff c02435e -- src script` in the original worktree is empty
- chain: mainnet fork of the latest block via https://mainnet.gateway.tenderly.co (block 26165117 to 26165132 across the runs; `PRIVATE_RPC` the same)
- `Rehearsal.t.sol` forked block 26165132, timestamp 1791672599
- nothing was broadcast. no `cast send`, no key, no ledger, no .env read (the clone has only `.env.example`)
- tooling: forge 1.8.1, jq 1.7.1, config copies `script/config/local.json` (gitignored; empty and filled)

## live state read on the run

| item | value |
|---|---|
| owner 0xCB43...17F9 nonce | 3835 (pin block 26158000: 3822) |
| owner balance | 0.016319 eth (doc step 0 says 0.068 at the pin) |
| factory `minProtocolSkimShareBps` | 1000 |
| `setMinProtocolSkimShareBps(362)` as an `eth_call` from the owner | succeeds (returns 0x), the owner command is valid |
| mevblocker rpc | serves `eth_getCode`, `eth_call`, `eth_getStorageAt` for the factory |

## numbers

| item | empty strings | filled placeholders |
|---|---|---|
| preflight rows (step 4) | 121: 118 pass (116 ok, 2 WARN), 3 FAIL | 121: 118 pass (117 ok, 1 WARN), 3 FAIL |
| WARN rows | `warn: image and description are filled`, `warn: owner differs from creator` | `warn: owner differs from creator` |
| FAIL rows | balance, `factory: min protocol skim share leaves room for the bounty`, `factory: deployTokenAsOwner accepts the config (simulated)` | the same three |
| CONFIG_HASH | 0x4d7b2e2bed9b49b0a4e753ad212eaf8d160844278d9711ad1e17e300bcc1be3a | 0xb32d568a6622aeb73ba328dc7992f2148cd9a65c1c0c7ff35b1a54fcb53d03d9 |
| CONTROLLER_NONCE | 3836 | 3836 |
| `Deploy.s.sol` dry run (step 5) | 119 of 121, FAIL: the two factory rows | 119 of 121, FAIL: the two factory rows |
| predicted coin | 0xcaCF08FD55b216CC133f1ef23b1D05B29E2a4e44 | 0x28E5d1475deF92a975a467c4546dcbE186a0fD93 |

- the failing owner-side rows are exactly the documented ones: balance (need 0.0704 eth, have 0.0163), and the two factory rows. The simulated `deployTokenAsOwner` reverts `BountyBpsTooHigh(9638, 9000)` (selector 0x55dd302a, 0x25a6 = 9638, 0x2328 = 9000)
- `check-preflight.sh` (pin block, tracked mainnet.json): CONFIG_HASH 0x4d7b2e2b... (the empty hash), CONTROLLER_NONCE 3822, failed rows exactly the expected three
- `FORK_BLOCK=26165132 check-preflight.sh script/config/local.json`: hash 0xb32d568a..., nonce 3836, the same three failed rows
- predicted addresses (filled config, nonce 3836): library 0x380dF8c74cAd52ed8bACEc97F72EC76c924D761a (create2, takes nonce 3835), controller 0xed702407Eb555b7e55C8DAA0a428C7A6A53eFf79 (3836), router 0x9ea4a2635009C91BbFC2CDcE58C22f62FCBEc3C6 (3837), core 0x91B6B85cCBA9A3147F3BD31c892352643bDdF621 (3838), lens 0x13EA088D47Db080b3d31B22017173885fE5F7427, house 0x80cc27A880c6105B5229db296A7bdc639bc907BC
- `Deploy.s.sol` stopped at its preflight, so forge printed no gas estimate. The measured gas is the rehearsal test (launch through the live factory with the owner impersonated, the owner command applied): total 16,862,800 for nine transactions. library 4,023,725, controller 989,225, router 1,017,652, core 4,716,981, lens 2,199,400, launch 3,597,013, setEngine 80,542, setPayees 177,303, setSplitStart 60,959. Cap per transaction 16,777,216. Needs at 1 / 5 / 20 gwei: 0.0859 / 0.1533 / 0.4063 eth including the 0.069 eth fee
- rehearsal test: PASS (13 s). preflight 119 of 121 before the owner command, 121 of 121 after, postflight 102 of 102 after the launch and 102 of 102 after the lock, trading smoke sold credit 1 for 8,900,000,000,000,000 wei

## steps

| step | command (dry form) | result | doc change |
|---|---|---|---|
| 0 | `set -a; . ./.env; set +a`, the exports, `cast code $FACTORY` and `cast call $FACTORY "owner()(address)"` | exports and both cast reads work (jq 1.7.1) | `.env` does not exist in a fresh clone; say to create it from `.env.example`. The code prefix printed is `0x60c0...`, the doc says `0x6080...`: write `0x60...` |
| 1 | `cp script/config/mainnet.json script/config/local.json`, `export LAUNCH_CONFIG=...` | works, git tree stays clean | `LAUNCH_CONFIG` must sit inside the project: a file in /private/tmp fails with `vm.readFile ... not allowed` (fs_permissions). State that |
| 2 | `REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv` | works, see numbers | gas table in step 0 is stale (below). The first preflight inside the test shows router and core one nonce lower than the script (0xed70... / 0x9ea4...) because the test is not a script context; the final addresses equal the script's |
| 3 | `cast send ... setMinProtocolSkimShareBps(362)` | blocked by the owner step; the same call as `eth_call` from the owner succeeds | none |
| 4 | `DEPLOYER=$DEPLOYER forge script script/Preflight.s.sol --rpc-url $MAINNET_RPC_URL` | works. Exit 1 with `ChecksFailed(...)` of the three owner-side rows, hash and nonce printed | the output is 1,200 lines of traces, the table is at the end; suggest `\| grep -E '^ +(WARN\|FAIL\|[0-9]+ of\|CONFIG_HASH\|CONTROLLER_NONCE)'`. "121 rows" is correct |
| 5 | `forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --sender $DEPLOYER` with `CONFIG_HASH` and `CONTROLLER_NONCE` | works as written, stops at the two factory rows | the recorded check numbers (108/109 preflight, 99 postflight, 23,599,965 gas) are older than this candidate: the current rows are 121 and 102 |
| 6 | `git checkout foundry.lock lib/solady` then `python3 script/director.py check --gate deploy` | checkout works. The gate prints ERROR at c02435e (see surprises); no broadcast | none; broadcast blocked by the owner |
| 7 | `forge script script/Resume.s.sol ... --sender $DEPLOYER` with `CORE` (the predicted core) | refuses `CoreMismatch("no code at the core address, run Deploy instead")`, the correct refusal before the launch | the dry form needs `--sender $DEPLOYER` instead of `--ledger`; say so |
| 8 | etherscan verify | not run (nothing deployed) | none |
| 9 | `CORE=... DEPLOYER=... CONFIG_HASH=... forge script script/Postflight.s.sol --rpc-url $MAINNET_RPC_URL` | refuses `code: core` (1 of 2 checks) on the predicted core; its 102-row pass is covered by the rehearsal test | doc says "100 rows on the fixture": 102 |
| 10 | `CORE=... forge script script/Lock.s.sol --rpc-url $MAINNET_RPC_URL` (no `SEND`) | runs postflight first, stops `code: core` (0 of 1). The rehearsal test lock step passes | none |
| 11-12 | owner decisions, keeper duties | not run | none |
| tools | `script/tools/check-preflight.sh` | works as written, both forms above | none |

## doc corrections needed

1. Step 0 gas row: total 16,862,800 (doc 17,581,727); per transaction figures above (doc: library 4,183,134, controller 1,024,461, core 5,328,452, lens 2,229,870, launch 3,479,793, setSplitStart 60,520). `DEPLOY_GAS_ESTIMATE` 19,200,000 stays above the total.
2. Step 0 balance: the owner holds 0.0163 eth now (doc 0.068 at the pin). The launch needs about 0.0704 eth at the live base fee, and 0.0859 at 1 gwei by the rehearsal.
3. Step 5 recorded numbers (108/109, 99, 23,599,965): refresh to 121 preflight rows and 102 postflight rows.
4. Step 9 "100 rows": 102.
5. Section 0 private rpc test: expected code prefix `0x60...`.
6. Step 1: `.env` creation, and `LAUNCH_CONFIG` inside the project tree.
7. Step 7: the dry form of Resume, Postflight and Lock is the doc command without `--broadcast` and `--ledger`, plus `--sender $DEPLOYER` for Resume.

## what would surprise an operator on launch day

- the director gate at c02435e fails: `project/director-state.json` there still records candidate 1e2c4b3, and the evidence and non-state-file checks run against it. The re-freeze is in 5826fff and 847a60d (they change only `project/director-state.json` and `project/evidence.json`). At 847a60d the gate refuses only on: objective OBJ-LAUNCH-1 active, and the gates productRules, independentReview and deploymentRehearsal with no evidence. The operator must run step 6 at the re-frozen HEAD with those three gates recorded.
- the owner key is active: nonce 3822 to 3835 and balance 0.068 to 0.0163 eth since the pin block. CONTROLLER_NONCE and the predicted addresses move with every owner transaction, so take both fresh from step 4 immediately before step 5 and step 6.
- the balance row fails in `Preflight` (balance 0.0163) and passes inside the `Deploy` dry run (the log shows 0.0969 eth there). The cause is not found: a scratch script with `--sender` showed the real balance. The step 5 dry run therefore does not catch an underfunded owner. Run step 4 and read the balance row.
- the copied `out/` carries an artifact for a deleted source (`test/Window.t.sol`) and forge prints "Detected artifacts built from source files that no longer exist". `forge clean` would force a full via_ir rebuild and could change the build pins, so leave it. `forge test` recompiled one file (PostflightV2.sol, warnings only) and the build rows still passed.
- the filled and empty configs give different CONFIG_HASH and different predicted coins (image and description are inputs of the coin address). Fill them before step 4.
- the premise of the doc (`stack` equal to `v2-mainnet.json`, nine code hashes) held at the latest block: all stack rows passed.
