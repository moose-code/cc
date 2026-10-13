# rehearsal of docs/DEPLOY.md at the frozen candidate 24378f9 (branch tip 00301d5)

- candidate: 24378f9. run in the worktree at the tip 00301d5 (the candidate plus `freeze candidate 24378f9`, which adds the state file). `git status` shows only the untracked `.claude/launch.json`. `out/` and `cache/` are the worktree's own
- chain: mainnet through https://gateway.tenderly.co/public/mainnet, reads only. the rehearsal test (`test/Rehearsal.t.sol`) forks the latest block at each run: 26184372 (inside the full suite), 26184400 (rerun with `-j 1`), 26184406 (alone with `-vv`)
- config: `LAUNCH_CONFIG=script/config/rehearsal.json` (placeholder image and description, by design). CONFIG_HASH 0x1688b478e48708eadd1f17261ff4a145e27f586ab74614cdff5c808be6b6d851
- sent nothing: no `cast send`, no `--broadcast`, no key, no ledger, no `.env`. the rehearsal runs on a fork inside `forge test`
- tooling: forge 1.8.1
- environment: `CANDIDATE_RUN=1 REHEARSAL=1 MAINNET_RPC_URL=https://gateway.tenderly.co/public/mainnet FORK_BLOCK=26158000`

## result

`test_rehearsal` FAILS at 24378f9 on its gas assertion, in the full suite (docs/SUITE-24378f9.log), in the rerun (docs/RERUN-24378f9.log) and alone:

```
[FAIL: the measured deploy gas is above DEPLOY_GAS_ESTIMATE: 20134787 > 19200000] test_rehearsal() (block: 26184406)
```

the suite run at block 26184372 read 19373863 > 19200000; the two later runs read 20134787 > 19200000. the assertion sits before the postflight and the trading smoke, so the unmodified test stops there.

to reach the later steps a throwaway copy of the worktree (outside the repository, no git metadata) ran the same test with the one assertion `assertLe(total, DEPLOY_GAS_ESTIMATE, ...)` raised to 40,000,000. nothing in the repository changed. in that copy (block 26184408):

- preflight before the owner command: 117 of 120, exactly the three expected rows failing (placeholder image and description, `min protocol skim share leaves room for the bounty`, `deployTokenAsOwner accepts the config (simulated)` reverting 0x55dd302a, BountyBpsTooHigh 0x25a6 = 9638)
- preflight after the owner command: 119 of 120, only the placeholder row failing
- postflight after the launch: 99 of 99 pass, 1 WARN (`warn: coin fee recipients are not locked yet`)
- postflight after the lock step: 99 of 99 pass
- the test then FAILS at the trading smoke step: `all of it reached the pot (no payee share in the flush that starts the split): 59851980000000000 != 66502200000000000` (the ratio is 0.9). the smoke sale result is therefore not recorded
- the same ratio 0.9 appears in test/V2PortMigration.t.sol (docs/SUITE-24378f9.log): `53101993399560000 != 59002214888400000`, and the same assertions fail at f171863 (the commit before 24378f9) in a copy of that commit

## live state read on the run

| item | value |
|---|---|
| owner 0xCB43...17F9 nonce | 3848 (latest, block 26184423) |
| owner balance | 93,283,894,234,589,749 wei = 0.093284 eth |
| factory `minProtocolSkimShareBps` | 1000 (step 3 open) |
| factory `deployFee()` | 0.069 eth |
| base fee | 0.842 gwei at block 26184422 |
| rehearsal test balance row | the test funds the owner with 5 eth (`balance 5000000000000000000 need 81784972416000000`); the real balance is the row above |

## gas per transaction (rehearsal test, block 26184406)

| tx | gas | 267139b (docs/REHEARSAL-267139b.md) |
|---|---|---|
| 1 library CoreLib (create2 deployer) | 4,327,043 | 4,398,715 |
| 2 controller | 3,468,326 | 1,696,100 |
| 3 router | 1,017,652 | 1,017,652 |
| 4 core | 4,171,128 | 4,152,515 |
| 5 lens | 3,227,650 | 1,918,891 |
| 6 launch through the factory (`deployTokenAsOwner`, value 0.069 eth) | 3,604,080 | 3,597,511 |
| 7 router `setEngine` | 80,542 | 80,542 |
| 8 router `setPayees` | 177,303 | 177,303 |
| 9 router `setSplitStart` (Resume) | 61,063 | 60,964 |
| total, nine transactions | 20,134,787 | 17,100,193 |

the nine figures sum to the printed total. per transaction cap 16,777,216; the largest transaction is the library (4.33 million). `DEPLOY_GAS_ESTIMATE` is 19,200,000, below the total by 934,787 (4.9 percent). the full suite run at block 26184372 measured a total of 19,373,863 (173,863 above the estimate); its per transaction figures are not in the log because the suite runs without `-vv`.

## owner funding (balance 0.093284 eth, fee 0.069 eth, gas 20,134,787)

| base fee | gas cost | gas plus fee | with 20 percent margin | balance minus need | balance minus need with margin |
|---|---|---|---|---|---|
| 1 gwei | 0.02013 eth | 0.08913 eth | 0.10696 eth | +0.00415 | -0.01368 |
| 5 gwei | 0.10067 eth | 0.16967 eth | 0.20361 eth | -0.07639 | -0.11032 |
| 20 gwei | 0.40270 eth | 0.47170 eth | 0.56603 eth | -0.37841 | -0.47275 |

- the balance covers the fee plus the measured gas up to a base fee of 1.21 gwei (0.43 gwei with the 20 percent margin). the base fee at block 26184422 is 0.842 gwei, need 0.0860 eth
- the test prints the same three rows from the gas total: gas plus fee 0.08913 / 0.16967 / 0.47169 eth

## step table

| step | command (dry form) | result |
|---|---|---|
| 1 | `LAUNCH_CONFIG=script/config/rehearsal.json` | CONFIG_HASH 0x1688b478... |
| 2 | `CANDIDATE_RUN=1 REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv` | FAIL, gas assertion, see result |
| 3 | `setMinProtocolSkimShareBps(362)` | not sent. the rehearsal test applies it as the impersonated owner |
| 4 | preflight inside the rehearsal test | 117 of 120 before the owner command, 119 of 120 after it. CONTROLLER_NONCE 3848 before, 3849 after |
| 5 to 10 | Deploy, Resume, Postflight and Lock dry forms, etherscan verify | not run in this record. the rehearsal test covers the launch, postflight and lock in-process (see result) |

## runbook and record lines that need the owner or director

1. docs/DEPLOY.md and `DEPLOY_GAS_ESTIMATE` state 17,100,193 gas for nine transactions and 19,200,000 as the estimate. the measured total at 24378f9 is 20,134,787 (19,373,863 at block 26184372). the controller (3,468,326 against 1,696,100) and the lens (3,227,650 against 1,918,891) account for the growth
2. the preflight balance row prices the deploy at `DEPLOY_GAS_ESTIMATE`; at the measured total the break-even base fee is 1.21 gwei at the current balance of 0.0933 eth (3.36 gwei at the 267139b rehearsal: balance 0.1264 eth, gas 17,100,193)
3. the owner balance is 0.0933 eth (0.1264 eth at the 267139b rehearsal) and the nonce is 3848 (3846 then)
