# status: credits engine

the live state of the project. the rules and the system are in docs/SPEC.md, the owner decisions in docs/DECISIONS.md, the launch commands in docs/RUNBOOK.md. precedence between sources: AGENTS.md.

## 1. where we are

decisions 1 to 113 are settled. the simplification plan of docs/SIMPLIFICATION-v1.md was approved on 2026-10-13 and is built as the packets of section 2 on the branch `simplify/v1`. packet 0 (the structural cleanup: five living documents, `docs/reviews/`, `docs/notes/`, the freeze table and `script/tools/check-freeze.sh`), packet 1 (the rename of exit to balance, decision 102), packet 2 (the pause clock in the Core: `paused`, `pausedSince`, `pausedTotal`, a `pauseMark` per Statement, `statementAge`) packet 6a (statement formats, decision 113) and packets 3, 3b, 4 and 4b (the listing adapters; the Core as the pool's fee recipient with `_book`, `fund`, `collectEscrow`, `claimPayee` and `bookBalance`; the FeeRouter deleted; `payeePpm` 75,185) and packet 5 (`pointRate` and `valueOf`, the unit read live, one floor on `saleFloorBps`, `feeToBuybackBps` out, `redeemOn` and `balanceBidOn`, the royalty on the controller, `composerOf` on the Core) are done. the build pins in `script/Checks.sol` and `test/BuildIdentity.t.sol` were re-pinned by packets 1, 2, 5, 5b and 6a and by the merges of packets 5, 3 and 4. nothing is deployed and the engine is unaudited.

## 2. the plan

each packet is one builder, bounded to the files it names, with `forge build` and `forge test --match-path` on the tests it touches and one independent review of the commit. the full suite, the deep runs and the rehearsal run once, at the freeze (packet 11).

| # | packet | removes | depends on | status |
|---|---|---|---|---|
| 0 | structural cleanup | logs, archive, the director ledger and `script/director.py` (1,782 LOC of python), the old document names | none | done |
| 1 | rename exit to balance (decision 102) | the old vocabulary | 0 | done |
| 2 | pause clock into the Engine, O(1) | the window array, the controller pause | 1 | done |
| 3 | listing adapters, measuring out (decision 100) | the measuring flag, `Measuring` in receive, raw calldata and the target list (packet 3b adds the Seaport recipient allowlist and `lockAdapters`) | 1 | done |
| 4 | the Engine as bounty recipient: `receive` open to the hook only, `_book`, payee ppm claim, sniper latch from the factory record, `COIN` from `predictToken` in the constructor, `fund`, `collectEscrow`; `skim` and FeeRouter deleted | FeeRouter, flush, pullFees, skim, the split start and the Resume split step, V2R-1 (packet 4b: the postflight prints the coin constructor argument, `migrate` falls back to a plain send, `setSettings` and `sellForBalance` book first) | 3 | done |
| 5 | `pointValue`, unit live, one floor, `feeToBuybackBps` out, two balance switches (decisions 104 to 107), the royalty on the controller and the composer on the record (decisions 111 and 112), settings recount and bounds | the value floor, baseline, backstop, stored unit, refresh, `floorBps`, `balanceMode` | 1 | done |
| 6 | one `State` struct; CoreLens deleted; the bid quote view after pending income; statement formats (decision 113: `compose(format)`, random default, `setHeldFormat`, `minCcToChoose` 1 coin) | CoreState, fixed slots, the lens, 8 postflight rows | 4, 5 | done in 6a and 6b |
| 6b | one `State` struct (`CoreState`, `SettingsStore` and `RateStore` gone), `CoreLens` deleted, the controller's per field setters replaced by `setSale(Sale)` and `setCredit(CreditSale)` (decision 114), invariant 6 model includes the pending pot share | CoreState, fixed slots, the lens, 14 controller setters | 4, 5 | done |
| 6a | statement formats (decision 113): `compose(format)`, a random default from `prevrandao` and the head id, `setHeldFormat`, `minCcToChoose` 1 coin at launch | none | 5 | done |
| 7 | CREATE2 deploy, `setController` before launch, preflight and postflight trimmed, env vars trimmed, the Lock run becomes a later owner command | nonce pinning, Resume, config echo rows | 6 | done: nine transactions (the library, Core, controller, the two adapters, `setController`, `addAdapter` for each adapter, the launch), 16,120,826 gas measured and `DEPLOY_GAS_ESTIMATE` 18,600,000; 116 preflight rows and 70 postflight rows on the fixture, 6 `build:` rows |
| 8 | the test cut: a test stays only when it names the promise it protects (a docs/SPEC.md section 1 row, a docs/INTEGRATION.md revert or an invariant); the reviewer era files, narratives and duplicate cases are deleted and a survivor carries a `// promise:` line. test/**/*.sol before and after: 94 to 75 files (test/*.sol 56 to 39), 34,964 to 23,432 lines, 983 to 452 test functions; the 12 files of packet 7 (4,474 lines, 130 test functions) are untouched. the 20 invariants, 9 suites and 7 Deep variants are kept | 11,532 lines, 531 test functions | 7 | done |
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
| Core size | 21,531 bytes of runtime code after the merge of packet 7, 3,045 bytes of headroom, margin rule at least 60. new logic goes into `CoreLib`. never drop a check to make room |
| safety | no mainnet broadcast, deploy, push or private key without the owner's explicit instruction |
| fork env | `set -a; source <path to a .env with MAINNET_RPC_URL and FORK_BLOCK>; set +a` before fork tests; this worktree has none, the owner's lives outside it |

`test/Lifecycle.t.sol` and `test/SaleSmoke.t.sol`, which held four failures at main 35b78be, were deleted by packet 8.

## 6. known and not fixed

| item | detail |
|---|---|
| balanceModule gas | `redeemStatement` forwards gas to a contract that does not exist yet. measure it against the gas cap when it does |
| v2 audit | pending. preflight pins the code hash of nine live v2 contracts read at block 26158000. a changed stack means new addresses and pins |
| invariant 6 flake | `invariant_06_rateFollowsTheModel` fails in some runs of `InvariantsSalePhase2` in `test/invariant/InvariantsSale.t.sol` (shrunk sequence: `setSettings`, `setRate`, `sellForEth`, `donate`, `composeChosen`) with "the read differs from the price state lowered to the clamp of the end pot: 1 != 0". it fails at d100be9 too (three of three runs there), so packet 8 did not cause it. the cause is open: a model edge in the handler or a one wei edge in the read |
| owner key | a stolen owner key moves everything at once (docs/SPEC.md section 10). a multisig owner and watching `SuccessorSet` and `Migrated` are the mitigations |
