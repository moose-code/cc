# status: credits engine

the live state of the project. the rules and the system are in docs/SPEC.md, the owner decisions in docs/DECISIONS.md, the launch commands in docs/RUNBOOK.md. precedence between sources: AGENTS.md.

## 1. where we are

decisions 1 to 112 are settled. the simplification plan of docs/SIMPLIFICATION-v1.md was approved on 2026-10-13 and is built as the packets of section 2 on the branch `simplify/v1`. packet 0 (the structural cleanup: five living documents, `docs/reviews/`, `docs/notes/`, the freeze table and `script/tools/check-freeze.sh`), packet 1 (the rename of exit to balance, decision 102) and packet 2 (the pause clock in the Core: `paused`, `pausedSince`, `pausedTotal`, a `pauseMark` per Statement, `statementAge`) are done. the build pins in `script/Checks.sol` and `test/BuildIdentity.t.sol` were re-pinned by packets 1 and 2. nothing is deployed and the engine is unaudited.

## 2. the plan

each packet is one builder, bounded to the files it names, with `forge build` and `forge test --match-path` on the tests it touches and one independent review of the commit. the full suite, the deep runs and the rehearsal run once, at the freeze (packet 11).

| # | packet | removes | depends on | status |
|---|---|---|---|---|
| 0 | structural cleanup | logs, archive, the director ledger and `script/director.py` (1,782 LOC of python), the old document names | none | done |
| 1 | rename exit to balance (decision 102) | the old vocabulary | 0 | done |
| 2 | pause clock into the Engine, O(1) | the window array, the controller pause | 1 | done |
| 3 | listing adapters, measuring out (decision 100) | the measuring flag, `BadCost`, raw calldata, `Measuring` in receive | 1 | pending |
| 4 | the Engine as bounty recipient: `receive` open to the hook only, `_book`, payee ppm claim, sniper latch from the factory record, `COIN` from `predictToken` in the constructor, `fund`, `collectEscrow`; `skim` and FeeRouter deleted | FeeRouter, flush, pullFees, skim, Resume, split start, V2R-1 | 3 | pending |
| 5 | `pointValue`, unit live, one floor, `feeToBuybackBps` out, two balance switches (decisions 104 to 107), the royalty on the controller and the composer on the record (decisions 111 and 112), settings recount and bounds | the value floor, baseline, backstop, stored unit, refresh, `floorBps`, `balanceMode` | 1 | pending |
| 6 | one `State` struct; CoreLens deleted; the bid quote view after pending income | CoreState, fixed slots, the lens, 8 postflight rows | 4, 5 | pending |
| 7 | CREATE2 deploy, `setController` before launch, preflight and postflight trimmed, env vars trimmed, the Lock run becomes a later owner command | nonce pinning, Resume, config echo rows | 6 | pending |
| 8 | tests follow: delete the files of SIMPLIFICATION-v1 section 5, rewrite fixtures to the five transaction deploy, invariants 15 and 20 out, 10 restated, gas rows re-measured | about 5,000 LOC | 7 | pending |
| 9 | sim follows: the fee fraction without a router, `pointValue`; the page kept (the pause clock is done in packet 2) | none | 5 | pending |
| 10 | docs content rewrite: SPEC, RUNBOOK, INTEGRATION, README and STATUS describe the built design; `src/` comments naming old paths fixed and the build pins re-pinned; the UI branch's one lens read replaced by a multicall | the stale text of the old design | 8 | pending |
| 11 | freeze: full suite, the deep runs, the rehearsal on the latest block, a security review of the candidate, the acceptance of decisions 99 to 108; section 4 filled | none | all | pending |

## 3. open items

* the owner keeper, a separate project that ships after launch: a backup caller for the listing door. outside bots are the primary callers.
* OD-2: when to call `coin.lockAllowlist()`. after it, `rescueCoin` reaches only addresses already listed. it does not block the launch.
* six unmerged branches for the owner to keep or delete: `claude/v1-ui-nextjs-web3-1d1637`, `feat/ui-anvil-local`, `feat/local-e2e`, `claude/repair-project-director-1366be`, `codex/independent-security-audit`, `codex/issue-3-spec`.

## 4. the freeze table

`script/tools/check-freeze.sh` reads this table. the candidate row holds the frozen commit, which must equal `git rev-parse HEAD`, and its result cell is not read. every other row holds the commit its run examined (7 to 40 hex characters) and the path of its result file in this tree. the script exits 1 while any checked cell is `pending`.

| gate | commit | result |
|---|---|---|
| candidate | pending | pending |
| full suite | pending | pending |
| deep runs | pending | pending |
| rehearsal | pending | pending |
| security review | pending | pending |
| acceptance | pending | pending |

## 5. how to work in this repo

| topic | rule |
|---|---|
| naming | the vocabulary is "balance", never "exit" (decision 102). code, comments, tests and docs name the balance side contracts `balanceModule` and `balanceToken` |
| tests | mainnet fork tests pinned to block 26158000 (`FORK_BLOCK`), real contracts only, the live v2 stack included. the only doubles are test/standins and attacker contracts |
| toolchain | foundry 1.8.1 (isolate on), solc 0.8.30. forge 1.8.1 rewrites foundry.lock and bumps lib/solady on build: `git checkout foundry.lock lib/solady` before committing. a fresh worktree needs `git -C lib/v4-periphery submodule update --init lib/v4-core lib/permit2`. fork tests read `MAINNET_RPC_URL` and `FORK_BLOCK` from the environment: `set -a; source .env; set +a` |
| timings | clean build about 3 to 4 minutes, a test file change about 3 seconds, a `src/Core.sol` change about 35 seconds. full suite with `REHEARSAL=1 forge test -j 6` about 2 minutes on a 16 core machine (rerun rpc failures with `-j 1`). a Deep suite 577 to 692 seconds: `INVARIANT_DEEP=1 FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=200 forge test --match-contract '^<Suite>Deep$'` |
| verification | during an edit run the smallest test that covers it (`--match-path`). run one combined gate at a batch boundary. full suites, deep invariants and the rehearsal belong to a frozen candidate or to a gate whose evidence was invalidated. before a command over 30 seconds, say what it must establish |
| interfaces | after changing a production contract's external surface run `script/tools/gen-interfaces.sh` and repin test/BuildIdentity.t.sol. never import `src/Core.sol` in a test |
| Core size | 6,095 bytes of headroom at 3a484a4, margin rule at least 60. new logic goes into `CoreLib`. never drop a check to make room |
| safety | no mainnet broadcast, deploy, push or private key without the owner's explicit instruction |
| fork env | `set -a; source <path to a .env with MAINNET_RPC_URL and FORK_BLOCK>; set +a` before fork tests; this worktree has none, the owner's lives outside it |

pre-existing failures found by packet 1 (they fail at main 35b78be too, before any change of this branch): `test/Lifecycle.t.sol` `test_narrative_theWholeLoopTwice`, `test_compose_unsoldStatementStaysHeldAtTheFloor`, `test_narrative_theOwnerAdaptsTheSystemLive`, and `test/SaleSmoke.t.sol` `test_price_falls_to_the_knee_then_to_the_floor`: sale price assertions. packet 5 (the pricing changes) must leave them green or delete them with a reason.

also pre-existing at main: `test/invariant/ComposeHostileNotReady.t.sol` calls `nextPage(uint8)` while the fuzz controller has `nextPage()` (stale since the single pile, decision 92); packet 8 fixes it. `test/Rehearsal.t.sol` compares the deploy gas with `DEPLOY_GAS_ESTIMATE` (19,200,000), which the adapter transactions of packet 3 exceed; packet 7 re-measures the deploy and sets the constant.

## 6. known and not fixed

| item | detail |
|---|---|
| balanceModule gas | `redeemStatement` forwards gas to a contract that does not exist yet. measure it against the gas cap when it does |
| v2 audit | pending. preflight pins the code hash of nine live v2 contracts read at block 26158000. a changed stack means new addresses and pins |
| owner key | a stolen owner key moves everything at once (docs/SPEC.md section 10). a multisig owner and watching `SuccessorSet` and `Migrated` are the mitigations |
