# full suite at ff0a2af

date 2026-10-13. command: `CANDIDATE_RUN=1 REHEARSAL=1 forge test -j 6` on a mainnet fork pinned to block 26158000, foundry 1.8.1, from the worktree of branch simplify/v1 at ff0a2af (the merge of the simulator packet; the last src/ change is b88940c plus comment edits at 086a946, which leave the masked build hashes unchanged, test/BuildIdentity.t.sol green).

result: 78 test suites in 148.82 s, 424 tests passed, 0 failed, 7 skipped (the seven Deep invariant suites, which run on their own, docs/reviews/DEEP-ff0a2af.md). the rehearsal ran inside this run (`REHEARSAL=1`) and once more on its own (docs/reviews/REHEARSAL-ff0a2af.md).

the simulator parity test: `node sim/engine.test.mjs`, 1,763 checks passed at ff0a2af.
