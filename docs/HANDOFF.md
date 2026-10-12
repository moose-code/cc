# handoff: credits engine

the baton for the session that directs this project next. read this file, then run `python3 script/director.py handoff` and read what it lists. the previous baton is `git show 2407087:docs/HANDOFF.md`.

## 1. where intent and evidence live

| source | role |
|---|---|
| AGENTS.md | precedence between the sources below |
| docs/ARCHITECTURE.md | the current reading of intent and of the system. section 1 "current intent at a glance" lists guarantees, behavior, parameters and accepted risks with their decision numbers and status |
| docs/FLOW.md | the dated owner decision log, decisions 1 to 71. a later dated decision supersedes an earlier one |
| docs/NEXT.md | the change list: decided, built, reviewed |
| project/director-state.json | the objective, open owner decisions, gates. `python3 script/director.py status` |
| project/evidence.json | the evidence ledger with the assumptions each record used. `python3 script/director.py evidence` |
| docs/REVIEW-*.md, docs/SIMULATION.md | evidence, each pinned to the commit it examined |
| docs/archive/ (SPEC, V2-PORT, BID-STUDY, V2-REQUESTS, the older reviews) | history, see docs/archive/README.md |

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
| phase | launch preparation. candidate 483be30 is frozen (`project/director-state.json`; Core runtime is identical to 97c1866). evidence exists for the full suite and the 7 Deep suites (97c1866, carried), the rehearsal (9ce8542, carried), the targeted runs at the tip, the security review and the acceptance of 0c3ecd2. the gate `independentReview` is red, section 5 lists what closes it |
| source | Core 18,462 bytes runtime (6,114 bytes of headroom), CoreLib 15,239, ControllerV1 7,463, CoreLens 6,492, measured after decision 71 |
| tests | the full suite at 97c1866: 995 passed, 0 failed, 8 skipped (docs/SUITE-97c1866.log). the 7 Deep suites at 97c1866 pass, 64 runs at depth 200 (docs/DEEP-RUN-97c1866.log). both are carried to 483be30. the diff 97c1866..483be30 holds `src/Core.sol` (comments, identical runtime bytecode), `script/Checks.sol` (metadata guard), `script/PostflightChecks.sol` (row text), `test/Config.t.sol`, `script/tools/check-preflight.sh` and documents. targeted runs at the tip 85d0c44: Config 32, BuildIdentity 5, PostflightSlots 8, ReviewDeploy 18, Resume 22, ReviewMatrix 11, Launch 16 and the Rehearsal test pass (E-TARGETED-483be30, outcome from the coordinator brief, no log file). the rehearsal of 9ce8542: preflight 115 of 116 after the owner command, postflight 96 of 96 (docs/REHEARSAL-97c1866.md) |
| reviews | full security review of 0c3ecd2 (docs/REVIEW-security-0c3ecd2.md: no critical, high or medium finding) and acceptance of decisions 1 to 71 and the 9 required paths at 0c3ecd2 (docs/ACCEPTANCE-0c3ecd2.md: ACCEPT). earlier: docs/REVIEW-security.md (1e2c4b3), docs/REVIEW-security-0d86ee7.md, docs/REVIEW-d77b82c.md, docs/ACCEPTANCE-50cec6f.md. docs/AUDIT-codex.md (commit 32ff35b) is on a branch outside main |
| launch prerequisite | the owner keeper, a separate project, ships before launch (FLOW 69, NEXT item 32). it is a backup for `buyListing`: outside bots are the primary callers (a caller is paid its gas at `min(basefee, keeperMaxBaseFee)` plus `keeperFee`, at most the bid minus the listing price, FLOW 71). the keeper acts only when a listing has sat below the bid for 3 minutes with nobody filling it (FLOW 74), simulates before it sends, and sends through a private relay (Flashbots Protect or MEV Blocker) so a lost race costs no gas |
| owner steps before launch | fund the owner address 0xCB43 (0.1264 eth at the rehearsal of 97c1866; the launch needs about 0.086 eth at 1 gwei and 0.15 eth at 5 gwei, and the balance covers the fee plus the measured gas up to a base fee of 3.47 gwei), run `setMinProtocolSkimShareBps(362)` on the v2 factory, then docs/DEPLOY.md with `--slow` (the owner address is an EIP 7702 delegated account) |

## 4. owner decisions

**OD-1, decided 2026-10-10 (FLOW 48).** the first `migrate` retires the old engine. `ethToBuyback` stays in it and its buyback burns it. the exit token pots move. built as NEXT item 22 at 74d1cbe, full suite 1078 pass, reviewed with no defect (docs/REVIEW-retire.md), follow ups built as NEXT item 23 at eff3051.

**OD-3, decided 2026-10-10 (FLOW 50).** `idleLoosenBps` 2_000 at launch and a lower bound of 1. built at dfd6001 (NEXT item 26). the launch value is 200 since FLOW 69 (NEXT item 32).

**OD-5, decided 2026-10-10 (FLOW 51).** buyback slice 0.5 eth at launch, upper bound 1 eth. built at dfd6001 (NEXT item 26).

**OD-4, decided 2026-10-10 (FLOW 52).** `xToBuyback` stays in the old engine on `migrate`. built at b2118fd (NEXT item 27).

**metadata, decided 2026-10-10 (FLOW 53, 54).** the name `CC` is final. `image` and `description` become launch config parameters, built at 70d88be (NEXT item 28). the owner supplies the image url and the description text before launch.

**scores, decided 2026-10-10 (FLOW 55).** the engine stops using credit scores everywhere, phase 2 included: per credit rates and a per credit exit unit. built at c8892a2 (NEXT item 29) and reviewed (docs/REVIEW-next29.md).

**removals, decided 2026-10-10 (FLOW 56).** built with NEXT item 29. **decision 58, decided 2026-10-10:** `sellForEth(ids)` without `minOut` stays and pays `min(price, pot)`. **OD-6, decided 2026-10-10 (FLOW 57):** `buyListing` stays; the owner's keeper is a fallback, built after launch.

**owner confirmations from the acceptance of 0c3ecd2, recorded in docs/ARCHITECTURE.md section 14.** items 47 (R1: one dump stalls buying for hours to days; the owner confirms the 50 percent minute floor of decision 69 or sets `dropFloorBps` higher), 48 (R2: statements bought above 1.33 times market stay unsold at the 75 percent floor; the owner confirms or lowers `saleFloorBps`), 49 (the reading of decision 67) and the L1 note on decision 71 (the fastest `buyListing` caller can take the whole gap between the bid and the listing price; the security review offers a target adapter as the other option). these are not in `ownerDecisions`; the gates do not wait for them.

**OD-2, open, does not block the launch.** when to call `coin.lockAllowlist()` and `router.lock()` (NEXT item 19, after launch). after `lockAllowlist`, `rescueCoin` reaches only addresses already listed.

**intent gap, decision 47.** what "ready for when burn router and $balance drop" requires of the engine is not written down. the director drafts it from the v2 burn router source and brings the owner one question if a real choice remains.

## 5. evidence

`python3 script/director.py evidence` lists every record with its validity. what a new session must know:

* gates green at the candidate 483be30: `focusedTests`, `localLifecycle`, `fullSuite` (E-SUITE-CARRY-483be30, E-DEEP-CARRY-483be30: the suite and the deep run of 97c1866, carried with the five changed files enumerated, backed by E-TARGETED-483be30), `deploymentRehearsal` (E-REHEARSAL-CARRY-483be30: the rehearsal of 9ce8542, carried; the corrected `docs/DEPLOY.md`, the metadata rows and the `check-preflight.sh` comments wait for a second walk) and `productRules` (E-ACCEPT-0c3ecd2, scope: the 30 files under `src`, `script` and `script/config` that are identical at 483be30).
* gate `independentReview` is red. E-REVIEW-SECURITY-0c3ecd2 is a valid review of the same 30 files. `src/Core.sol` (comments, identical runtime bytecode), `script/Checks.sol` (the L2 metadata guard fix) and `script/PostflightChecks.sol` (row text) changed in 483be30, and the checker carries a review only across unchanged scope. E-REVIEW-DELTA-483be30 is a director analysis of those three files, so E-REVIEW-CARRY-483be30 has kind analysis and review and the gate rejects it. a reviewer pass over `git diff 0c3ecd2 483be30 -- src script`, recorded as kind review with its report, closes the gate.
* required paths: 7 verified (fee-intake, credit-purchase, compose-and-listing, statement-sale-and-proceeds, phase2-exit on stand-ins, owner-powers-and-locks, migration-and-successor) from the path table of docs/ACCEPTANCE-0c3ecd2.md. launch-runbook (verified with gaps: owner inputs, the Deploy dry run balance row reading 0.07 to 0.08 eth high with unknown cause, the second walk of the corrected runbook) and participant-economics (a gap: no demand, price or composer evidence in the repository) stay in-progress.
* deliverables: candidate-suites, decision-audit and owner-decisions-settled verified; rehearsal, independent-security-review and intent-records in-progress. the objective stays active; completion is the owner's call.
* not verifiable from the repository: decision 47 (burn router readiness) and decision 57 (the owner keeper).
* invalid: every record of earlier candidates, and the leaf records of the carried runs (their scope changed; the carriers are valid).
* premise: A-OWNER-DECISIONS is v8 (decisions 1 to 71).
* migration gaps: no test migrates into a real second Core and runs `adopt` there, and `adopt` gives a migrated credit the successor's bid as its cost basis (the old basis is dropped).
* unproved assumptions: a composer exists for every full page at no cost to the engine, the 90 day volume projection (1,961 eth, fitted to 13 measured days), the credit market price of 0.0089 eth, the seller book and the absence of competing bidders in the simulator.

## 6. next action

launch day, in the order of docs/DEPLOY.md section 1. the owner sends every transaction.

1. step 1: copy the config to `script/config/local.json`, fill `image` and `description`, set `rateStart` from the credit price and `rateCap` to 3 times it.
2. fund the owner address 0xCB43 (section 3). no owner transaction between step 4 and the last step 6 transaction.
3. step 3: `setMinProtocolSkimShareBps(362)` on the v2 factory (owner command).
4. step 4: preflight at the latest block (`check-preflight.sh` with `FORK_BLOCK=<latest>` and no `IGNORE_BALANCE`); take `CONFIG_HASH` and `CONTROLLER_NONCE` from it.
5. step 5: Deploy dry run. step 6: `git checkout foundry.lock lib/solady`, `python3 script/director.py check --gate deploy` from the branch tip, then the Deploy broadcast with `--slow`.
6. steps 7 to 9: Resume, etherscan verify, Postflight; then `Lock.s.sol` and the section 4 duties.

open before step 6: a reviewer pass over the 483be30 delta (gate `independentReview`), the owner's confirmations of section 4, the owner keeper (section 3), the objective status (owner's call), and any change outside `docs/HANDOFF.md`, `project/director-state.json` and `project/evidence.json`, which needs a new freeze (`python3 script/director.py freeze <commit>`).

## 7. how to work in this repo

| topic | rule |
|---|---|
| naming | the phase 2 contracts are referred to only as `exitModule` and `exitToken` in code, comments, tests, docs and commit messages. never name or describe them |
| tests | mainnet fork tests pinned to block 26158000 (`FORK_BLOCK`), real contracts only, the live v2 stack included. the only doubles are test/standins and attacker contracts |
| toolchain | foundry 1.8.1 (isolate on), solc 0.8.30. forge 1.8.1 rewrites foundry.lock and bumps lib/solady on build: `git checkout foundry.lock lib/solady` before committing. a fresh worktree needs `git -C lib/v4-periphery submodule update --init lib/v4-core lib/permit2`. fork tests read `MAINNET_RPC_URL` and `FORK_BLOCK` from the environment: `set -a; source .env; set +a` |
| timings | clean build about 3 to 4 minutes, a test file change about 3 seconds, a `src/Core.sol` change about 35 seconds. full suite with `REHEARSAL=1 forge test -j 6` about 2 minutes on a 16 core machine (rerun rpc failures with `-j 1`). a Deep suite 577 to 692 seconds: `INVARIANT_DEEP=1 FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=200 forge test --match-contract '^<Suite>Deep$'` |
| verification | during an edit run the smallest test that covers it (`--match-path`). run one combined gate at a batch boundary. full suites, deep invariants and the rehearsal belong to a frozen candidate or to a gate whose evidence was invalidated. before a command over 30 seconds, say what it must establish |
| interfaces | after changing a production contract's external surface run `script/tools/gen-interfaces.sh` and repin test/BuildIdentity.t.sol. never import `src/Core.sol` in a test |
| Core size | 6,114 bytes of headroom after decision 71, margin rule at least 60. new logic goes into `CoreLib`. never drop a check to make room |
| safety | no mainnet broadcast, deploy, push or private key without the owner's explicit instruction |

## 8. known and not fixed

| item | detail |
|---|---|
| exitModule gas | `exitStatement` forwards gas to a contract that does not exist yet. measure it against the gas cap when it does |
| v2 audit | pending. preflight pins the code hash of nine live v2 contracts read at block 26158000. a changed stack means new addresses and pins |
| owner key | a stolen owner key moves everything at once (docs/ARCHITECTURE.md section 10). a multisig owner and watching `SuccessorSet` and `Migrated` are the mitigations |
