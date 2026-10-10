# handoff: credits engine

the baton for the session that directs this project next. read this file, then run `python3 script/director.py handoff` and read what it lists. the previous baton is `git show 2407087:docs/HANDOFF.md`.

## 1. where intent and evidence live

| source | role |
|---|---|
| AGENTS.md | precedence between the sources below |
| docs/ARCHITECTURE.md | the current reading of intent and of the system. section 1 "current intent at a glance" lists guarantees, behavior, parameters and accepted risks with their decision numbers and status |
| docs/FLOW.md | the dated owner decision log, decisions 1 to 47. a later dated decision supersedes an earlier one |
| docs/NEXT.md | the change list: decided, built, reviewed |
| project/director-state.json | the objective, open owner decisions, gates. `python3 script/director.py status` |
| project/evidence.json | the evidence ledger with the assumptions each record used. `python3 script/director.py evidence` |
| docs/REVIEW-*.md, docs/SIMULATION.md | evidence, each pinned to the commit it examined |
| SPEC.md, docs/V2-PORT.md, docs/BID-STUDY.md, docs/V2-REQUESTS.md | history |

rules for the director:

* a test, a document, a simulation or a checker run is evidence about the system, never authority over intent. a test that agrees with the code and conflicts with the owner's goal is a defect until the owner decides (docs/REVIEW-decisions.md path B is one).
* when a premise changes (a live contract, a market price, a gas price, an owner decision, a removed incentive), bump the assumption's version in project/evidence.json and reopen every record the checker then marks invalid. a mechanism whose reason disappeared is a removal candidate.
* record each owner instruction in docs/FLOW.md and docs/ARCHITECTURE.md section 1 in the turn it is given.
* `python3 script/director.py check --gate working` checks the records' structure. it does not show that a rule or a test is right.

## 2. objective

OBJ-LAUNCH-1: bring the engine to a candidate the owner can launch on mainnet. current intent recorded, every material path traced against it, owner decisions settled, the current source independently reviewed, the full suite, the deep invariants and the rehearsal valid on the frozen candidate, the runbook exact. the owner sends every mainnet transaction.

authority: reconstructed by the director on 2026-10-10 from the owner's launch preparation since 2026-10-08 and the owner's question of 2026-10-10, "ok, skip sepolia then. what else needs to be done here?". paths and deliverables with their status: `python3 script/director.py status`.

## 3. state

| item | state |
|---|---|
| branch | `main` is the working branch on github ripe0x/cc. the director repair of 2026-10-10 is on the local branch `claude/repair-project-director-1366be`, not pushed |
| phase | implementation. no candidate is frozen. NEXT item 21 (preflight `rateCap` row) is built at fb6c26c, with the review matrix isolating each rate bounds row at 2645c00 and f1fd139. focused tests pass, independent review of the change done in the director session of 2026-10-10 |
| source | Core 21,285 bytes runtime (3,291 bytes of headroom), CoreLib 15,608, ControllerV1 4,282, CoreLens 7,479, measured at c8892a2 |
| tests | candidate run at c8892a2: 1013 pass, 0 fail, 8 skipped (the Deep suites), REHEARSAL=1. the real preflight script on a fork: 113 rows, 110 pass, the three documented owner-side failures |
| reviews | none is valid for the current source: every docs/REVIEW-*.md predates 34 or more source commits, and docs/AUDIT-codex.md (commit 32ff35b) is on a branch outside main |
| owner steps before launch | fund the owner address 0xCB43 (0.068 eth at block 26158000, the launch needs about 0.1), run `setMinProtocolSkimShareBps(362)` on the v2 factory, then docs/DEPLOY.md with `--slow` (the owner address is an EIP 7702 delegated account) |

## 4. owner decisions

**OD-1, decided 2026-10-10 (FLOW 48).** the first `migrate` retires the old engine. `ethToBuyback` stays in it and its buyback burns it. the exit token pots move. built as NEXT item 22 at 74d1cbe, full suite 1078 pass, reviewed with no defect (docs/REVIEW-retire.md), follow ups built as NEXT item 23 at eff3051.

**OD-3, decided 2026-10-10 (FLOW 50).** `idleLoosenBps` 2_000 at launch and a lower bound of 1. being built as NEXT item 26 after NEXT item 24.

**OD-5, decided 2026-10-10 (FLOW 51).** buyback slice 0.5 eth at launch, upper bound 1 eth. being built with decision 50 as NEXT item 26.

**OD-4, decided 2026-10-10 (FLOW 52).** `xToBuyback` stays in the old engine on `migrate`. built after NEXT item 26 as NEXT item 27.

**metadata, decided 2026-10-10 (FLOW 53, 54).** the name `CC` is final. `image` and `description` become launch config parameters, built as NEXT item 28 after NEXT item 26. the owner supplies the image url and the description text before launch.

**scores, decided 2026-10-10 (FLOW 55).** the engine stops using credit scores everywhere, phase 2 included: per credit rates and a per credit exit unit. built as NEXT item 29 after items 26 to 28. it changes the Settings struct, the rate units, the exitModule interface, the config, the scripts, the simulator and most tests, so it gets its own full suite, deep invariants and independent review before the freeze.

**removals, decided 2026-10-10 (FLOW 56).** built with NEXT item 29. **OD-6, decided 2026-10-10 (FLOW 57):** `buyListing` stays; the owner's keeper is a fallback, built after launch.

**OD-2, open, does not block the launch.** when to call `coin.lockAllowlist()` and `router.lock()` (NEXT item 19, after launch). after `lockAllowlist`, `rescueCoin` reaches only addresses already listed.

**intent gap, decision 47.** what "ready for when burn router and $balance drop" requires of the engine is not written down. the director drafts it from the v2 burn router source and brings the owner one question if a real choice remains.

## 5. evidence

`python3 script/director.py evidence` lists every record with its validity. what a new session must know:

* valid: the focused tests of the rate rows at f1fd139 (E-FOCUSED-f1fd139) and the decision audit carried to f1fd139. the full suite and the deep invariants recorded on 06009bd are invalid at HEAD, because fb6c26c changed script/Checks.sol and two test files under their scope. they are rerun on the frozen candidate.
* invalid: every independent review (source changed), the codex audit (outside main), the simulator's statement flow figures (they assume a paid composer, decision 41 removed the payment).
* migration gaps: no test migrates into a real second Core and runs `adopt` there, and `adopt` gives a migrated credit the successor's bid as its cost basis (the old basis is dropped).
* unproved assumptions: a composer exists for every full page at no cost to the engine, the 90 day volume projection (1,961 eth, fitted to 13 measured days), the credit market price of 0.0089 eth, the seller book and the absence of competing bidders in the simulator.

## 6. next action

resolve the independent review of c8892a2 (decisions 55 and 56). then freeze the candidate with `python3 script/director.py freeze <commit>`, run the 7 Deep suites once (`CANDIDATE_RUN=1 INVARIANT_DEEP=1 ...`, the only sanctioned long run), an independent security review of the frozen candidate, the rehearsal from a clean checkout, `python3 script/director.py check --gate deploy`, then the owner's launch steps.

owner inputs before launch: the coin's image url and description (config), funding the owner address (0.068 eth held, about 0.1 needed), `setMinProtocolSkimShareBps(362)` on the factory, the launch day `rateStart` and `rateCap` from the credit price.

## 7. how to work in this repo

| topic | rule |
|---|---|
| naming | the phase 2 contracts are referred to only as `exitModule` and `exitToken` in code, comments, tests, docs and commit messages. never name or describe them |
| tests | mainnet fork tests pinned to block 26158000 (`FORK_BLOCK`), real contracts only, the live v2 stack included. the only doubles are test/standins and attacker contracts |
| toolchain | foundry 1.8.1 (isolate on), solc 0.8.30. forge 1.8.1 rewrites foundry.lock and bumps lib/solady on build: `git checkout foundry.lock lib/solady` before committing. a fresh worktree needs `git -C lib/v4-periphery submodule update --init lib/v4-core lib/permit2`. fork tests read `MAINNET_RPC_URL` and `FORK_BLOCK` from the environment: `set -a; source .env; set +a` |
| timings | clean build about 3 to 4 minutes, a test file change about 3 seconds, a `src/Core.sol` change about 35 seconds. full suite with `REHEARSAL=1 forge test -j 6` about 2 minutes on a 16 core machine (rerun rpc failures with `-j 1`). a Deep suite 577 to 692 seconds: `INVARIANT_DEEP=1 FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=200 forge test --match-contract '^<Suite>Deep$'` |
| verification | during an edit run the smallest test that covers it (`--match-path`). run one combined gate at a batch boundary. full suites, deep invariants and the rehearsal belong to a frozen candidate or to a gate whose evidence was invalidated. before a command over 30 seconds, say what it must establish |
| interfaces | after changing a production contract's external surface run `script/tools/gen-interfaces.sh` and repin test/BuildIdentity.t.sol. never import `src/Core.sol` in a test |
| Core size | 512 bytes left, margin rule at least 60. new logic goes into `CoreLib`. never drop a check to make room |
| safety | no mainnet broadcast, deploy, push or private key without the owner's explicit instruction |

## 8. known and not fixed

| item | detail |
|---|---|
| exitModule gas | `exitStatement` forwards gas to a contract that does not exist yet. measure it against the gas cap when it does |
| v2 audit | pending. preflight pins the code hash of nine live v2 contracts read at block 26158000. a changed stack means new addresses and pins |
| owner key | a stolen owner key moves everything at once (docs/ARCHITECTURE.md section 10). a multisig owner and watching `SuccessorSet` and `Migrated` are the mitigations |
