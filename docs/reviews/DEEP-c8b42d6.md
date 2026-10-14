# deep invariant runs at c8b42d6

date 2026-10-13. in a detached worktree at c8b42d6 (the candidate: the two fixes of decision 115 on top of the frozen system). each suite on its own: `CANDIDATE_RUN=1 INVARIANT_DEEP=1 FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=200 forge test --match-contract '^<Suite>$' -j 8`, 12,800 calls per invariant campaign, on the mainnet fork pinned to block 26158000, foundry 1.8.1.

| suite | result | seconds |
|---|---|---|
| InvariantsPhase1Deep | ok, 19 invariants | 452 |
| InvariantsPhase1WindowDeep | ok | 439 |
| InvariantsPhase2Deep | ok | 574 |
| InvariantsHostileControllerDeep | ok | 577 |
| InvariantsHostileOwnerDeep | ok | 539 |
| InvariantsSalePhase1Deep | ok | 456 |
| InvariantsSalePhase2Deep | ok | 557 |

no invariant broke. the hostile owner suite now exercises `rescueNft` refusing Credits in every state (decision 115).
