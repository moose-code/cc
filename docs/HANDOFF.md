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
| phase | launch preparation. candidate 0c3ecd2 is frozen (`project/director-state.json`; its src and tests are those of 97c1866). evidence records exist for the full suite and the 7 Deep suites (97c1866, carried), the rehearsal (9ce8542, carried) and the reviews of the source in five windows. the gates `productRules` and `independentReview` are red, section 5 lists what closes them |
| source | Core 18,462 bytes runtime (6,114 bytes of headroom), CoreLib 15,239, ControllerV1 7,463, CoreLens 6,492, measured after decision 71 |
| tests | the full suite at 97c1866: 995 passed, 0 failed, 8 skipped (docs/SUITE-97c1866.log). the 7 Deep suites at 97c1866 pass, 64 runs at depth 200 (docs/DEEP-RUN-97c1866.log). both are carried to 0c3ecd2, whose diff to 97c1866 holds documents and `script/tools/check-preflight.sh`. the rehearsal test: preflight 115 of 116 after the owner command, postflight 96 of 96 after the launch and after the lock (docs/REHEARSAL-97c1866.md) |
| reviews | security review of 1e2c4b3 (docs/REVIEW-security.md), of 14c6306..0d86ee7 (docs/REVIEW-security-0d86ee7.md), of 0d86ee7..d77b82c (docs/REVIEW-d77b82c.md), of d77b82c..50cec6f with the acceptance of decisions 42 to 70 at 50cec6f (docs/ACCEPTANCE-50cec6f.md), and of efd4656..97c1866 (decision 71; the verdict is recorded in `project/evidence.json`, the report file is missing from the repository). docs/AUDIT-codex.md (commit 32ff35b) is on a branch outside main |
| launch prerequisite | the owner keeper, a separate project, ships before launch (FLOW 69, NEXT item 32). it is a backup for `buyListing`: outside bots are the primary callers (a caller is paid its gas at `min(basefee, keeperMaxBaseFee)` plus `keeperFee`, at most the bid minus the listing price, FLOW 71). the keeper acts only when a listing has sat below the bid for 10 minutes with nobody filling it, simulates before it sends, and sends through a private relay (Flashbots Protect or MEV Blocker) so a lost race costs no gas |
| owner steps before launch | fund the owner address 0xCB43 (0.1264 eth at the rehearsal of 97c1866; the launch needs about 0.086 eth at 1 gwei and 0.15 eth at 5 gwei, and the balance covers the fee plus the measured gas up to a base fee of 3.47 gwei), run `setMinProtocolSkimShareBps(362)` on the v2 factory, then docs/DEPLOY.md with `--slow` (the owner address is an EIP 7702 delegated account) |

## 4. owner decisions

**OD-1, decided 2026-10-10 (FLOW 48).** the first `migrate` retires the old engine. `ethToBuyback` stays in it and its buyback burns it. the exit token pots move. built as NEXT item 22 at 74d1cbe, full suite 1078 pass, reviewed with no defect (docs/REVIEW-retire.md), follow ups built as NEXT item 23 at eff3051.

**OD-3, decided 2026-10-10 (FLOW 50).** `idleLoosenBps` 2_000 at launch and a lower bound of 1. built at dfd6001 (NEXT item 26). the launch value is 200 since FLOW 69 (NEXT item 32).

**OD-5, decided 2026-10-10 (FLOW 51).** buyback slice 0.5 eth at launch, upper bound 1 eth. built at dfd6001 (NEXT item 26).

**OD-4, decided 2026-10-10 (FLOW 52).** `xToBuyback` stays in the old engine on `migrate`. built at b2118fd (NEXT item 27).

**metadata, decided 2026-10-10 (FLOW 53, 54).** the name `CC` is final. `image` and `description` become launch config parameters, built at 70d88be (NEXT item 28). the owner supplies the image url and the description text before launch.

**scores, decided 2026-10-10 (FLOW 55).** the engine stops using credit scores everywhere, phase 2 included: per credit rates and a per credit exit unit. built at c8892a2 (NEXT item 29) and reviewed (docs/REVIEW-next29.md).

**removals, decided 2026-10-10 (FLOW 56).** built with NEXT item 29. **decision 58, decided 2026-10-10:** `sellForEth(ids)` without `minOut` stays and pays `min(price, pot)`. **OD-6, decided 2026-10-10 (FLOW 57):** `buyListing` stays; the owner's keeper is a fallback, built after launch.

**OD-2, open, does not block the launch.** when to call `coin.lockAllowlist()` and `router.lock()` (NEXT item 19, after launch). after `lockAllowlist`, `rescueCoin` reaches only addresses already listed.

**intent gap, decision 47.** what "ready for when burn router and $balance drop" requires of the engine is not written down. the director drafts it from the v2 burn router source and brings the owner one question if a real choice remains.

## 5. evidence

`python3 script/director.py evidence` lists every record with its validity. what a new session must know:

* gates green at the candidate 0c3ecd2: `focusedTests`, `localLifecycle`, `fullSuite` (E-SUITE-CARRY-0c3ecd2, E-DEEP-CARRY-0c3ecd2: the suite and the deep run of 97c1866, carried; the carried change is `script/tools/check-preflight.sh`) and `deploymentRehearsal` (E-REHEARSAL-CARRY-0c3ecd2: the rehearsal of 9ce8542, carried; the carried changes are the corrected `docs/DEPLOY.md` text and the header comment of `script/tools/check-preflight.sh`, which wait for a second walk).
* gate `independentReview` is red. E-REVIEW-CARRY-0c3ecd2 chains the reviews by window: each source file is covered by the review whose window holds its last change. 19 of the 36 files under `src/**`, `script/*.sol` and `script/config/**` are covered by report backed reviews (1e2c4b3: 8 files, d77b82c: 8, 50cec6f: 3). 11 files last changed in 97c1866 (Core, CoreLib, ICore, Interfaces, SettingsBounds, Checks, LaunchConfig, SetSettings, SettingsFields, mainnet.json, rehearsal.json) have the review of efd4656..97c1866 as their only review, and its report file is missing, so the record is kind analysis and the gate rejects it. 6 files wait for a review of their current content: `script/Deploy.s.sol`, `Preflight.s.sol`, `Resume.s.sol` and `SystemDeployer.sol` (last changed in 14c6306, the fixes for the findings of 1e2c4b3) and `script/PostflightPool.sol` and `Report.sol` (listed as not examined in docs/REVIEW-security.md). to close the gate: commit the report of the efd4656..97c1866 review, record it as kind review with its sha256, review the 6 files, replace the analysis link in the chain.
* gate `productRules` is red. E-ACCEPT-50cec6f (docs/ACCEPTANCE-50cec6f.md) accepts the code at 50cec6f for decisions 42 to 70 with result findings: L1 (the anchor pumped at a priced cost, an accepted risk of decision 68), L2 (the metadata guard is a marker test), D1 to D7 (document mismatches), C1 (decision 67 words) and C2 (the value of `anchorMinCost`) are open, E1 (no deep run at 50cec6f) is closed by the deep run of 97c1866. decision 71 and its 11 files are covered by the review of efd4656..97c1866 and by no acceptance. decisions 1 to 41 are outside any valid acceptance.
* the system audit path by path (E-AUDIT-SYSTEM-eff3051) is invalid since the sale, bid and keeper changes. the 9 required paths of the objective stay in-progress until it is redone.
* invalid by design: E-REVIEW-0d86ee7 (every file of its delta changed again, the later windows hold the review), the leaf records E-SUITE-97c1866 and E-REHEARSAL-9ce8542 (the carried scope changed; the carriers are valid), and every record of the older candidates.
* premise: A-OWNER-DECISIONS is v8 (decisions 1 to 71). records of v7 and older are invalid on that ground as well.
* migration gaps: no test migrates into a real second Core and runs `adopt` there, and `adopt` gives a migrated credit the successor's bid as its cost basis (the old basis is dropped).
* unproved assumptions: a composer exists for every full page at no cost to the engine, the 90 day volume projection (1,961 eth, fitted to 13 measured days), the credit market price of 0.0089 eth, the seller book and the absence of competing bidders in the simulator.

## 6. next action

1. the owner decides C1 and C2 of docs/ACCEPTANCE-50cec6f.md and the dispositions of L2 and D1 to D7.
2. commit the report of the efd4656..97c1866 review and record it as kind review. review the 6 files listed in section 5. acceptance for the decision 71 changes.
3. redo the system audit path by path against the candidate, then set the 9 required paths.
4. any change to `docs/ARCHITECTURE.md` or another file outside `docs/HANDOFF.md`, `project/director-state.json` and `project/evidence.json` needs a new freeze (`python3 script/director.py freeze <commit>`). the edit of this turn to section 1 of `docs/ARCHITECTURE.md` is such a change.
5. `project/director-state.json` field `nextAction` still names the rehearsal and is replaced by item 1 at the next freeze.
6. then `python3 script/director.py check --gate deploy` from the branch tip and the owner's launch steps.

owner inputs before launch: the coin's image url and description (config), funding the owner address (0.1264 eth held at the rehearsal, the need is about 0.07 eth at the live base fee and 0.15 eth at 5 gwei; no owner transaction between preflight and the last deploy transaction: the deploy checks `CONTROLLER_NONCE`), `setMinProtocolSkimShareBps(362)` on the factory, the launch day `rateStart` and `rateCap` (3 times `rateStart`, FLOW 69) from the credit price, and the owner keeper (section 3, launch prerequisite).

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
