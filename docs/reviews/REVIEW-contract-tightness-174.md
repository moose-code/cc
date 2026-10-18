# Contract tightness and comment pass (decision 174)

Owner request, 2026-10-18: review contracts for unused or unnecessary code and accurate comments/NatSpec, and make the contracts tight and legible for other developers. Base: `a6099d2`; branch: `codex/contracts-tightness-pass`. This is a source cleanup and focused correctness pass, not release acceptance or a new exhaustive security audit.

## Scope and method

Read all 23 Solidity files under `src/`: Core, ControllerV1, CoreLib, bounds/halving/drawing libraries, three adapters, both renderers, hand-maintained interfaces and generated interfaces. Follow private/internal symbol callers and cross-file library consumers; distinguish public integrations, forwarded calldata and storage from dead code. Compare comment claims with implementation, SPEC and decisions, including mode transitions, units, zero settings and failure behavior. Generated interfaces are regenerated from the ABI, never hand-trimmed.

The director reviewed Core and shared semantics. Separate read-only investigator agents reviewed CoreLib; Controller/adapters/bounds; and interfaces/renderers/drawing on immutable base `a6099d2`. Their source findings were reconciled before implementation. These investigations are not release acceptance reviews.

## Comment and NatSpec guidelines

- State rules, invariants and caveats in plain technical voice. Explain why a constraint exists or what a caller must account for; omit narration already clear from code (AGENTS.md; decision 114).
- Use “balance”, never the superseded vocabulary. Use no em or en dashes (AGENTS.md; decision 102).
- Keep units, rounding, ranges, roles, mode conditions, zero behavior and failure/fallback behavior exact. A comment cannot promise a successful fill merely because a view returns a nonzero price.
- Every kept line/helper/document must protect a promise. Every kept test carries `// promise:`. Do not add boilerplate NatSpec tags or comments solely to repeat a signature.
- Preserve generated-interface ownership and upstream drawing provenance. Describe compatibility-only declarations explicitly rather than imply they still execute.

The first two bullets and the promise rule are existing repository requirements. Exact semantic claims and restrained NatSpec are how this pass applies those requirements, not a newly mandated tag format.

## Removed or simplified

- Six unused Uniswap imports and the unused Core `DEAD` constant.
- CoreLib's uncalled external `drop` wrapper. Live fills already reach `_drop` through `spend`; Core's public purchase ABI is unchanged.
- Controller's legacy variable-quantity `_priceBaseUnits` and overflow helper `_mulDivFits`. Its sole remaining caller always prices `1e18` base units, so both intermediate products fit: `1e18 * 2^192 < 2^256`. `_spot` preserves the two separate integer divisions and all key/token/zero-price gates.
- The unused private `nextPage` format result, identity-return values from ownership checks, and the unused checkpoint boolean/redundant value-mode guard.

No unused storage field was found. Keep `State.balance`: it is value mode's ETH price instance, even though the posted balance bid is now flat. Keep getter/integration surfaces and ABI error declarations used by consumers. Keep CoinRenderer and its drawing helpers: decision 160 explicitly retains the pile renderer for a later owner swap. LogoCoinRenderer's Core binding is required by the shared renderer/deployment surface.

## Corrected documentation

Correct stale balance-state climb/drop descriptions, quote failure/fallback rules, value-mode payout clamps, wei-per-100-points units, royalty-inclusive adoption basis, original-buyer return locks with zero disabling the lock, bounded return-data semantics, artist royalty accrual limits, successor exclusions, recovery restrictions, configurable anchor movement, pause/eligibility caveats, tolerance-dependent spread bounds, renderer choice and the logo's 0.9-second hold followed by 0.7-second movement.

## Confirmed correctness defect

Controller's value-mode statement reference intentionally excludes historical cost. However, its final curve quote could fall below the Core's unconditional `cost * saleFloorBps / 10_000` floor, causing a purchase at `priceOf` to revert `BelowFloor`. This conflicts with the executable-price promise and does not require a new economic decision: keep the value-only reference and clamp only the final quote to the Core's existing floor, exactly as credit pricing already does.

The regression uses actual v4 swaps on fork block 26,208,025, a composed statement and a pool-price decline/reseed. Before repair it quotes 15,445,502,838,924,550 wei against the Core floor of 73,596,136,923,679,948 wei. The repaired regression passes: the reference remains value-only, the final quote equals the historical cost minimum, and buying at that quote transfers the statement. Existing accepted sale prices and the Core's hard floor are preserved.

## Verification and limits

Cleanup verification: `forge build` passed (solc 0.8.30); generated interfaces regenerated with no tracked interface delta. At fork block 26,208,025, 122 checks passed in ValueMode, BuildIdentity, CoreLayout, BidRule, ChosenCompose, Adopt, PerPointExact, SetSettings, CoinRenderer and LogoCoinRenderer, excluding the separate new quote regression. BalanceFlat added 12 passing checks. Total cleanup coverage: 134 passed, 0 failed, 0 skipped. Runtime sizes: Core 24,491 bytes (4 saved), CoreLib 24,446 (73 saved), ControllerV1 17,163 (85 saved). Build hashes and sizes re-pinned. Source symbol scans found no further unused imports or uncalled private functions; public library helpers were checked across callers.

Cleanup commit: `d1c27ab`. The separate statement quote regression reproduced its expected failure before repair. After repair, a second focused batch passed 94 checks in ValueMode, Sale, RatingReference and BuildIdentity, with 0 failures and 0 skips. Across the cleanup and repair batches, 181 distinct test functions passed. Both the regular `forge build` and the final scoped contract build passed; `script/tools/gen-interfaces.sh --check` passed; `git diff --check` passed. Forge's automatic foundry.lock/Solady changes were restored after each run.

Final runtime sizes against base `a6099d2`: Core 24,491 bytes (4 saved, 85 below EIP-170), CoreLib 24,446 (73 saved, 130 below), ControllerV1 17,189 (59 saved after the quote correction). The final controller hash/size is re-pinned. Core storage and Core's public ABI are unchanged. The removed uncalled library wrapper is intentionally absent from CoreLib's dispatch.

The fork block was 26,208,025. The regression exercises actual v4 swaps and real Credits/Statements; its balance token and module are the fixture's explicit stand-ins. The review does not establish behavior of a future token/module beyond the separate existing integration tests.

Exact focused commands (with the configured MAINNET_RPC_URL and FORK_BLOCK=26208025):

```sh
forge test --match-path test/ValueMode.t.sol --match-test test_statementQuoteCoversHistoricalCostFloor -vv
# Above: expected failure before repair. Below: passing cleanup and final repair batches.
forge test --match-path 'test/{ValueMode,BuildIdentity,CoreLayout,BidRule,ChosenCompose,Adopt,BalanceBid,PerPointExact,SetSettings,CoinRenderer,LogoCoinRenderer}.t.sol' --no-match-test test_statementQuoteCoversHistoricalCostFloor
forge test --match-path test/BalanceFlat.t.sol
forge build src/Core.sol src/ControllerV1.sol src/lib/CoreLib.sol
forge test --match-path 'test/{ValueMode,Sale,RatingReference,BuildIdentity}.t.sol'
script/tools/gen-interfaces.sh --check
```

The initial cleanup glob included the nonexistent historical BalanceBid filename; its live flat-balance equivalent was exercised separately by BalanceFlat. This did not skip any claimed cleanup test result.

Independent final review: [record](REVIEW-contract-tightness-174-independent.md), SHA256 `69200da05a37e0bd10b20147e5359686a43bd43324ba7ee50a566193971129b0`. Reviewer `final_review` inspected the immutable source/test snapshot SHA256 `1fd09d17862bebe4c8c23f6cbf917fd510d9a7226cfdee62882396ab9585682c`, found no runtime defect and requested four documentation corrections. All four were repaired and rechecked with no remaining findings. Runtime tests were run by the director, not the reviewer. No full suite, deep invariant campaign, production release build, rehearsal, deployment, push or merge is part of this pass. Executable changes reopen the release freeze; prior `85dbc51` gate records remain historical evidence only.
