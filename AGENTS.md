# credits engine: agent entrypoint

Read `docs/STATUS.md` first. `CLAUDE.md` points here.

## Authority

1. The owner's latest explicit instruction.
2. `docs/SPEC.md`: the current reading of intent and of the system (section 1 lists guarantees, behavior, parameters and accepted risks).
3. `docs/DECISIONS.md`: the dated owner decision log. A later dated decision supersedes an earlier one.
4. Code, tests, simulations and reviews: evidence, never authority over intent.

Record each owner instruction in `docs/DECISIONS.md` and `docs/SPEC.md` section 1 in the turn it is given. When a test agrees with the code and conflicts with the owner's goal, raise it as a defect.

## Objective

The plan, the open items and the freeze table are in `docs/STATUS.md`. A fix or a green suite is progress toward the freeze. Before ending a turn, compare the plan with what is done, state what remains, and continue the next authorized step.

## Working rules

- One active director. Implementers get bounded packets. Reviewers inspect an immutable commit, challenge the director's reasoning, and do not fix their own findings.
- Each change gets `forge build` and `forge test --match-path` for the test files it touched. Nothing more. The full suite, the deep invariants and the rehearsal run once, on the frozen candidate. A builder packet never asks for a full suite on a work item. Before a command over 30 seconds, say what it must establish.
- No mainnet broadcast, deploy, push, merge or private key without the owner's explicit instruction.
- The vocabulary is "balance", never "exit" (docs/DECISIONS.md decision 102). Until the rename packet (docs/STATUS.md section 2, packet 1) lands, the code still carries `exitModule`, `exitToken` and `exitMode`; new text and new code use the balance names.
- Toolchain, timings and test rules: `docs/STATUS.md` section 5.
