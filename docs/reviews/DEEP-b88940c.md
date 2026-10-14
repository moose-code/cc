# deep invariant runs at b88940c

date 2026-10-13. in a detached worktree at b88940c (the last src/ change; the commits after it change comments, tests, sim and docs only, and the masked build hashes are unchanged). each suite on its own: `CANDIDATE_RUN=1 INVARIANT_DEEP=1 FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=200 forge test --match-contract '^<Suite>$' -j 8`, 12,800 calls per invariant campaign, on the mainnet fork pinned to block 26158000, foundry 1.8.1.

| suite | result | seconds |
|---|---|---|
| InvariantsPhase1Deep | ok, 19 invariants, 6 tests | 480 |
| InvariantsPhase1WindowDeep | ok | 464 |
| InvariantsPhase2Deep | ok | 578 |
| InvariantsHostileControllerDeep | ok | 564 |
| InvariantsHostileOwnerDeep | ok | 544 |
| InvariantsSalePhase1Deep | ok | 452 |
| InvariantsSalePhase2Deep | ok | 570 |

no invariant broke. the invariant 6 flake found by packet 8 (a one wei difference between the read and the model after the pending fee share entered `ethRate`) was fixed in the test model in packet 6b and did not recur in any of the seven runs.
