# status

the baton for whoever directs this project next. read it first, then docs/SPEC.md. the authority order is AGENTS.md.

## 1. where we are

decisions 1 to 123 are settled (docs/DECISIONS.md; section 11 is the product agreement of 2026-10-13). decision 116 (2026-10-14) makes the eth bid per point (`ethRate() * score / refScore` per credit, the drop scaled, `refScore` the 25th Core setting, a `bidOf` view); decision 117 (2026-10-14) moves balance custody to the module (the Core holds no balance token, `balancePot`/`bookBalance` and the migrate balance leg removed, the module gains `available()`/`pay()`, the bid off is the accumulate mode); decision 118 (2026-10-14) adds the credit swap (`swapCredit(inId, outId)`, a pile credit for one of equal or higher score, `swapFeeCc` the 26th Core setting burned through the coin's `burnFrom`). they are built on branch `points/v1` and re-open the freeze (section 4): the full suite, the deep invariant and fuzz runs, the rehearsal and a review must run again on the new candidate. the simplification plan of docs/reviews/SIMPLIFICATION-v1.md ran on branch `simplify/v1` on 2026-10-13: every packet is merged; an independent Opus review of 63e011c found two highs (docs/reviews/REVIEW-security-opus-63e011c.md), fixed in 43c9f94 (decision 115); the local end to end on anvil and the web app (packets 12a to 12c) are merged; the candidate is c8b42d6 (section 4). the system is three contracts plus two adapters, deployed by nine CREATE2 transactions, with 445 tests that each name their promise. `main` holds the system before the plan; the owner decides the merge. decision 119 (2026-10-14) sets the launch values: credit sale on, 2,500 bps of sales to the buyback, swap fee 10,000 coins, keeper fee 0.0003 ether at a 5 gwei ceiling, `redeemOn` true, balance bid margin 9,000 bps, creditCostToPotBps 80 percent. decision 120 (2026-10-14) sets the fee split: skim 10 points of volume, bounty 9,000 of 10,000 to the engine (9.0 points), protocol 1,000 (1.0 point to artcoins), `payeePpm` 0 at launch (the setting stays for later), `minProtocolSkimShareBps` lowered to 1,000 at launch. decision 122 (2026-10-14) makes the balance token bid a second instance of the eth bid's price state (`CoreLib` refactored to one `Rate` struct and one set of climb and drop functions parameterised by unit, cap and floor): the balance bid climbs in bps of par, capped at 10,000 (never above par), floored at `10,000 - balanceBidMarginBps`, clamped to the module `available()`; views `balanceRate()` and `balanceBidOf(id)`, event `BalanceRateFill`; the eth bid is byte for byte unchanged. decision 123 (2026-10-14) takes the artist and operator cuts of nft sales off the top of a statement or credit sale payment (`saleToArtistBps` 250 and `saleToOperatorBps` 50, the 27th and 28th Core settings) and pushes them to the `artist` (a Core setting, `setArtist`) and the payee with `forceSafeTransferETH`; the controller royalty of decision 112 and the payee claim of decision 109 are removed, the payee fee share is pushed by the book, and `StatementSoldTo`, `CreditSold` and `FeesAdded` carry the pushed amounts.

measured on the branch tip against `main` (lines without the generated interfaces):

| | main | now |
|---|---|---|
| contract code | 3,248 | about 2,800 |
| tests | 35,515 lines, 1,011 tests | about 23,300 lines, 445 tests |
| scripts and tooling | 5,813 lines | about 3,000 |
| docs | 102 files, 3.3 MB | 6 living files plus docs/reviews and docs/notes |
| contracts | 5 | 3 plus 2 adapters |
| deploy transactions | 10 | 9 |

runtime sizes at the tip (limit 24,576): Core 21,531, CoreLib 14,495, ControllerV1 13,129, SeaportBasicAdapter 2,558, CreditStrategyAdapter 508. after decisions 116 and 117 (branch `points/v1`): Core 22,119, CoreLib 14,985, ControllerV1 13,138, adapters unchanged. after decision 118: Core 23,118, CoreLib 15,190, ControllerV1 13,167, adapters unchanged. after the credit sale floor dropped the flat floorRate term (part of decision 116): ControllerV1 13,056; after decision 121 (one rate decay): ControllerV1 12,443, the rest unchanged. after decision 122 (rising balance bid): Core 23,315, CoreLib 16,861, ControllerV1 12,443 unchanged. after decision 123 (the nft sale cuts, the forced pushes and the royalty removal): Core 23,613, CoreLib 17,147, ControllerV1 11,667. after the security and intent review fixes at ac8da10 (the balance floor revert, the same block return guard, the artist constructor argument, the per credit drop rounding, both instance checkpoints): Core 23,797, CoreLib 17,475, ControllerV1 11,667.

## 2. the plan

| # | packet | status |
|---|---|---|
| 0 | structural cleanup: SPEC, DECISIONS, STATUS, RUNBOOK, reviews/, notes/; logs, archive, the director ledger removed | done |
| 1 | rename exit to balance (decision 102) | done |
| 2 | the pause clock in the Core, O(1) | done |
| 3 | listing adapters replace measuring (decision 100), with the review fixes 3b | done |
| 4 | the Core as fee recipient, FeeRouter deleted (decision 109), with the review fixes 4b | done |
| 5 | pointRate and valueOf, unit live, one floor, two switches, feeToBuybackBps out, the royalty, the composer (decisions 104 to 107, 111, 112), with the review fixes 5b | done |
| 6a | statement formats (decision 113), with the review fixes | done |
| 6b | one State struct, CoreLens deleted, setSale and setCredit (decision 114) | done |
| 7 | CREATE2 deploy, preflight and postflight trimmed (118 and 73 rows), env vars trimmed, the script tests cut | done |
| 8 | the test cut: 983 to 452 tests, every survivor names its promise | done |
| 9 | the simulator follows | done |
| 10 | SPEC, RUNBOOK, INTEGRATION, README, AGENTS rewritten; comment references fixed; the simplification review archived | done |
| 11 | the freeze: full suite, deep runs, rehearsal, security review, acceptance | done on c8b42d6, section 4 |
| 11b | the two high findings of the independent review fixed (decision 115) | done |
| 12 | the local end to end on anvil (12a), the web app ported with a local mode (12b), the flywheel bar (12c), the browser run (docs/reviews/E2E-ecf51f3.md) | done |

## 3. open items

- the launch config's `image` and `description` are empty owner inputs; the preflight metadata row fails until they are filled with the final content.
- `coin.lockRecipients()` and `lockSuccessor()`: later owner decisions (RUNBOOK section 4, the lock table). `coin.lockAllowlist()`: the owner's.
- the owner keeper: post launch, a bounty bot (decision 100).
- the local seed gives a1 no CC and under a page of credits, so the restyle and the composes are driven by the scenario stages, not the UI; a seed change (one coin and 80 credits to a1) would close that.
- the flywheel presentation: a design brief for three directions was written on 2026-10-13; the current bar is the first draft.
- the balance module: written when the redeem contract is final (decision 101).
- artcoins master stack (46cec5be): integration packet after its mainnet deployment; the engine is pinned to the live stack until then.
- time-weighted price for the credit sale floor: the controller's `valueOf` pool term reads the pool spot price (`getSlot0`), so the credit sale floor `max(cost, valueOf(score)) * creditFloorBps` moves with the spot. the same block credit sale guard (`SameBlockReturn`) removes the atomic round trip against the engine's own balance bid; a multi block round trip remains priceable off a pushed pool (security review U1). a pool oracle hook or TWAP for the floor is the long-term fix.
- unmerged branches for the owner to keep or delete: claude/v1-ui-nextjs-web3-1d1637 (a Next.js frontend that read the deleted lens; it needs the multicall list of INTEGRATION section 2), feat/ui-anvil-local, feat/local-e2e, claude/repair-project-director-1366be, codex/independent-security-audit, codex/issue-3-spec.

## 4. the freeze table

`script/tools/check-freeze.sh` reads this table: the candidate row must equal `git rev-parse HEAD` and every row needs a commit and a result file that exists.

| gate | commit | result |
|---|---|---|
| candidate | ecf51f3 | the tip of simplify/v1 with every packet merged (src/ as of 43c9f94; the suite, deep and rehearsal records name c8b42d6, whose src/, script/ and test/ are identical: the commits between change docs and .claude/launch.json); the commits after it are docs only |
| full suite | c8b42d6 | docs/reviews/SUITE-c8b42d6.md |
| deep runs | c8b42d6 | docs/reviews/DEEP-c8b42d6.md |
| rehearsal | c8b42d6 | docs/reviews/REHEARSAL-c8b42d6.md |
| security review | 63e011c | docs/reviews/REVIEW-security-opus-63e011c.md |
| acceptance | b88940c | docs/reviews/ACCEPTANCE-b88940c.md |

the security review row is the independent Opus review; its two highs are fixed in 43c9f94 (decision 115), and the director review is docs/reviews/REVIEW-security-b88940c.md. the src/ of the candidate is 43c9f94 (the two fixes on top of b88940c and the comment edits of 086a946). the review and the acceptance examined the logic before the fixes; the fixes are the two lines they asked for, each with its regression test.

### the master stack exercise

the engine retargeted to the artcoins v2 stack at launcher commit `6d099486` (decision 126; `script/config/v2-master.json`), which re-opens the freeze against the new stack. the candidate exercise ran against the master stack fork fixture (`STACK=master`, the dump on chain id 31337, the scripts and suite re-entering chain id 1, the dev wallet the factory and engine owner) and is recorded in one file. the second candidate run at `eab58c7` is green on every gate:

| gate | result |
|---|---|
| full suite and the seven deep invariant suites | docs/reviews/STACK-master-6d099486.md, second run at eab58c7 (88 suites, 536 tests, 534 passed, 0 failed, 2 skipped, 886 s) |
| rehearsal | docs/reviews/STACK-master-6d099486.md, second run (1 passed, 3 s) |
| simulator parity | docs/reviews/STACK-master-6d099486.md, `node sim/engine.test.mjs` 1,804 checks |
| local end to end (PHASE=post) | docs/reviews/STACK-master-6d099486.md (passed, dev wallet the Core owner) |

the first run's two failures were fixed at the root at eab58c7 (`9fb6c65`): the pause-clock fuzz counterexample at age 17050 was a wrong expectation in the test (the price check used the statement cost, not the controller reference `max(valueOf(rating), cost)`; the age clock was correct), and the balance-bid `PotTooSmall` deep invariant was the handler's payable model, which now mirrors the `CoreLib._fillBalance` floor rule. the engine `src/` is byte for byte unchanged; only the three test files changed, each with a unit test for the exact state. `v2-mainnet.json` stays only as the record of the superseded live stack, whose old ABI the engine no longer targets.

## 5. how to work in this repo

| topic | rule |
|---|---|
| naming | "balance", never "exit", in code, comments, tests and docs (decision 102) |
| tests | mainnet fork pinned to block 26158000 (`FORK_BLOCK`), real contracts only, the two stand ins are the balance module and the balance token. every kept test carries a `// promise:` line |
| toolchain | foundry 1.8.1 (isolate on), solc 0.8.30. forge 1.8.1 rewrites foundry.lock and bumps lib/solady on build: `git checkout foundry.lock; git submodule update -- lib/solady` before committing. a fresh worktree needs the nested uniswap submodules: `git -C lib/v4-periphery submodule update --init lib/v4-core lib/permit2`, or an rsync of them from a checkout that has them |
| fork env | `set -a; source <a .env with MAINNET_RPC_URL and FORK_BLOCK>; set +a` before fork tests; this repo tracks only .env.example |
| timings | clean build 3 to 4 minutes, a test file change seconds, a src/Core.sol change about 40 seconds. a test file about 10 to 60 seconds. a Deep suite 10 to 15 minutes |
| verification | during an edit run the smallest test that covers it (`--match-path`). the full suite, the deep invariants and the rehearsal belong to the frozen candidate, marked `CANDIDATE_RUN=1`; the hook in .claude/settings.json refuses a whole suite run without it |
| interfaces and pins | after changing a production contract's external surface run `script/tools/gen-interfaces.sh` and re-pin test/BuildIdentity.t.sol and script/Checks.sol. never import src/Core.sol in a test |
| Core size | 3,045 bytes of headroom at the tip; new logic goes into CoreLib; never drop a check to make room |
| safety | no mainnet broadcast, deploy, push to main, merge or private key without the owner's explicit instruction |

## 6. known and not fixed

| item | detail |
|---|---|
| balance module gas | `redeemStatement` forwards gas to a contract that does not exist yet; measure it against `REDEEM_GAS` when it does |
| v2 audit | the engine targets the master v2 stack `6d099486` (decision 126). preflight pins its code hashes and constantsHash (`script/LaunchConfig.sol`, `script/config/v2-master.json`); the stack is not yet on mainnet, so the fixture is a fork deployment and a mainnet stack means new addresses and pins |
| owner key | a stolen owner key moves everything at once (docs/SPEC.md section 11). a multisig owner and watching `SuccessorSet` and `Migrated` are the mitigations |
| rehearsal gas estimate | `DEPLOY_GAS_ESTIMATE` 22,000,000 covers 19,069,638 gas measured on the master stack fixture with eleven transactions (the coin renderer and `setCore` added, decision 127); the freeze re-measures it |
