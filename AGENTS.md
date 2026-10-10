# credits engine: agent entrypoint

Read `docs/HANDOFF.md` first, then run `python3 script/director.py handoff` and read what it lists. `CLAUDE.md` points here.

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
- During an edit, run the smallest test that covers it. Full suites, deep invariants and the rehearsal belong to a frozen candidate or to a gate whose evidence was invalidated. Before a command over 30 seconds, say what it must establish.
- No mainnet broadcast, deploy, push, merge or private key without the owner's explicit instruction.
- Phase 2 contracts are named only `exitModule` and `exitToken`.
- Toolchain, timings and test rules: `docs/HANDOFF.md` section 7.
