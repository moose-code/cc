# full suite at c8b42d6

date 2026-10-13. command: `CANDIDATE_RUN=1 REHEARSAL=1 forge test -j 6` on a mainnet fork pinned to block 26158000, foundry 1.8.1, from the worktree of branch simplify/v1 at c8b42d6 (the merge of the two security fixes of decision 115 and the web app; the last src/ change is 43c9f94).

result: 78 test suites in 186.64 s, 426 tests passed, 0 failed, 7 skipped (the seven Deep invariant suites, docs/reviews/DEEP-c8b42d6.md). the rehearsal ran inside this run and once more on its own (docs/reviews/REHEARSAL-c8b42d6.md). the simulator parity test: 1,765 checks passed.
