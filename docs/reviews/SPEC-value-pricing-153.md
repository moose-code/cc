# Value referenced pricing: the implementation spec after decisions 147 to 153

Date 2026-10-16. Base: main `f1101cb`. Source of each rule: the decision in docs/DECISIONS.md named in brackets. The review behind it: docs/reviews/DESIGN-value-pricing-f1101cb.md. Nothing here is built; this is what to build.

## 1. One unit, one value

- The unit is points (145). A credit's score is its points times 10,000; the eth rate is wei per 100 points (`RATE_SCORE`); one point is one BALANCE (`unitPerPoint` 1e14 base units per score unit, 18 decimals).
- The value of a point in ETH is `V = unitPerPoint × P / 1e18` wei per score unit, where `P` is the protected ETH price of BALANCE (section 2). Two readings: `V_buy` from `P_buy`, `V_sell` from `P_sell`.
- Equal score means equal value. No cost basis and no remembered bid peak prices anything once the switch is on; cost records stay for accounting.

## 2. The reference and the protected price [148]

- The controller stores `reference` next to the balance pool key. `_observe()` moves it toward the pool spot by at most `min(rateBpsPerHour × elapsed / 3600, maxStepBps)` and records the time. It runs at the start of `buy`, `buyCredit`, `buyCredits`, and in a public `observe()`. Views never update it.
- `P_buy = min(spot, reference × (10,000 + tolBps) / 10,000)`. `P_sell = max(spot, reference × (10,000 - tolBps) / 10,000)`.
- Usable when: the newest update is within `maxStale`, pool liquidity (`getLiquidity` of the key) is at least `minLiquidity`, the unit read succeeds. Unusable halts the ETH routes only (`sellForEth`, `buyListing`, `buy`, `buyCredit`, `buyCredits` revert `NoQuote`); `sellForBalance`, `redeemStatement`, `compose`, `buyback`, `book` stay live.
- Settings, one `Quote` struct with a setter by the Core's owner: `rateBpsPerHour`, `maxStepBps`, `tolBps` (500 proposed), `maxStale`, `minLiquidity`. Values are tuned once the pool exists and its depth is known.
- Accepted limit: a hold of the pool price longer than the rate limit moves the reference the full way. The owner's pause is the backstop; the web shows spot against reference.

## 3. The shared bid [122, 150, 151, 152]

- One price state for both currencies: the existing balance `Rate` instance in bps of par. The ETH instance is retired when the switch is on.
- Floor and opening 90 (`balanceBidMarginBps` 1,000). Normal ceiling 100. Above 100 only through the existing idle loosening (`idleLoosenBps`, `idleStepSeconds`, the pot multiplier on this instance). Hard cap `balanceBidCapBps` 11,000, bound 10,000 to uint32.max, the most the engine ever pays [152].
- Climb and recovery climb 100 bps a minute [151]; the temporary phase runs the same 100 on the ETH instance from launch (config change to `script/config/*.json` and `Mainnet.defaultSettings()`). Drop `dropPer100PointsBps` 115, no minute floor, as built.
- Per credit: `bps_now` is the instance climbed to now, at least the floor, at most the hard cap, not clamped to funds. ETH route pays `score × V_buy × bps_now / 10,000`, which is `ethRate() × score / RATE_SCORE` with `ethRate() = bps_now × V_buy × RATE_SCORE / 10,000`; `bidForScore`, `ethPerPoint`, `bidOf` keep their meaning. BALANCE route pays `score × unitPerPoint × bps_now / 10,000`, no quote needed. Every fill on either route drops the one instance by `_drop(score)`; `buyListing` included.
- Funds limit capacity, not value: the ETH route reverts `PotTooSmall` above `ethPot - reserve`, the BALANCE route above `available()`. `buyListing` pays `value <= bid` and `min(gas refund + keeperFee, bid - value, ethPot - reserve - value)`.
- No new budget [146, review F5]: the drop bounds dump volume; `spendCapBps` stays an incident tool for the ETH route.
- The BALANCE bid stays in accumulate mode (`balanceBidOn` false) until the switch, because the two instances share the climb settings.

## 4. Sales [150, 153]

- `floorMult = max(10,000, (10,000 + spreadBps) × balanceBidCapBps / 10,000)`, read live, so a cap change moves the floor with it. `spreadBps` 200: 11,220 at the launch hard cap.
- `protected = points × V_sell × floorMult / 10,000` for a credit (its score) and a statement (its rating).
- Ask: `protected × (start - (start - 10,000) × min(age, window) / window) / 10,000`. Credits: `creditStartBps` 15,000, `creditWindow` 14,400 s from acquisition. Statements: `markupBps` 15,000 at an anchor of 10,000 with `anchorMoveBps` 0, `decayHours` 4, age by `statementAge`.
- Core floors: `sellTo` and `sellCreditTo` refuse under `cost × saleFloorBps / 10,000` (the credit door changes from `cost`); `saleFloorBps` is lowered to a sanity level (5,000) at the switch. The controller's ask is never under `protected`.
- Splits as built [149]: statements 2.5 and 0.5 percent cuts off the top, 25 percent of the rest to the buyback, the remainder to the pot; credits the cuts, then `creditCostToPotBps` (8,000) of the cost to the pot, the rest to the buyback.
- Why the loop closes: the most paid is `cap × score × unit × spot / 1e22`; the least asked is `(10,000 + spread) × cap × score × unit × spot / 1e26`; a round trip loses at least the spread at every bid and quote state, in either currency.

## 5. Conversion

- `atFloor(sid)` becomes `startBps() <= 10,000 || statementAge(sid) >= decayHours × 1 hours`, no reference read. Eligibility never restarts on a price move and never blocks on a quote. (Recommended, not yet decided.)
- `redeemStatement` unchanged otherwise: module set, `redeemOn`, module returns at least `rating × unit × 0.98`, proceeds stay in the module, caller paid.
- Compose unchanged: the 80 oldest credits past their window.

## 6. Reserve and return lock (recommended, not yet decided)

- `reserve = max(reserveWei, 15 × queued / 10)`, `queued = (pileSize / 80) × (9,000,000 × callerMaxBaseFee + callerFee) + heldIds.length × (600,000 × callerMaxBaseFee + callerFee)`. Bids and `ethRate()` read `ethPot - reserve`; `_payCaller`, buyback and the pushes still pay from the whole pot. `reserveWei` 1e17.
- Return lock: `creditSaleBlock[id]` stores the sale timestamp; every intake door (`sellForEth`, `sellForBalance`, `buyListing`, `swapCredit` as `inId`) refuses a credit the engine sold within `returnLockSeconds` (86,400 proposed; 0 keeps the block rule). Error `ReturnLocked(id, until)`.

## 7. Settings summary

| setting | where | value |
|---|---|---|
| `climbPerMinBps`, `recoveryClimbPerMinBps` | Core | 100 now [151] |
| `balanceBidMarginBps` | Core | 1,000 |
| `balanceBidCapBps` | Core | 11,000 at the switch [152] |
| `valueModeOn` | Core, new | false at launch, true at the switch |
| `reserveWei` | Core, new | 1e17 |
| `returnLockSeconds` | Core, new | 86,400 |
| `saleFloorBps` | Core | 10,000 now, 5,000 at the switch |
| `spreadBps` (was `floorBps`) | controller | 200 [153]; at launch values, before the switch, 11,000 was 10 percent over `max(cost, valueOf)` and 200 on a 10,000 cap gives 2 percent: the owner may keep 1,000 until the switch |
| `creditStartBps`, `creditWindow` | controller | 15,000, 14,400 |
| `markupBps`, `anchorMoveBps`, `decayHours` | controller | 15,000, 0, 4 |
| `Quote` | controller, new | `rateBpsPerHour`, `maxStepBps`, `tolBps` 500, `maxStale`, `minLiquidity`; tuned at pool creation |

## 8. The switch, one block

`setSale` and `setCredit` first if not yet applied; the controller's `Quote` and pool key set; `observe()` called until usable; then one `setSettings` with `valueModeOn` true, `balanceBidOn` true, `balanceBidCapBps` 11,000, `balanceBidMarginBps` 1,000, `climbPerMinBps` and `recoveryClimbPerMinBps` 100, `saleFloorBps` 5,000. Turning `valueModeOn` on resets the shared instance to the floor.

## 9. Packets

- A, settings only: `decayHours` 4, `anchorMoveBps` 0, `creditStartBps` 15,000, climb 100 [151]. Config files and `Mainnet.defaultSettings()`, SPEC 3 and 8.
- B, next candidate, independent of BALANCE: the credit door floor on `saleFloorBps`, the reserve, the return lock, age only `atFloor`, `spreadBps` with the live cap multiplier. Core bytes: the clamp moves into CoreLib; new logic in CoreLib and the controller.
- C, the switch: `valuePerPoint(bool forSale)` on `IController`, the reference and `Quote`, `valueOf` on `V_sell` with the floor rate and cost terms dropped when on, `CoreLib.climb` in value mode from the shared instance and the controller's bounded read (200,000 gas, fail closed to `NoQuote`, bounded by `rateCap`), `spend` dropping the shared instance, the instance climbing whenever `valueModeOn` or the BALANCE bid is usable, `clampTo = cap`.
- Every packet: `forge build`, `forge test --match-path` on touched files, `script/tools/gen-interfaces.sh`, re-pin `script/Checks.sol` and `test/BuildIdentity.t.sol`, simulator and keeper and web follow, docs/SPEC.md and INDEXER.md rows, a decision row for any owner call made along the way. The full suite, deep invariants and rehearsal run once on the frozen candidate with `CANDIDATE_RUN=1`.

## 10. Tests required

Round trips in both currencies at the floor, the cap, after a climb, in the next block, after 20 idle minutes, across a currency switch, at spot above and below the reference, with the reference stale: the attacker loses at least the spread and the lock refuses inside its window. The shared instance drops on an ETH fill and a BALANCE fill; a currency switch cannot reset it; only the switch and the bid turning on reset it. The reserve: acquisitions revert at `ethPot - reserve`, processing still pays, `ethRate()` never above the payable. Eligibility by age under every quote state and a pause. Sale floors on both doors. A hostile controller quoting a huge or zero value cannot pay above `rateCap`, cannot move the BALANCE bid, cannot block conversion. The reference: spam gains nothing beyond the rate, a long idle gains one step, staleness halts the ETH routes only, the cap multiplier follows a cap change. Gas of the ETH doors with the extra read. Invariants 1, 2, 3, 7, 16, 19 restated. `sim/engine.test.mjs` on the new rules and `sim/value.mjs` rerun on the engine model; keeper boundaries for the age gate, the reserve alert, the halted quote skips, the observe tick.
