# Delta audit: e6a7654 against 1db4a9f

2026-10-17. Scope: every merge on `ripe0x/cc` main from `1db4a9f` through `e6a7654384c7b1d95c9a108da520cbcb04004350` (PRs 81 to 95, decisions 166 to 172). Audit checkout: fresh clone, branch `codex/delta-audit-e6a7654`. All chain execution used local Anvil forks with chain ID 1 at Ethereum block 26,216,744. No mainnet broadcast or production contract behavior edit was made. Jack's `jckbtchr-vv/credits` checkout was built by `script/tools/upstream-balance.sh` at `9318c713974ee18658ac5aeddab45f0e1e45b585` (`ConversionLineageWithdrawals`).

The auditor's fixes (commits 0a0059c, 379d652, adc6f50, 153345e on its branch) were re-implemented on main by PR 96 (decision 173).

## Verdict

The listed S01, S02 and S03 closures reproduce as passing with the bound ControllerV1 and Jack's pinned token. The original candidate has two operational defects found in this audit: the dev scenario leaves a documented mode-off round-trip hazard and its postflight fails 7 pass, 1 fail; the web presents a posted BALANCE payout when the protected quote is unusable, although the contract reverts `ZeroAmount`. Both were fixed without changing production contracts. The residual controller-read fallback in `CoreLib` remains reproducible under a hostile or incompatible controller, as decision 167 already discloses. The freeze table still says `candidate | pending`, so this is audit evidence, not release acceptance.

## Security

### SEC-01 | Medium | `src/lib/CoreLib.sol:589-592`

Claim. In value mode, `_clampPayout` returns the posted BALANCE amount when its bounded `balanceClampFor` read fails or returns malformed data. The normal ControllerV1 outage path answers `(0,true)` and closes S02; the low-level read-failure path remains open.

Test evidence. `test_hostileQuoteIsBounded` passed with a hostile controller that rejects `balanceClampFor`; its trace shows `BalanceFill` with seller payout 19,008,810,000,000,000 mock-token units and artist amount 475,220,250,000,000 instead of zero. The current ControllerV1 outage test passes: two bad pool samples, `balanceClampFor` returns `(0,true)`, `balanceBidOf` becomes zero, and a pre-outage Credit moved to a second wallet reverts `ZeroAmount` despite the 21,600-second return lock applying only to its buyer.

Failure scenario. An owner installs or leaves an incompatible controller, or a bounded quote read fails after value mode is active. A seller can collect the posted balance bid when no safe protected sale value was established. Conditional on that read failure; not observed with the bound ControllerV1 during an ordinary quote outage.

Structural fix. Make the BALANCE payout fail closed on an unsuccessful `balanceClampFor` read in value mode, while retaining the last-good-rate fallback for ETH. Core and CoreLib are immutable and at their size limit; the owner accepted the residual (decision 167) with the operational rule that the bound controller always answers and stays unlocked.

### SEC-02 | Medium | `web/app/api/listings/route.ts`

Claim. The OpenSea fulfillment endpoint has a per-client token bucket keyed to the first `x-forwarded-for` value and a four-request concurrency cap, but no global upstream POST budget. Different client keys can consume the whole cached listing set every 10 seconds.

Test evidence. `web/scripts/listings-route.test.mjs` passes while exercising 200 distinct known listing hashes from 200 client keys and causing 200 upstream POSTs. `BUCKET_BURST=10`, `BUCKET_REFILL_MS=2,000`, `MAX_FULFILL_INFLIGHT=4`, `MAX_LISTINGS=200`, `FULFILL_CACHE_MS=10,000`.

Structural fix. A shared global upstream POST budget, client identity from a trusted proxy boundary only, quota decided against the OpenSea plan. PR 96 adds the global bucket (burst 8, refill 4 per second, plan-dependent constants).

## Best practice

### B-01 | Medium | `web/lib/live.ts`, `web/lib/sell.ts`, `web/app/sell/page.tsx`

Claim. The candidate treated an absent `perPointSell` as mode off, replayed the posted balance payout, and left the BALANCE sell action enabled. Decision 167 makes the live Core quote zero and revert `ZeroAmount` in this state.

Test evidence. A score of 4,330,000, unit 1e14 and posted rate 9,000 produced a displayed 389.7 BALANCE in the candidate replay while the unusable-quote contract payout was zero.

Failure scenario. A user sees a payable amount, approves the Core, then submits a sell that reverts and pays gas.

Structural fix. Keep value-mode state independent of quote availability in all web payout calculations and block the action when the protected quote is unusable. PR 96.

### B-02 | Low | `web/lib/live.ts` (`useCoinLive`)

Claim. The deferred-launch coin-code query caches `false` indefinitely and refetches only when the window regains focus. A foreground tab will not notice a later launch until focus changes or reload.

Structural fix. Poll code every 15 seconds while the answer is false, then stop once it becomes true. PR 96.

## Legibility

- LEG-01 `script/dev/Scenario.s.sol`: the "temporary" bid comment conflicted with the stage's final state; postflight 7 pass, 1 fail. Fix: close the bid after the two route fills (PR 96).
- LEG-02 `script/dev/check-post.sh`: header said the balance bid was on although the gate rejects that state with a pool key. Fix: describe the skipped probe (PR 96).
- LEG-03 `web/lib/live.ts`: comment said an unusable quote keeps posted pay; web showed 389.7 BALANCE while Core paid 0. Fix: align with decision 167 (PR 96).
- LEG-04 `web/lib/sell.ts`: replay comment treated missing value fields as par. Fix: explicit value-mode flag, zero for a missing protected quote (PR 96).
- LEG-05 `docs/STATUS.md`: baton led with superseded candidates. Fix: lead with this audit, freeze table stays pending (PR 96).

## Launch readiness and numbered verification

### 1. S01, artist royalty liability (PR 83/90, decisions 166/169)

`test/UpstreamBalance.t.sol` 8 passed; `test/StatementBalanceModule.t.sol` 21 passed. With `ARTIST_PAY_GAS=600,000`, Jack's real token transferred a one-credit cold-wallet royalty directly, `owed=0`. A complete 80-Credit page sold at its exact posted total and delivered the total royalty directly, `owed=0`; `available()` fell by seller payout plus royalty. A direct module payment on the real token measured 296,463 gas cold and 119,117 warm for 1e18 units. A forced 100,000-gas payment accrued 5e18 owed, excluded it from `available()`, and `claim()` delivered the full 5e18. A mock token that moved half of a 40-token transfer then returned false accrued only 20, a full move with false return added 0, a reverting transfer added 40, a no-move/no-data transfer added 40; final owed 100 against 60 delivered.

### 2. S02/S03, protected value cap (PR 84/86, decisions 167/168)

`test/ValueMode.t.sol` 41 passed across three suites. The unusable protected quote returns `(0,true)`, refuses the BALANCE fill with `ZeroAmount`, including from a second wallet holding a Credit bought before the outage. `test_balanceCapIgnoresEthPotClamp` and partial-room variants pass: a funded module pays while the ETH pot sits at its reserve and `bidForScore` is zero. Loop-closure and cross-route tests pass at caps 11,000 and 30,000; one measured ETH round trip paid 0.01252258161 ETH, returned 0.01138416510 ETH, lost 0.00113841651 ETH. `cap = floor(floor(ethPrice × score / RATE_SCORE) × 1e18 / pSell)`, so `paid × pSell / 1e18` cannot exceed the un-clamped bid.

### 3. Gas bounds and byte identities (PR 90, decision 169)

`test/GasCap.t.sol` 13 passed; `test/BuildIdentity.t.sol` 6 passed. Core and CoreLib `QUOTE_GAS`/`READ_GAS` 2,000,000; CoreLib `REFRESH_GAS` 200,000; `ARTIST_PAY_GAS` 600,000. Hostile controller degrades the ETH route rather than halting it. One-credit ETH sell 522,082 gas. Mode-off 86-Credit ETH batch 16,467,926 against the 16,777,216 cap (309,290 headroom); 87 Credits 16,686,998 (90,218 headroom); 88 Credits 16,891,192, over the cap. One-credit BALANCE sell 431,129; largest 94-Credit balance batch 16,617,597. Core 24,495 bytes, CoreLib 24,519, ControllerV1 17,248; `script/Checks.sol` and `test/BuildIdentity.t.sol` hashes match. EIP-170 headroom 81 and 57 bytes.

### 4. Pool key while value mode is off (PR 89, decision 170)

`test/ModeOffDifferential.t.sol` 11 passed. Ten price views and doors match with and without a pool key through refresh cycles in mode off. The route test reproduces the accepted hazard when `balanceBidOn=true`, `valueModeOn=false` and a pool key is set, with spot 30% above break-even; value mode closes it at caps 11,000 and 30,000. Same-key `setBalancePoolKey` resets reference and both sample slots to the live spot; a 2x `expectedSpot` is rejected by the 4.5% seed guard. The dev seed and e2e-real preflight reject the hazard; the dev scenario reintroduced it (L-01, fixed in PR 96).

### 5. Jack re-pin (PR 91, decision 171)

`ConversionLineageWithdrawals` at `9318c713974ee18658ac5aeddab45f0e1e45b585`. Creation SHA-256 `ecc7afbffdcebc9004e25f2e767e932fe697f266d28c33330862065ff00e98ae`; token runtime hash `0x29b369bc9814eaaf98e696df1a521200ad8584726f2fe036b3408a9d0bf3c3bd`. Renderer and artwork runtime hashes unchanged (`0xc8b64ac9...`, `0xc5b01961...`). `opensAt=1792506000`; before it a non-funder redemption reverts `ConversionNotOpen` and module `available()` is zero; reaching it without retirement reverts `LaunchSupplyNotFinalized`. After both gates, real-token redemption and one-credit/page BALANCE sales pass.

### 6. Deferred launch (PR 94, decision 172)

`test/Resume.t.sol` 9 passed; `test/Config.t.sol` 30 passed. `script/dev/test-launch-only-guards.sh` 26 checks, 0 failed on chain ID 1. Step 1 leaves `coinLive=false`, no `launchBlock`, `code=0x` at the predicted coin. Keeper reads `launchedAt=0`; the web coin-code gate sees `0x`. Ten tampered records and a stale deferred record refuse `LAUNCH_ONLY`; its dry run collects 3 guard failures. The intact record launches at block 26,216,755. Against a one-shot deployment from the same fork state, records match except `rpcUrl` and `launchBlock`, 7 runtime code hashes match, Core settings return identical bytes, both postflights pass.

Vendored `docs/reviews/factory-source/ArtCoinsFactoryV2.sol` and `ArtCoinsDeployerV2.sol` have SHA-256 `14135d0f107d80f1b233b2d6bcc781faa51c9804970bc536679bf6ec8771faa5` and `22eaa7f832915c3e06067d802b52a911650ed997b48d812d9e483d154538deb6`, identical to the Sourcify source (full creation and runtime match); the fetched runtime equals the fork's mainnet bytecode at `0xC27e182ef5D8A1A7C9dd0a27414fEaBA47DF8e3c`. The factory's deprecated gate permits only its owner to deploy; a non-owner `deployToken` reverts `Deprecated()`.

### 7. Candidate gates

Single full suite run (`CANDIDATE_RUN=1`, fork chain ID 1, block 26,216,744): 112 suites, 751 passed, 0 failed, 7 skipped (deep variants gated by `INVARIANT_DEEP`). Invariants 21 and 21b passed in 8 suite variants at 24 runs × 80 calls, 0 reverts; a targeted deep run passed 7 suites at 64 runs × 200 calls, 0 reverts. `FRESH=1 script/dev/e2e-real.sh` passed 35 checks with Jack's token; balance sell paid 246.5604 BALANCE to the seller and 6.16401 BALANCE artist royalty; the same-block round trip lost 0.000177461682905660 ETH. Keeper unit tests 48/48. `npm run check -w web` and web TypeScript passed. Simulator 2,098 engine checks and 97 value checks. `gen-interfaces.sh --check` clean. Focused fork tests 147 passed across ten files.

### L-01 | Medium | `script/dev/Scenario.s.sol`

Claim. The `balance-bid` stage opens the mode-off BALANCE bid to test two fills and does not restore it; the final state is the pool-key round-trip hazard that decision 170 forbids.

Test evidence. `PHASE=post script/dev/e2e.sh` passed; `check-post.sh` gave 7 pass, 1 fail with `balanceBidOn=true`, `valueModeOn=false`, `poolKeySet=true`. With the bid closed after the fills, the stage paid 1,088.90973 BALANCE across one-credit and two-credit fills and `check-post.sh` passed 7 checks with the balance-fill probe skipped.

Structural fix. Keep the route exercise in a bounded temporary owner setting and restore `balanceBidOn=false` before leaving the stage. PR 96.

## Limits

The factory source check relies on Sourcify's verified source plus byte-for-byte runtime comparison on the fork; it did not reproduce the solc build settings. The OpenSea quota effect was tested with stubbed upstream fetch. The full suite and real-token rehearsal ran on the original `e6a7654` source before the web and dev-script fixes; a newly frozen candidate needs its own one-time gates. Only the 21/21b deep campaigns were run. `check-freeze.sh` returned `pending candidate: not frozen`.
