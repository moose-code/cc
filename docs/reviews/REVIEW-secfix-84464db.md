# review of 84464db (fixes for docs/reviews/REVIEW-security-55307c4.md M1, M2, L4, I1-I3)

reviewer: read-only, diff + source read. no tests or builds run.

## findings
src/lib/CoreLib.sol:587: 🟡 risk: live `IExitModule(c.exitModule).unitPerPoint()` is a raw high-level call with no gas cap, unlike the bounded `_ask` (READ_GAS, 32 bytes) used by `_setExitModule`/`refreshUnitPerPoint`. A module that burns 63/64 of gas or reverts blocks every `sellForExitToken` (intended for revert, not for gas burn). Use the same bounded staticcall; keep revert on failure.
src/Core.sol:814: 🟡 risk: `refreshUnitPerPoint` does not check `IExitModule(module).exitToken() == exitToken`. `_setExitModule` enforces this (ExitTokenChanged). An upgradable module that switched token would store a unit for another token while the Core still measures the old one. Add the same check.
src/CoreLens.sol:183: 🟡 risk: `exitBidOf` uses stored `core.unitPerPoint()`, not min(stored, live) as `_sellForExitToken` does. Quote exceeds payout once the module lowers its rate; a front end using the quote as `minOut` reverts `Slippage`. Read the module unit live and take the min.
script/Checks.sol:76-82: ❓ question: BUILD_HASH_* comment says "computed at the frozen candidate in project/director-state.json" (6ea44f5). Constants now hold hashes of 84464db sources and director-state.json is not updated in this commit. Intended (candidate refreeze pending)?
src/ControllerV1.sol:308: 🟡 risk: value floor still uses stored `unitPerPoint`; after a module rate drop and before `refreshUnitPerPoint` the floor overstates value and the ask is too high (buyer harm only). Stale-low after a rise understates. Residual of M1 bullets 1 and 3, covered only by the owner calling refresh. Needs a runbook line in RUNBOOK.md; no code fix required.
test/SecFixes55307c4.t.sol:70: 🔵 nit: `test_bidRevertsWhenLiveUnitReadFails` uses bare `vm.expectRevert()`; no test for refresh with a failing read or unit > uint128, none for refresh keeping module/token.

totals: 0🔴 4🟡 1❓ 1🔵

## verified correct
- M1 bid: unit = min(stored, live); live 0 gives price 0 and `ZeroAmount`; failing live read reverts the whole bid; higher live keeps stored. Exit check (Core.sol:706) still uses stored unit.
- M1 refresh: onlyOwner, nonReentrant, no `exitModuleLocked` check so it works after lock; writes only `unitPerPoint`; module and `exitToken` untouched; `_ask` bounded read, unit nonzero and <= uint128 max (same as `_setExitModule`); NoExitModule when unset.
- M2 release: onlyOwner, nonReentrant; move = min(amount, reserve); ZeroAmount on 0; only `ethRedeemBurn -= move`, `ethToBuyback += move`. Touches no `ethPot`, `xPot`, rate or checkpoint state. Solvency sum unchanged. Works after `migrate` (migrate leaves both trackers). `onlyOwner` modifier does not checkpoint.
- L4: `exitSlippageBps <= exitBidMarginBps` in SettingsBounds after the individual caps; launch configs (200 <= 2000) satisfy it; handler bound mirrors it; ReviewFlowCore test adjusted to margin 0 and slippage 0, not weakened. Cycle claim holds: bid unit <= stored unit used by the exit check.
- I1: `setExitPoolKey` requires c0 == 0 and c1 == exit token, then non-zero slot0 (same StateLibrary read as `_value`); pool cannot be uninitialized later. `_value` math for eth as currency0 is `owed*Q96^2/p^2`, floor-rounded. `_exitIsCurrency0` removal leaves no reader.
- I3: lens returns 0 when no module, retired, or mode != 2, and caps at `xPot`.
- Tests: new tests assert exact amounts, edge (slippage == margin), non-owner, retired path, solvency. Invariant handlers add refresh/release with strangers and ledger checks. ExitValueFloor tests flipped to match the new rejection, not removed.
- Sizes: Core runtime 17,481 under the limit.

## not examined
- forge build/tests/invariants (read-only, none run); BuildIdentity sizes and BUILD_HASH values not recomputed.
- docs edits (ARCHITECTURE, DEPLOY, INTEGRATION), MockExitModule internals, ICore generated-interface check, buyback `sqrtPriceLimit` (unchanged, now receives released reserve), L1-L3 (unchanged).
