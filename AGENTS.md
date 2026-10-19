# credits engine: agent entrypoint

read docs/STATUS.md first. CLAUDE.md points here.

## authority

1. the owner's latest explicit instruction.
2. docs/SPEC.md: the current reading of intent and of the system (section 1 is the intent table).
3. docs/DECISIONS.md: the dated owner decision log. a later dated decision supersedes an earlier one.
4. code, tests, simulations and reviews: evidence, never authority over intent.

Record consequential owner decisions once in docs/DECISIONS.md; update affected specification promises when behavior changes. Ordinary feedback and status requests need no duplicate ledger entry. When a test agrees with the code and conflicts with the owner's goal, raise it as a defect.

## working rules

- every line, test, helper and document justifies its existence by the promise it protects; else it is not written. a kept test carries a `// promise:` line.
- Batch related feedback and verify coherent slices with checks for changed behavior and affected callers, including unchanged tests where relevant. A focused Forge test supplies compilation with its selected settings; Python, shell and documentation changes need their own checks, not an unrelated Solidity build. Keep valid evidence. The full suite, deep invariants and broad rehearsal belong to the frozen candidate (`CANDIDATE_RUN=1`); repeat affected checks after repairs. The hook still refuses unmarked broad runs.
- Inspect unexpected foundry.lock or submodule changes; do not automatically restore files or reset another task's work. After a change of a production contract's external surface: `script/tools/gen-interfaces.sh`, then re-pin the build hashes in script/Checks.sol and test/BuildIdentity.t.sol. Check deployment bytecode size when it changes.
- Name the release step: deferred Core, coin launch or service activation. Preserve the evidence and owner approval scoped to that step; do not convert a waiver into a pass or a Core approval into permission to launch the coin. Use `script/tools/check-freeze.sh <core|coin|services>`; the default checks coin launch. Later-stage requirements block an earlier step only for a concrete risk to that step.
- no mainnet broadcast, deploy, push to main, merge or private key without the owner's explicit instruction.
- the vocabulary is "balance", never "exit" (decision 102). comments state rules, invariants and caveats in plain technical voice; no em or en dashes.
- a change that adds data to the web names its source in docs/INDEXER.md section 9.
- toolchain, timings and the fork env: docs/STATUS.md section 5.
