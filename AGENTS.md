# credits engine: agent entrypoint

Read `docs/HANDOFF.md` first, then run `python3 script/director.py handoff` and read what it lists. `CLAUDE.md` points here. For directing, reviewing or handing over this project, use the `project-director` skill; these records are its adopted layout.

## Authority

1. The owner's latest explicit instruction.
2. `docs/ARCHITECTURE.md`: the current reading of intent and of the system (section 1 lists guarantees, behavior, parameters and accepted risks).
3. `docs/FLOW.md`: the dated owner decision log. A later dated decision supersedes an earlier one.
4. Code, tests, simulations, reviews and `script/director.py` output: evidence, never authority over intent.

Record each owner instruction in `docs/FLOW.md` and `docs/ARCHITECTURE.md` section 1 in the turn it is given. When a test agrees with the code and conflicts with the owner's goal, raise it as a defect. When a premise changes, bump its assumption in `project/evidence.json` and reopen what `python3 script/director.py evidence` marks invalid.

## Objective

The active objective, its required paths and deliverables, and the open owner decisions are in `project/director-state.json` (`python3 script/director.py status`). A fix or a green suite is progress toward the objective. Before ending a turn, compare the objective with valid evidence, state what remains, and continue the next authorized step.

## Working rules

- One active director. Implementers get bounded packets. Reviewers inspect an immutable commit, challenge the director's reasoning, and do not fix their own findings.
- Each change gets `forge build` and `forge test --match-path` for the test files it touched. Nothing more. The full suite, the deep invariants and the rehearsal run once, on the frozen candidate. A builder packet never asks for a full suite on a work item. Before a command over 30 seconds, say what it must establish.
- No mainnet broadcast, deploy, push, merge or private key without the owner's explicit instruction.
- The vocabulary is "balance", never "exit" (docs/FLOW.md decision 102). Until the rename packet (docs/NEXT.md item 38) lands, the code still carries `exitModule`, `exitToken` and `exitMode`; new text and new code use the balance names.
- Toolchain, timings and test rules: `docs/HANDOFF.md` section 7.
