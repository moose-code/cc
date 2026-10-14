# rehearsal at c8b42d6

date 2026-10-13. `REHEARSAL=1 forge test --match-path test/Rehearsal.t.sol -vv` with `FORK_BLOCK` unset: a fork of block 26187632 (timestamp 1791943463), the live v2 stack, the owner impersonated, script/config/rehearsal.json. nothing was sent to mainnet. preflight 113 of 116 before the owner command (the metadata row and the two factory rows, as expected), 115 of 116 after it, postflight 70 of 70 after the launch and after the lock step.

| tx | gas |
|---|---|
| 1 library CoreLib (CREATE2) | 3,199,712 |
| 2 Core (CREATE2) | 5,242,833 |
| 3 controller (CREATE2) | 3,030,171 |
| 4 Seaport adapter (CREATE2) | 643,535 |
| 5 CreditStrategy adapter (CREATE2) | 167,102 |
| 6 setController | 72,594 |
| 7 addAdapter, Seaport | 79,858 |
| 8 addAdapter, strategy | 79,858 |
| 9 launch, deployTokenAsOwner | 3,627,789 |
| total | 16,143,452 |

`DEPLOY_GAS_ESTIMATE` 18,600,000 holds. every transaction is under the 16,777,216 cap. the deployer needs, fee included: 0.08514 eth at 1 gwei, 0.14971 at 5 gwei, 0.39186 at 20 gwei. runtime sizes: Core 21,531, CoreLib 14,495, ControllerV1 13,129, SeaportBasicAdapter 2,558, CreditStrategyAdapter 508.
