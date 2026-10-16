# credits engine: agent entrypoint

read docs/STATUS.md first. CLAUDE.md points here.

## authority

1. the owner's latest explicit instruction.
2. docs/SPEC.md: the current reading of intent and of the system (section 1 is the intent table).
3. docs/DECISIONS.md: the dated owner decision log. a later dated decision supersedes an earlier one.
4. code, tests, simulations and reviews: evidence, never authority over intent.

record each owner instruction in docs/DECISIONS.md and docs/SPEC.md section 1 in the turn it is given. when a test agrees with the code and conflicts with the owner's goal, raise it as a defect.

## working rules

- every line, test, helper and document justifies its existence by the promise it protects; else it is not written. a kept test carries a `// promise:` line.
- each change gets `forge build` and `forge test --match-path` for the test files it touched, nothing more. the full suite, the deep invariants and the rehearsal run once, on the frozen candidate, marked `CANDIDATE_RUN=1`. a hook refuses a whole suite run without the marker.
- after a forge run: `git checkout foundry.lock; git submodule update -- lib/solady`. after a change of a production contract's external surface: `script/tools/gen-interfaces.sh`, then re-pin the build hashes in script/Checks.sol and test/BuildIdentity.t.sol.
- no mainnet broadcast, deploy, push to main, merge or private key without the owner's explicit instruction.
- the vocabulary is "balance", never "exit" (decision 102). comments state rules, invariants and caveats in plain technical voice; no em or en dashes.
- a change that adds data to the web names its source in docs/INDEXER.md section 9.
- toolchain, timings and the fork env: docs/STATUS.md section 5.
