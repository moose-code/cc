# Audit of ripe0x/cc at main 84ea170

Independent whole-system audit from a fresh clone, 2026-10-19. No production contract was changed by this audit; no
mainnet transaction was sent; every broadcast went to a local Anvil fork. The supporting records are in
docs/reviews/audit-84ea170/ (one file per area, each written from current source and runtime behavior, none from a prior review).

## 1. Pinned revision and environment

| item | value |
|---|---|
| commit | `84ea170ab3330a4163ef8ac00cb5fa2cd067fe09` (origin/main, 2026-10-18, merge of PR 110) |
| toolchain | forge 1.8.1 (982849d3), anvil 1.8.1, solc 0.8.30, node 22.22.0, npm 10.9.4 |
| compiler settings | foundry.toml: default profile cancun, optimizer 200, bytecode_hash none; production contracts (`src/[A-Z]*.sol`, CoreLib, CoreOpsLib, CreditDrawing, adapters) on the `viair` profile: via_ir, optimizer 200 |
| dependencies | forge-std f3dae6e (v1.17.0), solady d07f92e (v0.1.25), v4-periphery ad04c9f, v4-core 59d3ecf, permit2 cc56ad0 |
| clean build | 7m00s; Core 23,674 bytes (902 under EIP-170), CoreLib 23,635 (941), CoreOpsLib 3,378, ControllerV1 17,189, LogoCoinRenderer 4,464, SeaportBasicAdapter 2,536, CreditStrategyAdapter 534 |
| deployment config | script/config/mainnet.json: owner, creator, payee 0xCB43078C32423F5348Cab5885911C3B5faE217F9; artist 0xc8f8e2f59dd95ff67c3d39109eca2e2a017d4c8a; rateStart 4.9e15, rateCap 1.47e16; skim 690 bps, bounty 9,000, sniper 9,000 over 1,800 s; supply 1e27; CONFIG_HASH 0xb3d6cfc400e5305238201e2841401f90e83d07d0e33b71b8a4421feb80f967a7 |
| live stack | factory 0xC27e182ef5D8A1A7C9dd0a27414fEaBA47DF8e3c (deployed at block 26202473), hook 0x866F3156..., locker 0xbD049E96..., escrow 0xB65816a3..., mev 0x32Ab8Ec0..., tokenDeployer 0x99EB38d6..., feeController 0xbD5A853f...; code hashes and treasury match the pins in script/config/v2-mainnet.json at head 26223305 |
| fork for tests | anvil fork of https://eth.drpc.org at block 26222700 (`MAINNET_RPC_URL=http://127.0.0.1:8545`, `FORK_BLOCK=26222700`, `forge test --chain-id 1`) |
| fork for the lifecycle | anvil chain id 1 fork of the same RPC at block 26208025 (script/dev/e2e-real.sh default) |
| Jack's token | jckbtchr-vv/credits at 9318c713974ee18658ac5aeddab45f0e1e45b585, built with script/tools/upstream-balance.sh; creation sha256 and the three runtime hashes equal the pins (an `xxd -r -p` shim was needed; the container has no xxd) |
| predicted launch addresses (mainnet.json) | CoreLib 0xFae5939A144409a2bCa8B60f94dbd5a7b94bf01F, CoreOpsLib 0xAbcfEE48bA34760420B068BE28a15a886C574DF1, Core 0xA66dbb50B9D6622233F195C4d795EAA2abD59116, controller 0x7b48F47F272E392f27A76E222a168D55D39AEb97, Seaport adapter 0x22C6De3380dA5bF52B19c84efD225768BFfeD466, strategy adapter 0x5757788D0A6dF507dba064d66532F0b630Be1dc9, renderer 0x0D2022F8D780884A1B46de156CBfc4f36423504c, coin 0x696f4dC78F29dd14Ad3CbD5153BbbbC5dC661b5c; all empty at 26222700 and at head |
| masked runtime hashes of this build | Core 0x3229a50e...6d21, CoreLib 0xbe30bdc9...3947, CoreOpsLib 0x3237260e...fa35, ControllerV1 0x03359cd8...b98b, SeaportBasicAdapter 0xf5c8fd4b...d30c, CreditStrategyAdapter 0xa17a41dc...4a38, LogoCoinRenderer 0x789770d6...9be9; CoreLib creation 0x2976071e...cada, CoreOpsLib creation 0x0b4009fd...d689; all equal the pins in script/Checks.sol and test/BuildIdentity.t.sol |

## 2. What ran

| gate | result |
|---|---|
| candidate suite (`CANDIDATE_RUN=1 REHEARSAL=1 forge test --chain-id 1`) | 112 suites, 775 tests: 768 passed, 0 failed, 7 skipped (the seven Deep variants, which need `INVARIANT_DEEP=1`), 949.67 s wall |
| rehearsal with the real config (`REHEARSAL=1 LAUNCH_CONFIG=script/config/mainnet.json`, test/Rehearsal.t.sol) | pass; twelve transactions 21,230,672 gas in total (CoreLib 5,186,624; CoreOpsLib 788,657; Core 5,927,012; controller 3,969,084; Seaport adapter 638,760; strategy adapter 172,741; renderer 1,026,122; setCore 69,307; setController 87,583; addAdapter 77,785 twice; deployToken 3,209,212); every transaction under the 16,777,216 cap; deploy fee 0; at 5 gwei the deployer needs 0.106 eth, at 20 gwei 0.425 eth |
| deep invariants (`INVARIANT_DEEP=1`, 64 runs, depth 200, seven Deep suites) | 7 suites (Phase1, Phase1Window, Phase2, HostileController, HostileOwner, SalePhase1, SalePhase2), 55 tests passed, 0 failed, 0 skipped; 64 runs of depth 200 per suite (12,800 handler calls each); 2,517.97 s wall. Coverage caveat T-01 applies: after the hostile owner's first `setSettings` the royalty, discount, return lock and reserve are zero and value mode is off |
| test/GasCap.t.sol | compose 8,549,226 exec gas cold; `sellForEth` 501,755 for one credit, largest batch 87 credits at 16,735,455 tx gas; `sellForBalance` largest batch 94 at 16,631,893; `buyListing` 583,934 (strategy) and 569,791 (Seaport); buyback 221,130; redeem 223,008; swapCredit 229,080; `nextPage` read 244,914 under the 500,000 cap |
| test/BuildIdentity.t.sol | pinned hashes equal the artifacts; Core and CoreLib under EIP-170 (902 and 941 bytes of margin); tests compile without via_ir |
| audit tests (test/audit/AuditFindings.t.sol, new, 4 tests) | 1 passed, 3 failed as intended: each failing assertion is a stated rule the code breaks (findings C-01, C-02, C-03) |
| script/dev/e2e-real.sh (chain id 1 fork, block 26208025) | 37 PASS, 0 FAIL, 791 s; details and the real/mocked table in audit-84ea170/e2e-real-record.md |
| script/dev/test-launch-only-guards.sh (deferred launch, port 8794) | 10 PASS, 0 FAIL on a fresh fork at 26222700: DEFER_LAUNCH writes a coinless record, each of six tampered records is refused for its named reason, DRY_RUN collects every guard failure, the untampered record launches (coinLive true, launchBlock 26222712) |
| script/dev/test-indexer-deploy-guards.sh | passed |
| local stack (script/dev/local.sh PHASE=post, port 8619) with check-post.sh, the keeper e2e, the indexer candidate smoke on Postgres 16, an alert webhook sink | local.sh built the post phase chain (fork 26208025, Core 0x9224cb4b..., Jack's pinned token and the production module wired) in one run. check-post.sh: 7 PASS, 0 FAIL (module set, token runtime hash equals the pin, redeem on, module available 29,115.7 tokens; the balance fill probe skipped because the bid is off in the safe final state). keeper e2e (`npm run e2e --workspace keeper`): 6 of 7 pass (book, buyback, compose, collectEscrow, redeemStatement, priority); the `buyListing` test reverts at its seed because its hand written `setSettings` tuple has 37 fields (K-17), not because of the keeper. keeper live tick with a throwaway keystore: sent and confirmed `book()` (94,381 gas), decided `redeemStatement(247)` for the next tick, posted the `balance` alert as JSON `{source: cc-keeper, key: balance, text, balance, address}` to a local webhook sink (received). indexer candidate smoke on Postgres 16 (check-indexer.sh): passed at block 26209539, parity row 26209528, pile 11, pot 1,607,157,304,251,123,137 wei, 435 credits, 5 statements, all equal to fresh Core reads. web: `scripts/local-env.mjs` wrote the env from the record (Core, deploy block, both adapters, pool key, indexer url) and `npm run check` passed; the web's live reads share `packages/engine` `readSnapshot` with the keeper tick above |
| keeper unit tests | 49 passed, 0 failed |
| indexer unit tests | 14 passed, 0 failed; `ponder codegen` and `tsc --noEmit` clean |
| web | `npm run check` (7 scripts), `check:docs`, `tsc`, production build pass; `npm run lint` has no ESLint config and cannot run |
| forge lint src | no finding beyond the manual review (summary in audit-84ea170/forge-lint.md) |
| slither 0.11.6 | 165 results, every High and Medium read; none adds to the manual review (audit-84ea170/slither.md) |
| preflight against the fork with mainnet.json | 116 rows ok, 2 WARN (reference inputs pending, owner equals creator), 0 FAIL |

## 3. Findings

Severity: Critical (funds or liveness lost without an attacker's cost), High (loss or a stuck launch under a realistic
scenario), Medium (loss bounded or needs an unlikely setup, or a wrong decision record that would mis-launch), Low
(small, recoverable, or owner only), Info. Categories: security, economic, launch readiness, best practice, legibility.
"verified" means reproduced by test or traced by the auditor in the source; delegated findings carry the reviewer's area letter.

### 3.1 Security and economic (contracts)

| id | sev | where | claim | evidence | failure scenario | fix |
|---|---|---|---|---|---|---|
| C-01 | High | src/lib/CoreLib.sol:546-550, :375-389, :479-484 | in value mode, an unusable quote turns the eth bid into a fixed price: the fallback reads `rateAtCheckpoint`, which fills, time and the pool never move | test `test_quoteOutageFreezesTheBidThroughATokenCrash`: bid 4.41e15 before the outage, 4.41e15 after a real 50 percent pool move during the outage, a live quote would pay 2.45e15; three sells paid the frozen rate, `rateAtCheckpoint` unchanged | liquidity leaves (or the keeper stalls past `referenceMaxStale`), the token falls, credits bought at market are sold to the engine at the stale bid; bounded per bucket only by `spendCapBps` (void at 9,999) and by the pot | price the fallback off the shared instance times the last good value per point (owner decision 190), or fail closed for the two eth purchase doors; set `spendCapBps` 500 in value mode (decision 188) |
| C-02 | Low | src/lib/CoreOpsLib.sol:55-69, src/lib/CoreLib.sol:616 | the unpause shifts three clocks but not the eth `lastFillTime`; the ceiling's idle loosening gains up to `min(pause, lastFill - climbRestart)` | test `test_pauseDoesNotAddIdleLooseningSteps`: 9,789,904,493,600,000 without a pause, 11,767,760,417,943,988 after a 3 h pause, same 50 minutes of idle (20.2 percent higher) | after any owner pause longer than the gap between the last funding restart and the last fill, the bid's ceiling is looser than decision 178 states | shift `s.lastFillTime` with the others (decision 194) |
| C-03 | Low | src/lib/CoreLib.sol:806, :821, :729; src/lib/SettingsBounds.sol:11 | the rate can reach an absorbing zero: the bucket floor is 0 under 10,000 wei and `_climb` never climbs from 0; the bounds comment claims otherwise | test `test_rateCanReachZeroAndNeverClimbsBack`: from `setRate(2)` two fills reach 0; a week later with a funded pot `ethRate` reads 0 and sells revert `PotTooSmall`; `setRate` recovers | a griefer walks the rate to zero over hundreds of fills (giving credits away) and the bid is dead until the owner acts | `max(1)` on the dropped rate (decision 194) |
| C-04 | Low | src/lib/CoreLib.sol:656-664 | the return lock is keyed to the buyer; one transfer to a second wallet ends it, so the protection SPEC 14.19 states (time for a manipulated pool to move back) is not delivered | code and decision 167's own note | a buyer round trips through a second wallet in the same block | key the lock to the credit id for every counterparty (decision 193) |
| C-05 | Low | src/lib/CoreLib.sol:500-515 | `refreshReference` pays any caller `callerFee` plus gas every `referenceMinSeconds` once the quote triple is set; about 0.13 eth a day at launch values, farmable | code | a standing outflow in value mode no decision priced | accept and record, or pay only the keeper (an allowlist) |
| C-06 | Low | src/lib/CoreLib.sol:963-969 | `setSuccessor` refuses fewer targets than SPEC 11 says (the stack contracts pass) | code | owner only; `migrate` to the escrow would strand `ethPot` | align the check with `_forbidden` |
| C-07 | Info | src/Core.sol:749 | a target that returns more eth than it took in `buyListing` leaves untracked eth, booked as fee income (shared with the payee) at the next book | code | none | note |

### 3.2 Off chain services (keeper, indexer, web), verified by the auditor where marked

| id | sev | where | claim | fix |
|---|---|---|---|---|
| K-01 (verified) | High | keeper/src/main.ts:116-124, exec.ts:72, :141 | a `buyListing` that simulates clean (`estimateGas` at `latest`, no fee fields) and reverts on chain is neither cooled down nor dropped: the listing stays first, the tick ends, three reverts trip the one hour breaker; a contract offerer whose `receive` reverts on `tx.gasprice != 0` or a seller who drops the bid in the inclusion block starves every other sweep | cool down and drop on a reverted receipt; simulate with the transaction's fee fields at `pending`; use the relay's revert protection |
| K-02 (verified) | High | keeper/src/decide.ts:233-239 | the refresh door is sent every tick when the controller returns false for a reason the keeper does not gate (`_spot` not ok after a token replacement, a rate too small for one bps per cadence); the transaction succeeds unpaid, the breaker never trips, and the daily budget drains, idling every paid door | gate on `snap.value.spot` and `floor(rate * elapsed / 3600) >= 1`; count a zero receipt on a paid door as a breaker failure |
| K-03, K-04 | Medium | keeper/src/listings.ts, main.ts | the OpenSea refresh runs inside the tick with no request timeout; a malformed order throws outside the try and kills the tick once per refresh period | timeouts and per order try/catch |
| K-05 | Medium | keeper/src/exec.ts | the base fee ceiling is checked at the snapshot block only; the recheck clamps instead of refusing, producing unincludable transactions that count as breaker failures | refuse when the pending base fee exceeds the ceiling |
| K-17 (verified) | Medium | keeper/test/e2e/doors.e2e.ts:53-55 | the keeper door e2e encodes `setSettings` with a 37 field tuple (39 since decisions 163 and 164), so its `buyListing` test reverts at the seed call and has not passed since; the candidate workflow does not run `npm run e2e --workspace keeper`, so nothing caught it | regenerate the tuple from the engine ABI and add the keeper e2e to the candidate workflow |
| K-06 to K-16 | Low, Info | see audit-84ea170/keeper.md | receipt timeout blind spot, `txError` on hot paths, indexer seed at block 0, entrypoint guard, config values that fail a door on first use, test assertions checking fixtures, stale RUNBOOK lines ("on the controller, unpaid", an `observe` door) | per report |
| I-01 (verified) | Medium | indexer/src/index.ts, indexer/abis | `Core:TokenRescued` and `Controller:AgeEligibilitySet` have no handler, so Ponder never fetches them (51 handlers, 49 of the 50 events plus transfers); the age eligibility switch is untracked | add handlers and an ABI versus handler diff test |
| I-02 | Medium | indexer/src/index.ts:26-30 | per transaction facts (`ethFill`, `balanceBuy`, `coreBurn`) live in process memory; a restart inside a transaction misclassifies a credit as a balance bid or zeroes an amount, and no parity check covers it | derive from committed log rows of the same transaction |
| I-03 to I-12 | Low, Info | see audit-84ea170/indexer.md | stale sale columns on swap in, snapshot before the module projection, slow failover (inner retries), public `/sql` with no cap and CORS `*`, `/health/parity` ignores row age, a `BalanceToken` filter that cannot match, deploy ledger untracked, check-live prelaunch only, gen-abis merges CoreLib only, two reads that can halt indexing | per report |
| W-01 | Medium | web/components/StatementLive.tsx:373,377 | the redeem copy says the caller receives $BALANCE; `redeemStatement` leaves the tokens in the module and pays the caller fee only (decision 183 asked for this alignment) | fix the copy |
| W-02 | Medium | web/app/sell/page.tsx:48,153 | the sell page "pot" and "covers" use the gross `ethPot`; the header and stats use the buying room after reserve and royalty (decision 176) | use the room |
| W-03 | Medium | web/lib/events.ts:166-187 | the chain fallback history has no `ValueRateFill` case; in value mode without the indexer eth purchases are labelled balance bids with blank amounts | add the case |
| W-04 | Low | web/app/api/listings/route.ts:176-177 | the per client limiter keys on the first `x-forwarded-for` hop (client controlled); the global bucket still bounds the upstream | key on the trusted hop |
| W-05 to W-15 | Low | see audit-84ea170/web.md | "clears" ignores the royalty the Core adds, buy buffers below a 2 percent per minute climb, $BALANCE figures ignore `available()`, Flywheel split 75/25 versus 72.75/24.25/3, dead `valueOf` multicall, lint not runnable, docs wording, no caller payment shown on acquire, silent snapshot defaults | per report |

### 3.3 Tests and simulator

| id | sev | where | claim | fix |
|---|---|---|---|---|
| T-01 (verified) | High | test/invariant/HandlerOwner.sol:51-93 | the hostile owner's `_genSettings` builds a fresh struct and never assigns `buyToArtistBps`, `balanceDiscountBps`, `returnLockSeconds`, `reserveWei`, `valueModeOn`; after its first `setSettings` every invariant campaign runs with royalty 0, discount 0, no lock, no reserve and value mode off | fuzz the five fields and add launch value corners |
| T-02 | High | sim/engine.js:471-507, :554-557 | the simulator does not model the funded clock (176) or the paused clock (178); the exposure numbers the owner relied on overstate the climb of an underfunded or paused engine | port `_ethClimb` to the model |
| T-03 (verified) | High | sim/market.mjs:275 | `--spendcap` divides by `core.s.refScore`, removed by decision 145; the market run sells nothing | update the model |
| T-04 (verified) | Medium | test/invariant/Invariants.t.sol:124-126 | invariant 4 asserts a redeemed statement sits with the module; the production module hands it to the token | assert against the production custody |
| T-05 | Medium | test/standins/MockBalanceModule.sol, MockBalanceToken.sol | the stand ins omit `available()` gates, `pay` restrictions and accrual, `RedeemedBelowRating`, unit 1e10 versus 1e14, the renderer callback; production behavior runs only in UpstreamBalance.t.sol, which skips without the artifact | run the production module in the balance invariant suite |
| T-06 | Medium | test/Pause.t.sol:229, invariant 6 | no test has a fill between the funded restart and a pause, so C-02 was invisible | the audit test covers it |
| T-07 | Medium | test/utils/Fixture.sol:172-189 | the general suite runs with reserve 0, credit sale off, opening rate 1.732e15 and a 1e10 mock unit; the launch values are exercised only by the suites that override | a launch value variant of the fixture for the invariants |
| T-08 to T-13 | Low, Info | see audit-84ea170/tests.md | weak assertions (bare `expectRevert`, try/catch without a success count), invariant 14 reachable in three suites, hazard state fixtures, dead rising balance helpers, stale fixture comments | per report |

### 3.4 Scripts and deployment

| id | sev | where | claim | fix |
|---|---|---|---|---|
| S-01 | Medium | script/LaunchConfig.sol:18-24, script/config/v2-master.json | `STACK=master` cannot pass preflight (the pins are the live stack's); the runbook says CI loads the dump, neither workflow does | retire the variant (decision 195) |
| S-02 | Medium | .env.example, script/dev/anvil.sh:17, local.sh, check-preflight.sh, RUNBOOK 7 | the default fork block 26158000 predates the live factory; the dev flows fail out of the box; candidate.yml hard codes 26208025 | pin after 26205064 everywhere |
| S-03 | Low to Medium | script/deploy.sh:258-262, :308-331 | `RESUME=replay` and `RESUME=record` ignore a failing preflight; only `RESUME=state` re-enforces it | compare the failed rows with the allowed set as LAUNCH_ONLY does |
| S-04 (verified) | Low | script/SetSettings.s.sol:47-48, :71; docs/RUNBOOK.md:86; docs/INTEGRATION.md section 13 | the printed `cast send` fallback uses a 37 type tuple for a 39 field `Settings`; an operator pasting it in an incident gets an encoding error; the docs say 37 | derive the tuple from `SettingsFields`; fix the docs |
| S-05 | Low | script/PostflightPool.sol:467-476, :397-400 | "lp fee 0" and the protocol recipient are signed off but not read back (slot0 lpFee discarded; recipient a warn) | check both |
| S-06 | Low | script/Checks.sol:50-53 | the 22,000,000 gas budget rested on a pending gate; this audit measured 21,230,672 (3.6 percent under); the owner holds 0.0816 eth at head, which covers the deploy only up to about 3.7 gwei | fund the deployer for 20 gwei (0.43 eth) and re-pin the budget from the measurement |
| S-07 | Medium (legibility) | docs/SPEC.md:259, docs/RUNBOOK.md:23, :30, :81, :82, :145 | SPEC 12 instructs a removed factory step and `lockRecipients`; RUNBOOK names `CoinRenderer` as the launch renderer and `lockRecipients` in the lock table; the deployed token has `lock()` only (bytecode probe) | rewrite to decisions 126 and 160 |
| S-08 to S-11 | Low | see audit-84ea170/scripts.md | keystore on a 31337 node accepted and fails late; private key examples in script headers; the stale "live engine occupies the predicted addresses" comment in e2e-real.sh (false at 26222700 for both configs); check-preflight.sh dead | per report |

### 3.5 Decisions and documentation coherence

The full review of decisions 1 to 187 is audit-84ea170/decisions-coherence.md. The owner has since decided the open items
(decisions 188 to 196, recorded in audit-84ea170/owner-decisions-2026-10-19.md and to be entered in docs/DECISIONS.md by the
documentation change). The rows that remain findings against the repository as pinned:

| id | sev | claim |
|---|---|---|
| DC-01 | High (launch readiness) | the phase two parameter set was undecided and partly unsettable (spread 200 at tol 100 refused by the controller; `referenceMaxStale`, `minLiquidity`, value mode `spendCapBps` unvalued; the runbook switch step set `saleFloorBps` 5,000 and climb 100 with no decision). Closed by decisions 188 and 189 |
| DC-03 | Medium | two activation orders for the balance bid; the module wiring runbook lands in the hazard state. Closed by decision 191 |
| DC-04, DC-05, DC-06, DC-07, DC-12, DC-15 | Medium to Low | SPEC describes the removed mode-off pool floor, bounds the balance payout by `balanceBidCapBps`, carries the decision 120 fee arithmetic and the superseded coin admin vocabulary, cites gas bounds from before decision 169 |
| DC-08 | Medium | `lockRecipients` and `lockAllowlist` do not exist on the deployed token (bytecode probe of 0x99EB38d6 at 26222700: `lock()`, `unrestrict()`, `setAllowed`, `renounceAdmin()`, `setMetadataRenderer`, `updateImage`, `updateDescription` exist); `lock()` also freezes `lowerBaselineSkim`. Closed by decision 192 |
| DC-10, DC-13, DC-14 | Low | decision 158 versus the unclamped bases in code; 155(f)'s "same transaction"; the successor forbidden list |
| table B | Low | about 35 decisions superseded without the in place marker the log requires (FeeRouter 10.2/10.3/10.8, the lens 34, the pool floors 87/88/91/94/96d, and others). Closed by decision 196 |
| DOC-01 to DOC-14 | Low | README (half of every sale burns, `claimPayee`, `claimRoyalty`, the balance token in the Core, FORK_BLOCK 26158000), INTEGRATION (`NoQuote` from `sellForEth`, pool value in mode off, 37 fields, stale gas), STATUS headroom, e2e-real.sh and V2Stack.sol comments. List in audit-84ea170/docs-findings.md |

### 3.6 Legibility: comments, names and dead code

audit-84ea170/comments.md lists 68 onchain comment rows (16 contradicted by the code, 35 citations of decisions, reviews or
documents in NatSpec, 17 voice or punctuation), 27 dead or misnamed code items, 25 off chain comment rows, 19 test names and
9 shell or config comments, with the replacement text for each, plus 21 numeric claims checked and found correct. Highlights:
`_openDoor` says two steps and has three; `setPaused` NatSpec misstates the scope; CoreOpsLib says the clocks "restart";
`NoQuote` is declared in Core and CoreLib and never raised; `ICredits.approve`, `IStatements.safeTransferFrom` and 17
ArtCoinsV2 members are unused; the local `paused` in `_ethClimb` means underfunded; `State.balance` is now value mode's shared
instance; `pausedNow` is an internal without an underscore. None changes behavior; all go into the cleanup change.

## 4. Launch gates

Proven on this revision (by this audit's runs):
1. the build is the pinned build, under EIP-170 with 902 and 941 bytes of margin;
2. the live v2 stack equals the pins at head; the predicted launch addresses are empty; preflight on mainnet.json passes 116 rows;
3. the twelve transaction deploy measures 21,230,672 gas against the 22,000,000 budget and every transaction fits the block cap;
4. the candidate suite passes (768 of 768 run, 7 deep variants skipped by design in that run) and the deep campaign passes 55 of 55 (with the T-01 coverage caveat);
5. the real lifecycle on a chain id 1 fork passes 37 of 37 checks with real pool fees, the real keeper, real Seaport orders and Jack's pinned token;
6. the deferred launch guards pass (10 of 10); the indexer deploy guards pass;
7. the keeper, the indexer (Postgres path) and the web build and check against the same deployment record (check-post 7 of 7, keeper e2e 6 of 7 with the one failure a stale test ABI, keeper live tick with a confirmed transaction and a delivered alert, indexer smoke parity at block 26209539, web env and checks).

Not proven, and the minimum to close each:
1. value mode: C-01 (fix and re-test), the parameter set of decision 188 pinned in a tracked patch and a Config test, T-01 (fuzz the five fields) and a value mode invariant suite with the production module;
2. the keeper under adversarial listings: K-01 and K-02 fixed and covered by tests that replay a reverting receipt and a false refresh;
3. the deployer's balance: 0.0816 eth covers the measured deploy only below about 3.7 gwei; fund for 20 gwei (0.43 eth) before the broadcast;
4. the production services: a local fork proves code paths, not Fly.io capacity, relay behavior, OpenSea plan limits or RPC rate limits; the runbook's own pre-launch checklist (indexer parity on mainnet, keeper health against the deferred Core, alert delivery) remains to be executed against production;
5. `rateStart` deploy day refresh (decision 187) and the signoff hash of the launch copy;
6. the documentation that the authority order ranks above code (SPEC 12, 5, 9, 11; RUNBOOK lock table and wiring) corrected before the freeze, so the operator does not follow a removed step.

## 5. Limitations

- every run was on local Anvil forks of public archive RPCs; no mainnet state was changed; production service acceptance is not claimed;
- the lifecycle run impersonates the owner, pre-funds fixed accounts, forces 1 gwei base fees for keeper ticks, warps time and seeds the balance pool itself; the table in e2e-real-record.md lists each item;
- the delegated reviews (keeper, indexer, web, scripts, tests, comments) were performed by six fresh agents from source; the auditor verified the consequential claims named "verified" above and spot checked the rest; the full reports are included as appendices unedited;
- the deep invariant campaign ran once at 64 runs and depth 200; the fuzz coverage gap of T-01 applies to it;
- slither and forge lint were run on the production sources only; no symbolic or formal tool was used;
- the audit did not read docs/reviews/* or STATUS section 1 before forming its findings.

## 6. Changes proposed (separate from this report)

Documentation and cleanup change (no behavior): decisions 188 to 196 in DECISIONS.md and SPEC section 1; the SPEC, RUNBOOK,
INTEGRATION, README rows of 3.5; the comment, name and dead code rows of 3.6; the supersession markers; the fork block pins.

Contract change (behavior, reopens the freeze, each with its test): C-01 (decision 190), C-02 and C-03 (decision 194),
C-04 (decision 193). Script and service fixes: K-01, K-02, I-01, I-02, W-01 to W-03, S-03, S-04, S-05, T-01, T-02, T-03.
