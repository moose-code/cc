# Contract review notes (src/**), main 84ea170

Read in full: Core.sol (1,597 lines), lib/CoreLib.sol (1,359), lib/CoreOpsLib.sol (176), ControllerV1.sol (724),
adapters/StatementBalanceModule.sol (161), adapters/SeaportBasicAdapter.sol, adapters/CreditStrategyAdapter.sol,
lib/SettingsBounds.sol, lib/CreditBounds.sol, lib/Halving.sol, interfaces/Interfaces.sol, interfaces/ArtCoinsV2.sol,
LogoCoinRenderer.sol, CoinRenderer.sol (CreditDrawing.sol skimmed: pure drawing code).

## Threat model (who can move what)

| actor | can move | bound |
|---|---|---|
| anyone | eth out of the pot by selling a credit (`sellForEth`) | `ethRate() * score / 1e6` per credit plus 2.5 percent royalty to the artist; the pot room; the spend cap when under 10,000 |
| anyone | eth out of the pot by sweeping a listing (`buyListing`) | at most the bid for the credit (price plus keeper payment) plus the royalty; the target passes the forbidden list; exactly one credit must arrive |
| anyone | eth to themselves as caller payment (`compose`, `composeChosen`, `redeemStatement`, `refreshReference`, `buyback`, `buyListing`) | gas up to a per door cap at `min(basefee, ceiling)` plus a fixed fee; `refreshReference` pays only when the controller moved the reference (at most once per `referenceMinSeconds`) |
| anyone | balance tokens out of the module (`sellForBalance`) | posted `score * unit * 0.9` per credit plus royalty, the module's `available()`; value mode lowers it to the eth bid at `P_sell`; `balanceBidOn` must be on |
| anyone | statements out of the Core | by paying the controller's ask (`buy`, at least `cost * saleFloorBps`) or by redeeming an eligible statement into the module (`redeemStatement`, proceeds stay in the module) |
| anyone | pile credits out of the Core | by paying `creditPrice` (`buyCredit`), or by swapping in a credit of equal or higher score for `swapFeeCc` burned |
| anyone | coin supply down | `buyback` burns what the slice buys; `swapCredit` burns the fee |
| anyone | the eth instance's clock | `fund`, `book`, `collectEscrow` checkpoint; a checkpoint never raises the read (verified: `_checkpointNow` climbs to now and stores; `_climb` is monotone in time until a fill) |
| controller | `sellTo` and `sellCreditTo` at any price at or above `cost * saleFloorBps / 10_000` | owner sets both the controller and `saleFloorBps` (0 allowed) |
| balance module | the statements handed to it and every token it holds | owner sets it; `everBalanceTarget` keeps replaced modules off every other door |
| listing adapter | the one call the Core makes in `buyListing` (target, value, data) | approved by the owner; target must pass the forbidden list; value at most the bid; one credit must arrive |
| payee, artist | receive forced pushes (50,000 gas); cannot block | shares bounded by settings |
| coin admin (owner key) | the pool's bounty recipient (`setBountyRecipient` on the hook), `lowerBaselineSkim`, `setAllowed`, `unrestrict`, `lock()` | until `lock()` |
| owner | everything in SPEC section 11; the forbidden list stops only the stack contracts, Credits, Statements, the coin and past balance targets | no timelock (accepted) |

Reentrancy: every door that moves assets is under solady's guard (Core) or `_enter/_leave` (CoreLib `rescueCoin`,
`rescueNft`, `migrate`); `setArtist`, `setSuccessor`, `lockSuccessor`, `rescueToken` are owner only and write before
any external call or make none. The controller's `buy*` doors have their own `_busy` flag and call `sellTo*`, which are
guarded; a Core door cannot reach a controller door. External calls with attacker influence: the listing target
(`buyListing`, after `_openDoor`, before `_spend`; a re-entrant view reads the pre-spend pot: read-only reentrancy
exposure for an external integrator pricing off `ethRate` inside a Seaport order's receive hook, not for the engine),
the seller payment in `sellForEth` (after state), the forced pushes (bounded gas), `IBalanceModule.pay` and `redeem`
(owner-set module), the hook's `receive` push (two immutable compares).

## Findings (contracts)

### C-01 (Medium to High, economic) Value mode quote outage: the fallback bid is a fixed price that does not follow the token
- src/lib/CoreLib.sol:546 to 550 (`_valueRateOrLast` returns `c.rateAtCheckpoint` when the quote is unusable); :375 to 389
  (`spend` in value mode drops the shared instance only); :479 to 484 (`_checkpointNow` stores a new rate only when the quote is ok).
- while `valuePerPoint(false)` is unusable (reference older than `referenceMaxStale`, liquidity sample under `minLiquidity`,
  pool key token mismatch, no module) every credit is paid `rateAtCheckpoint * score / 1e6`: no drop, no decay, no spot.
  In healthy value mode the bid follows `min(sampledSpot, ref * (1 + tol))` and so falls with the next refresh after a
  token crash; in the outage it stays at the pre-outage level until the quote recovers or the owner acts.
- scenario: value mode on; the LP withdraws (or the keeper stalls past `referenceMaxStale`); the token falls 50 percent;
  credits are bought on the open market at the new value and sold to the engine at the frozen bid; bounded per
  60 second bucket by `spendCapBps` of the pot (void at the runbook's 9,999) and overall by the pot room.
- reproduction: test/audit/AuditFindings.t.sol `test_quoteOutageFreezesTheBidThroughATokenCrash`, run on the fork at 26222700: bid before the outage 4,410,000,000,000,000 wei per 100 points; after the reference lapsed (1 day + 1 s, no refresh) and a real 50 percent pool move, the bid still 4,410,000,000,000,000; the bid a usable quote would pay at the crashed spot 2,450,000,000,253,200 (the frozen bid is 1.8x the live value); three credits sold in the outage were each paid the frozen rate times score and `rateAtCheckpoint` did not move. FAIL on main at the assertion `the outage bid follows the token's value`.
- fix: store the last good value per point and keep the shared instance as the multiplier (drop and climb still bind;
  the stored value still lags but the spend cap is not the only bound), or fail closed on `sellForEth` and `buyListing`
  while the quote is unusable and keep the fallback for views only. Decide `spendCapBps` for value mode with this in view.

### C-02 (Low, correctness versus decision 178) Unpause does not shift the eth instance's `lastFillTime`
- src/lib/CoreOpsLib.sol:55 to 69 shift `anchor.peakTime`, `balance.anchor.peakTime`, `climbRestartTime`,
  `balance.lastFillTime`; `s.lastFillTime` is left. src/lib/CoreLib.sol:616 anchors idle loosening on
  `max(lastFillTime, climbRestartTime)`.
- when the last fill is later than the last funded restart and the pause is longer than their gap, the shifted restart
  overtakes the fill time and the ceiling earns `min(pause, lastFill - climbRestart)` of idle steps (600 bps times the
  pot multiplier per 600 s step).
- reproduction: `test_pauseDoesNotAddIdleLooseningSteps` (fork 26222700, fixture settings, pot 5 eth, fill one hour after funding): with 50 minutes of unpaused idle after the fill the price state is 9,789,904,493,600,000 without a pause and 11,767,760,417,943,988 with a 3 hour pause in between (20.2 percent higher). FAIL on main at `paused time added idle loosening steps to the ceiling`. fix: shift `s.lastFillTime` like `balance.lastFillTime`.

### C-03 (Low, liveness) The eth rate can reach an absorbing zero
- src/lib/CoreLib.sol:806 and :821 (`_drop`: floor `minuteStartRate * dropFloorBps / 10_000` is 0 under 10,000 wei;
  `mulDiv` rounds a one or two wei price to 0); :729 (`_climb`: `r != 0` guard, no climb from zero); :773 (`_recover`
  divides by `r`). src/lib/SettingsBounds.sol:11 claims the bounds prevent it.
- reaching it from the launch rate takes hundreds of fills across at least four buckets (each bucket can fall 10,000x
  at `dropFloorBps` 1) at prices near zero, so it is a griefing path (the griefer gives credits away) with an owner
  recovery (`setRate`). `ethRate()` reads 0, `sellForEth` reverts `PotTooSmall`, `buyListing` reverts `AboveBid`.
- reproduction: `test_rateCanReachZeroAndNeverClimbsBack` (fork 26222700): from `setRate(2)` two fills of 800 point credits take `rateAtCheckpoint` to 1 then 0; a week later with a funded pot `ethPrice()` and `ethRate()` read 0 and the next sell reverts `PotTooSmall`. FAIL on main at `a funded pot climbs the price state after a week`. `test_setRateRecoversAZeroRate` PASSES: `setRate` reopens the bid. fix: `max(1)` on the dropped rate.

### C-04 (Low, design) The return lock is keyed to the buyer and ends with one transfer
- src/lib/CoreLib.sol:656 to 664. SPEC 14.19 states its purpose as time for a manipulated pool to move back. A transfer
  of the credit to a second wallet (one `transferFrom`) removes the lock. The owner has decided (this session) to key it
  to the credit id for every counterparty.

### C-05 (Low, economic) `refreshReference` is a permissionless paid door once the quote triple is set
- src/lib/CoreLib.sol:500 to 515: any caller is paid `min(gas + 50,000, 200,000) * min(basefee, callerMaxBaseFee) + callerFee`
  from the pot each time the controller moves the reference (at most once per `referenceMinSeconds`, 600 s). At launch
  values (3 gwei, 0.0003 eth) that is about 0.13 eth a day of standing outflow in value mode, farmable by anyone; the
  keeper is not needed for it. Not a defect, a cost no decision prices; raise it as a parameter.

### C-06 (Low, doc versus code) `setSuccessor` refuses fewer targets than SPEC section 11 states
- src/lib/CoreLib.sol:963 to 969: the Core, ever balance targets, the coin, Credits, Statements. The hook, pool manager,
  factory, locker, escrow, Permit2, position manager and universal router pass. Owner only. `migrate` to the escrow
  would strand `ethPot` (the escrow's `receive` path is not `fund`). Align the check with `_forbidden` or the text with the code.

### C-07 (Info) `buyListing` books an over-refund as fee income
- src/Core.sol:749: the balance may rise above `ethBefore - value` (a target that returns more than it took). The
  excess is untracked eth and the next `_book` shares it with the payee and the redeem burn pot. No loss; a note.

### C-08 (Info) Decision 158 versus the code: `adopt`, `_moveEth` and `_ethFloorNow` are not clamped
- src/lib/CoreLib.sol:899, :1011, :1188 read the price state climbed toward booked room, never lowered to a clamp.
  SPEC section 6 and the Core comment (:1305 to :1311) describe the unclamped basis deliberately (a thin pot must not
  book a 1 wei basis). The decision row is the stale one; see the decisions review DC-10.

### Checked and found sound
- the `_delegate` forwarding (`_toLib`, `_toOps`) copies calldata and bubbles reverts; every forwarded owner function
  checks `msg.sender == state().owner` inside the library; `swapCredit`, `adopt`, `sellForBalance` run under the Core's guard.
- `setSettings` forwarding rewrites the selector to the library's struct-typed one; the constructor runs the same
  validation before the Core has code.
- `_book` ordering: checkpoint before the pot grows (no climb credited under a later pot); payee share only after the
  latch; the latching book shares nothing; pushes forced with 50,000 gas.
- `buyback`: `slice >= 2 * maxPay` keeps the payment under half the slice; `paid <= slice - spent`; refund via escrow.
- `sellForBalance`: running total of payouts plus royalties checked against `available()` read once; the seller's
  receipt verified; the artist pay is gas bounded and failure-tolerant; the production module accrues shortfalls.
- `redeemStatement`: custody handed first, the module's holding must rise by `rating * unit * (1 - slippage)`;
  the production module additionally requires `rating * 1e14`.
- `_quote` of `buyListing`: 4 word minimum, 8,192 byte maximum, 2,000,000 gas; `value == 0` refused; one credit must arrive;
  balance may fall by at most `value`; keeper payment capped at the gap and the room.
- `_sniperOver`: word 9 of `deploymentInfo` is `launchedAt` in the v2 struct (token, hook, locker, mevModule, escrow,
  poolId, configHash, version, launchedAt): offset word plus 8 static fields precede it. Correct.
- deferred launch window: `fund`, `adopt`, `compose`, `sellForEth` work before the coin exists; `swapCredit` reverts
  (no code at `COIN` for `burnFrom`); `setHeldFormat` reverts `BelowMinCc` (balance read of no code is 0); `payeeOn`
  never latches (`launchedAt` 0). Matches the runbook's abort note except the error name (`PotTooSmall`, not `ZeroAmount`).
- arithmetic: `_climb` cap product fits (anchor <= uint64, loosened bounded by uint16 * uint16 / 1e4 * steps);
  `_climbTo` exponent inputs within int256; `_toBpsRaw` saturates before the multiply; `Halving` returns 0 past 256 half lives.
