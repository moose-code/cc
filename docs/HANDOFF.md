# handoff: credits engine

the baton for the session that directs this project next. read this file, then run `python3 script/director.py handoff` and read what it lists. the previous baton is `git show 2407087:docs/HANDOFF.md`.

## 1. where intent and evidence live

| source | role |
|---|---|
| the owner's latest explicit instruction | overrides every file below until the director records it, in the same turn |
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
| phase | implementation. no candidate is frozen |
| source | Core 24,064 bytes runtime (512 bytes of headroom), CoreLib 16,967, ControllerV1 4,445, FeeRouter 4,446, CoreLens 8,702, measured on 382b967 |
| tests | 1059 pass, 0 fail, 8 skipped (the Deep suites), REHEARSAL=1, foundry 1.8.1, fork block 26158000, on 06009bd. the 7 Deep suites with 20 invariants each are clean at 64 runs and depth 200 on 06009bd (NEXT item 7) |
| reviews | none is valid for the current source: every docs/REVIEW-*.md predates 45 or more source commits, and docs/AUDIT-codex.md (commit 32ff35b) is on a branch outside main |
| owner steps before launch | fund the owner address 0xCB43 (0.068 eth at block 26158000, the launch needs about 0.1), run `setMinProtocolSkimShareBps(362)` on the v2 factory, then docs/DEPLOY.md with `--slow` (the owner address is an EIP 7702 delegated account) |

## 4. owner decisions

**OD-1, open, blocks the freeze.** after the first `migrate`, should the old engine stop buying and composing?

* as built: the old engine keeps every door open. sale proceeds and any fees still routed to it are spent on credits, and full pages can be composed into new statements that only the old engine can sell. the owner then calls `migrate` again, as often as proceeds arrive. `test_OK_theEngineKeepsWorkingAfterAMigration` asserts this.
* the owner's words (2026-10-09): "migrate only credits and eth and let v1 sell out its own statements". FLOW 33: "a later migrate moves" the proceeds.
* option A, keep as built: no code change. the wind down lasts as long as proceeds arrive, and the old engine bids against the new one meanwhile.
* option B, retire on the first migrate: the old engine stops `sellForEth`, `buyListing`, `adopt`, `compose` and `composeExit`, and keeps settling, exiting and overprinting its statements and running the buyback. proceeds wait in the pot for the next `migrate`. cost: one flag in the Core, checked once in `_pullFees`, which all five doors call first, then the migration tests, the invariant handler and a review of that path.
* recommendation: B. it matches the stated purpose, ends the wind down when the last statement sells, and keeps one engine buying at a time.

**OD-2, open, does not block the launch.** when to call `coin.lockAllowlist()` and `router.lock()` (NEXT item 19, after launch).

**intent gap, decision 47.** what "ready for when burn router and $balance drop" requires of the engine is not written down. the director drafts it from the v2 burn router source and brings the owner one question if a real choice remains.

## 5. evidence

`python3 script/director.py evidence` lists every record with its validity. what a new session must know:

* valid: the full suite and the deep invariants on 06009bd, carried to this branch by a record that shows the later diff under their scope is one comment line in test/utils/Fixture.sol.
* invalid: every independent review (source changed), the codex audit (outside main), the simulator's statement flow figures (they assume a paid composer, decision 41 removed the payment).
* unproved assumptions: a composer exists for every full page at no cost to the engine, the 90 day volume projection (1,961 eth, fitted to 13 measured days), the credit market price of 0.0089 eth, the seller book and the absence of competing bidders in the simulator.

## 6. next action

ask the owner OD-1. while waiting, build NEXT item 21 (the preflight row for `rateCap`) with its config test, the smallest test that covers it.

after that, in order: freeze the candidate (OD-1 settled, NEXT 21 built), run the full suite and the deep invariants on it, an independent security review of the candidate by a fresh reviewer, the system audit of the remaining required paths, the rehearsal from a clean checkout, the owner's launch steps.

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
