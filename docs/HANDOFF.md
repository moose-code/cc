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
| phase | launch preparation. candidate 6ea44f5 is frozen (`project/director-state.json`; src, script and config are those of 267139b, the last change since is test comments and documents). evidence records exist for every gate: the full suite and the 7 Deep suites (267139b, carried), the rehearsal (55a44ad, carried), the chain of independent reviews and the acceptances of decisions 1 to 78. the gates are green; the objective is the owner's sign-off |
| latest rehearsal | docs/REHEARSAL-267139b.md (candidate 267139b, branch tip 55a44ad, mainnet fork, nothing sent). it holds the measured figures: gas per transaction and total, block numbers, owner balance readings, config hashes, preflight and postflight row counts, the break-even base fee, and the corrected runbook lines. docs/DEPLOY.md states the procedure and the expected shape of each result, and names the latest record in one place (section 0, the signer row). a rehearsal therefore changes the record and leaves DEPLOY unchanged; the next rehearsal writes `docs/REHEARSAL-<candidate>.md` and the pointer moves at the next freeze. E-REHEARSAL-CARRY-6ea44f5 carries it to the candidate 6ea44f5 |
| source | Core 18,662 bytes runtime (5,914 bytes of headroom), CoreLib 17,089, ControllerV1 8,678 (with the pause of decision 81), CoreLens 6,492, FeeRouter 4,446, measured with `forge build --sizes`. the Core, CoreLib, CoreLens and FeeRouter build hashes in `script/Checks.sol` are unchanged by decision 81; the ControllerV1 hash and size are re-pinned. the pause is built and tested (`test/Pause.t.sol`, the sale invariant handler) and awaits an independent review and a new freeze |
| tests | the full suite at 267139b: 1011 passed, 0 failed, 8 skipped (docs/SUITE-267139b.log). the 7 Deep suites at 267139b pass, 64 runs at depth 200 (docs/DEEP-RUN-267139b.log). the rehearsal at 55a44ad: preflight 113 of 116 with exactly the three expected rows failing, the rehearsal test 115 of 116 after the owner command and postflight 96 of 96 after the launch and after the lock (docs/REHEARSAL-267139b.md). all three are carried to 6ea44f5, whose diff to 267139b holds two test files (comments) and documents |
| reviews | full security review of 0c3ecd2 (docs/REVIEW-security-0c3ecd2.md) and acceptance of decisions 1 to 71 and the 9 required paths (docs/ACCEPTANCE-0c3ecd2.md). delta reviews: 0c3ecd2..483be30 (docs/REVIEW-483be30.md), 483be30..45cfc62 (docs/REVIEW-security-45cfc62.md), 45cfc62..cb7cb9d (docs/REVIEW-cb7cb9d.md part 1), cb7cb9d..2b21fbf with the acceptance of decisions 72 to 75 (docs/REVIEW-2b21fbf.md), 2b21fbf..267139b with the acceptance of decisions 76 to 78 (docs/REVIEW-267139b.md). none of them is a human audit (decision 78). docs/AUDIT-codex.md (commit 32ff35b) is on a branch outside main |
| launch prerequisite | the owner keeper, a separate project, ships before launch (FLOW 69, NEXT item 32). it is a backup for `buyListing`: outside bots are the primary callers (a caller is paid its gas at `min(basefee, keeperMaxBaseFee)` plus `keeperFee`, at most the bid minus the listing price, FLOW 71). the keeper acts only when a listing has sat below the bid for 3 minutes with nobody filling it (FLOW 74), simulates before it sends, and sends through a private relay (Flashbots Protect or MEV Blocker) so a lost race costs no gas |
| owner steps before launch | fund the owner address 0xCB43 (the launch needs the factory fee of 0.069 eth plus gas; docs/REHEARSAL-267139b.md lists the funding needed at 1, 5 and 20 gwei and the base fee the current balance covers), run `setMinProtocolSkimShareBps(362)` on the v2 factory, then docs/DEPLOY.md with `--slow` (the owner address is an EIP 7702 delegated account) |

## 4. owner decisions

**OD-1, decided 2026-10-10 (FLOW 48).** the first `migrate` retires the old engine. `ethToBuyback` stays in it and its buyback burns it. the exit token pots move. built as NEXT item 22 at 74d1cbe, full suite 1078 pass, reviewed with no defect (docs/REVIEW-retire.md), follow ups built as NEXT item 23 at eff3051.

**OD-3, decided 2026-10-10 (FLOW 50).** `idleLoosenBps` 2_000 at launch and a lower bound of 1. built at dfd6001 (NEXT item 26). the launch value is 200 since FLOW 69 (NEXT item 32).

**OD-5, decided 2026-10-10 (FLOW 51).** buyback slice 0.5 eth at launch, upper bound 1 eth. built at dfd6001 (NEXT item 26).

**OD-4, decided 2026-10-10 (FLOW 52), superseded by decision 86.** the exit token dutch auction and its `xToBuyback` pot are removed. on `migrate` the old engine keeps `ethToBuyback` and `ethRedeemBurn` and the successor takes `xPot`, where all redeemed exit token now accumulates.

**metadata, decided 2026-10-10 (FLOW 53, 54).** the name `CC` is final. `image` and `description` become launch config parameters, built at 70d88be (NEXT item 28). the owner supplies the image url and the description text before launch.

**scores, decided 2026-10-10 (FLOW 55).** the engine stops using credit scores everywhere, phase 2 included: per credit rates and a per credit exit unit. built at c8892a2 (NEXT item 29) and reviewed (docs/REVIEW-next29.md).

**removals, decided 2026-10-10 (FLOW 56).** built with NEXT item 29. **decision 58, decided 2026-10-10:** `sellForEth(ids)` without `minOut` stays and pays `min(price, pot)`. **OD-6, decided 2026-10-10 (FLOW 57):** `buyListing` stays; the owner's keeper is a fallback, built after launch.

**goal risks of the acceptance of 0c3ecd2, decided 2026-10-11 and 2026-10-12.** R2 (statements bought above 1.33 times market stay unsold at the 75 percent floor) is decision 72, owner: "Accept". the `buyListing` tip gap (the fastest caller can take the whole gap between the bid and the listing price) is decision 73, owner: "Keep as is". R1 (one dump stalls buying) led to decisions 74, 75 and 77 (remembered peak, fast recovery climb, gap 1_000). the reading of decision 67 is ARCHITECTURE section 14 item 49.

**OD-2, open, does not block the launch.** when to call `coin.lockAllowlist()` and `router.lock()` (NEXT item 19, after launch). after `lockAllowlist`, `rescueCoin` reaches only addresses already listed.

**intent gap, decision 47.** what "ready for when burn router and $balance drop" requires of the engine is not written down. the director drafts it from the v2 burn router source and brings the owner one question if a real choice remains.

**phase 2 fit (owner information, 2026-10-12).** the exit side will wrap the redeem contract that burns a statement for an erc-20. owner: "it's not restricted ifaik. instant payout, yes". the payout arrives in the redeem transaction and the token is not transfer restricted, to the owner's knowledge. still to confirm from the contract source when it is published: a contract that owns the statement may redeem it, the token is a plain erc-20 (no fee on transfer, no rebase), its address is fixed, and the payout per statement has a known minimum (the module's `unitPerPoint`, times the statement's rating, is set at or below it). a fork test with a draft module follows once the source exists.

## 5. evidence

`python3 script/director.py evidence` lists every record with its validity. what a new session must know:

* gates green at the candidate 6ea44f5: `focusedTests`, `localLifecycle`, `fullSuite` (E-SUITE-CARRY-6ea44f5, E-DEEP-CARRY-6ea44f5: the suite and the deep run of 267139b, carried; the carried changes are test/Recovery.t.sol and test/RecoveryOracle.t.sol), `deploymentRehearsal` (E-REHEARSAL-CARRY-6ea44f5: the rehearsal of 55a44ad, docs/REHEARSAL-267139b.md, carried; the carried change is docs/DEPLOY.md, whose corrected text waits for a second walk), `independentReview` (E-REVIEW-CARRY-6ea44f5) and `productRules` (E-ACCEPT-CARRY-6ea44f5).
* review chain: each file under `src/**`, `script/*.sol`, `script/config/**` and `script/tools/**` is covered by the report backed review whose window holds its last change. 22 files by the review of 0c3ecd2, 1 by 0c3ecd2..483be30, 7 by 45cfc62..cb7cb9d, 1 by cb7cb9d..2b21fbf, 3 by 2b21fbf..267139b, none changed after 267139b. the review of 483be30..45cfc62 (E-REVIEW-45cfc62) covers no current file and is invalid. 6 files are outside every report of the chain: `script/config/v2-mainnet.json`, `src/interfaces/ArtCoinsV2.sol`, `src/interfaces/IFeeRouter.sol` and the tools `fix-interface.py`, `gen-interfaces.sh`, `guard-forge-test.sh`.
* acceptance chain: decisions 1 to 71 and the 9 paths at 0c3ecd2 (E-ACCEPT-0c3ecd2-KEPT), decisions 72 to 75 (E-ACCEPT-2b21fbf), decisions 76 to 78 (E-ACCEPT-267139b). the path table dates from 0c3ecd2; later changes to the bid rule are accepted decision by decision.
* required paths: 8 verified (fee-intake, credit-purchase, compose-and-listing, statement-sale-and-proceeds, phase2-exit on stand-ins, owner-powers-and-locks, migration-and-successor, launch-runbook). participant-economics is a gap in the acceptance report (no demand, price or composer evidence in the repository) and stays in-progress.
* deliverables: candidate-suites, rehearsal, independent-security-review, decision-audit and owner-decisions-settled verified; intent-records in-progress. the objective stays active; its completion is the owner's sign-off.
* the lows of the delta reviews are test and document items with fixes by commit message; the chain records them as dispositioned and does not recheck them line by line.
* not verifiable from the repository: decision 47 (burn router readiness) and decision 57 (the owner keeper).
* invalid: every record of earlier candidates, and the leaf records of the carried runs (their scope changed; the carriers are valid).
* premise: A-OWNER-DECISIONS is v9 (decisions 1 to 78). records of v8 and older are invalid on that ground as well.
* migration gaps: no test migrates into a real second Core and runs `adopt` there, and `adopt` gives a migrated credit the successor's bid as its cost basis (the old basis is dropped).
* unproved assumptions: a composer exists for every full page at no cost to the engine, the 90 day volume projection (1,961 eth, fitted to 13 measured days), the credit market price of 0.0089 eth, the seller book and the absence of competing bidders in the simulator.

## 6. next action

launch day, in the order of docs/DEPLOY.md section 1. the owner sends every transaction and each one is confirmed (receipt read, state read back) before the next command runs.

1. image and description: copy the config to `script/config/local.json` and fill `image` (an `ipfs://`, `https://`, `ar://` or `data:` url) and `description`. the metadata row of preflight fails until both hold real values.
2. `rateStart` at the market price of one credit on launch day and `rateCap` at 3 times it (DEPLOY section 1, the launch day rule). `recoveryGapBps` is 1_000 (decision 77).
3. funding: the owner address 0xCB43 holds the factory deploy fee plus gas (section 3). before the broadcast read `cast balance <owner> --rpc-url <rpc>` and compare it with the need of the step 4 balance row (DEPLOY step 5); the Deploy dry run balance row is not a funding check. no owner transaction between step 4 and the last step 6 transaction.
4. factory: `setMinProtocolSkimShareBps(362)` before the launch (step 3), `setMinProtocolSkimShareBps(1000)` after the last step 6 transaction, each confirmed with a read of `minProtocolSkimShareBps()`.
5. backup keeper: the owner keeper is running before the broadcast with the 3 minute delay and a private relay (Flashbots Protect or MEV Blocker). it is a separate project (section 3).
6. sign off and broadcast: preflight at the latest block (`check-preflight.sh` with `FORK_BLOCK=<latest>`, no `IGNORE_BALANCE`), take `CONFIG_HASH` and `CONTROLLER_NONCE`, the Deploy dry run, `git checkout foundry.lock lib/solady`, `python3 script/director.py check --gate deploy` from the branch tip, then the Deploy broadcast with `--slow` (the owner address is an EIP 7702 delegated account). then Resume, etherscan verify, Postflight (steps 7 to 9). the postflight row `controller: not paused` passes at launch: sales are open (decision 81).

after launch:

1. `Lock.s.sol` (`coin.lockRecipients()`, step 10).
2. the metadata renderer (DEPLOY section 4, the coin's metadata after launch).
3. the weekly slice check: the postflight and the pool depth against the buyback slice (DEPLOY section 4, watching the buyback after a price fall).
4. phase 2 per decision 82: `exitMode` is 0 at launch (the exit side off); the redemption policy is decided later. the exit side now prices each credit by its score (decision 84): the exit token bid pays per the credit's live score and a statement's redemption floor is its rating (the sum of its credits' scores) times `unitPerPoint`, after the slippage margin. turning it on is the DEPLOY runbook, section 4.
5. when the exit token's auction is announced: `setPaused(true)` on the controller, re-price with the live sale settings, `setPaused(false)` (DEPLOY section 4, when the exit token's auction is announced).
6. open and not blocking: decision 47 (burn router readiness) and OD-2 (`coin.lockAllowlist()` and `router.lock()`).

open before step 6: the owner keeper (section 3), the owner's sign-off on the objective, and any change outside `docs/HANDOFF.md`, `project/director-state.json` and `project/evidence.json`, which needs a new freeze (`python3 script/director.py freeze <commit>`). the engine launches on the AI-run reviews recorded in docs/ with no human audit (decision 78).

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
