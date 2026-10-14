# rehearsal at ff0a2af

date 2026-10-13. `REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv` with `FORK_BLOCK` unset: a fork of the latest block, 26187072 (timestamp 1791936695), the live v2 stack, the owner impersonated, the config script/config/rehearsal.json (metadata placeholders by design). nothing was sent to mainnet.

what it did: preflight before the owner command (113 of 116 rows pass: the metadata row and the two factory rows fail as expected), the owner command `setMinProtocolSkimShareBps(362)`, preflight after it (115 of 116, the metadata row), the whole deploy, postflight after the launch (70 of 70), the lock step and postflight after it (70 of 70), a trading smoke.

| tx | gas |
|---|---|
| 1 library CoreLib (CREATE2) | 3,201,302 |
| 2 Core (CREATE2) | 5,242,833 |
| 3 controller (CREATE2) | 3,006,036 |
| 4 Seaport adapter (CREATE2) | 643,535 |
| 5 CreditStrategy adapter (CREATE2) | 167,102 |
| 6 setController | 72,594 |
| 7 addAdapter, Seaport | 79,858 |
| 8 addAdapter, strategy | 79,858 |
| 9 launch, deployTokenAsOwner | 3,627,710 |
| total | 16,120,828 |

`DEPLOY_GAS_ESTIMATE` 18,600,000 (the total plus 15 percent). every transaction is under the 16,777,216 cap. the deploy fee is 0.069 eth. the deployer needs, fee included: 0.08512 eth at 1 gwei, 0.14960 at 5 gwei, 0.39141 at 20 gwei.

addresses at this config and signer (they move with the config, the deploy prints the real ones): Core 0x42ad934e10870c9d2C9277a43e5368FA946aFcc2, coin 0x6B53D655BA45dFC02e3f7da84419b58A7a18F675, library 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f. Core runtime 21,531 bytes.

the config hash and the row counts: 116 preflight rows, 70 postflight rows. the launch day run uses script/config/local.json with the real `image`, `description`, `rateStart`, `rateCap` and `royaltyRecipient`, where every preflight row passes after the owner command.
