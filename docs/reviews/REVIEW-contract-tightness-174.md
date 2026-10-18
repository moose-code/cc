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

The regression uses actual v4 swaps on fork block 26,208,025, a composed statement and a pool-price decline/reseed. Before repair it quotes 15,445,502,838,924,550 wei against the Core floor of 73,596,136,923,679,948 wei. The regression must assert that the reference remains value-only and buying at the final quote transfers the statement. Existing accepted sale prices and the Core's hard floor are preserved.

## Verification and limits

Cleanup verification: `forge build` passed (solc 0.8.30); generated interfaces regenerated with no tracked interface delta. At fork block 26,208,025, 122 checks passed in ValueMode, BuildIdentity, CoreLayout, BidRule, ChosenCompose, Adopt, PerPointExact, SetSettings, CoinRenderer and LogoCoinRenderer, excluding the separate new quote regression. BalanceFlat added 12 passing checks. Total cleanup coverage: 134 passed, 0 failed, 0 skipped. Runtime sizes: Core 24,491 bytes (4 saved), CoreLib 24,446 (73 saved), ControllerV1 17,163 (85 saved). Build hashes and sizes re-pinned. Source symbol scans found no further unused imports or uncalled private functions; public library helpers were checked across callers.

The separate statement quote regression reproduced its expected failure before repair; it is not part of the cleanup pass count. Quote repair, final comment review and post-repair verification remain in progress. No full suite, deep invariant campaign, production release build, rehearsal, deployment, push or merge is part of this pass. Executable changes reopen the release freeze; prior `85dbc51` gate records remain historical evidence only.
