# Phase 3: treasury v2 and ControllerV3

Start by reading AGENTS.md, docs/STATUS.md section 1 and the last rows of docs/DECISIONS.md. Live addresses are in
deployments/1.json and deployments/1-phase2.json.

## Task

Build, test, review and prepare the deployment of treasury v2 and ControllerV3 as specified below, plus the indexer,
keeper and web changes listed. Ask the owner one question at a time, with a recommendation, where this spec says
"decide".

## Hard constraints

- The protocol never sells $BALANCE.
- The Core is immutable. Only the balance module (treasury) and the controller are replaced; neither is locked.
- Tests and sims run against the deployed mainnet contracts on a fork pinned at block 26250700 or later. No
  redeploys or stand-ins of live contracts.
- Tenderly RPC only (`https://gateway.tenderly.co/public/mainnet`). Never use the owner's Alchemy key.
- You never broadcast. Every owner send is prepared from the main checkout with `--slow`, a no-keystore dry run
  and a gas estimate first; the owner runs it with `--account ripe0x`.
- Frontend changes stay local until the owner reviews them.

## Work rules (fast, safe)

- Implement v2 and V3 as new files next to `src/adapters/Phase2BalanceTreasury.sol` and `src/ControllerV2.sol`.
- Run only the tests you add or touch, once each. No separate build when a test run compiles. Whole-suite runs only
  once, on the frozen candidate, with `CANDIDATE_RUN=1`.
- One migration rehearsal on a fork of the head. One independent review of v2 + V3 (money, authority, migration);
  fix findings and re-run only affected tests.
- Indexer: API-only code in `indexer/src/api`; all schema changes in one reindex on a temporary machine.

## Why

1. The Core's $BALANCE payout is flat and at most 100% of par (`score * unitPerPoint * (10_000 - balanceDiscountBps)
   / 10_000`, CoreLib.sol:1211). Credits list at 108-115% of par, so the treasury's ~570k $BALANCE cannot buy them.
2. The v1 treasury hard-codes redemption as a pro-rata share of the claim reserve, so no other burn/redeem design
   can ever be used without migrating the treasury.
3. In value mode the ETH bid follows the $BALANCE price and stalls when $BALANCE falls.

## Treasury v2

Keep the Core-facing interface of v1 unchanged: `unitPerPoint` stays the constant 1e14 (the Core requires a
conversion to bring in `rating * unitPerPoint`, Core.sol:1047), plus `available()`, `redeem`, working payments and
the conversion path.

**Custody and spenders (decision 292).** The treasury is the custodian and holds no pricing rule. Claim debt and
owed payments as in v1; `cushion` (owner parameter, e.g. 150k) reserved for the Core's 80% exchange; one bucket per
registered spender. A spender is any contract the owner registers (`registerSpender`, bucket, switch off by default,
per call / per period / lifetime caps, a one day activation delay, a sweep share): a redeemer, quoted through
`IRedeemer` for a CC burn in `redeemCC`, or a module that draws itself through `draw(to, amount, accrue)`, the credit
bid among them. The treasury checks only the bucket, the caps, the recipient, the switch and the pause. No bucket pays
from another, the debt or the cushion. `available()` = working funds above all earmarks. A new rule is a new spender:
deploy, register, fund its bucket, switch it on; the treasury never migrates for a rule. `migrateTo(successor)` exists
as a last resort only, the v1 handshake again: every switch and spender off, every bucket but the pro-rata one
returned, custody less the debt and the committed payouts moves, the pro-rata bucket lands in the successor's.

**$BALANCE bid: `CreditBid.sellCredit(uint256[] ids, uint256 minOut)`, anyone.** A spender module
(`src/adapters/CreditBid.sol`), its budget its bucket, its per call and per period caps its spender caps.
- Price per point = `bidBps / 10_000 * unitPerPoint`. `bidBps` climbs while idle, drops per 100 points filled,
  bounded `[bidFloorBps, bidCapBps]` (8,000..10,000, never above par, decision 285).
- Its ETH value may not exceed the Credit's ETH bid by more than `bidOverEthBps`, using the controller's protected
  $BALANCE price. A failed or stale read pauses the bid.
- Each fill: pay the seller from `bidBudget` (artist royalty on top through the split, at `buyToArtistBps`), send
  the Credit to the Core, call `Core.adopt([id])`, require it is in the pile. Per-call and per-period caps.
- Loop protection, decide before building: the Core's return lock does not cover `adopt` and has no view. Stop
  "buy from the engine's resale, sell to the v2 bid": keep the bid below the engine's resale price of the id by a
  margin (a ControllerV3 view), or refuse ids the engine sold within `returnLockSeconds`.

**Funding: `sweep()`, anyone.** Moves working funds above `cushion + bidBudget + buckets + committed liabilities`
into `bidBudget` and the redeemer buckets in owner-set shares. The conversion contribution (`conversionToClaimBps`,
10%) keeps feeding the pro-rata redeemer's bucket.

**Redemption, pluggable.**
- Redeemers are contracts the owner registers. Each has its own bucket, switch (off by default) and caps (per call,
  per period, lifetime). A newly registered redeemer has a per-period limit (and optionally a delay) before it can
  draw, so a bad one cannot drain the treasury in one block.
- The treasury checks only: the CC was burned, the payout fits the redeemer's bucket and caps, it goes to the stated
  recipient, and the caller's pinned configuration epoch is current.
- Payout modes available to any redeemer: immediate; linear vesting held in the treasury; deferred claim. Any
  committed amount is reserved in full when created.
- Redeemer 1, shipped off: the current plan. Pays `ccIn * B / S` less `redemptionFeeBps` (B = its bucket, S = CC
  supply). The v1 claim reserve migrates into its bucket. `/claim` reads it. Turning it on stays the owner's decision.
- Adding a design later: deploy the redeemer or module, register it as a spender, fund its bucket, switch it on. No
  treasury migration, for a redemption rule or a bid rule alike.

**Owner powers.** Parameters, pause, redeemer registration and bucket shares. Decide whether to add one-way locks
(for example on `withdrawWorking`).

**Migration.** Deploy v2 → v1 `migrateTo(v2)` (moves funds, imports claims through v2 `receiveMigration`) → Core
`setBalanceModule(v2)` → readback.

## ControllerV3 (from ControllerV2)

- The value-mode band check `(1+step)(1+tol)(1-margin) < 1` must pass the live parameters with headroom.
- Idle loosening: while nothing is bought for `idleStepSeconds` (Core `lastFillTime()`), raise the premium in
  `valuePerPoint(false)` by `idleLoosenBps` per step up to a bound; reset on a fill.
- Views v2 needs: the resale price of an id; a CC price reference (time averaged, step and rate bounded, staleness
  pause) available for future redeemers.
- Keep every view and event the Core, keeper, indexer and web read today. Switch with Core `setController(V3)`.

## Off-chain

- Indexer: v2/V3 events (bid fills, redeemer registration, redemptions, vesting and deferred claims, sweeps,
  settings).
- Web: /exchange shows the better of the Core's 80% offer and the v2 bid; /claim reads redeemer 1 (off);
  market-compare reads v2.
- Keeper: refresh V3 references when needed, same rule as today.

## Break-even rules

1. `bidBudget` and redeemer buckets grow only from surplus above the cushion; working funds never fall below it.
2. Credits bought above par lose `(bidBps * 1.03 - 1)` per point if converted, so they should exit for ETH: decide a
   longer Statement redemption delay (e.g. 7 days) and a lower Statement multiplier (1.5x has produced no sales).
3. Every redemption payout comes from its own bucket, reserved in full when committed.
4. Keep the ETH bid buying (idle loosening): ETH-bought Credits that convert are the surplus that funds everything.
5. Public views of cumulative in and out per bucket.

## Acceptance (once each, on the pinned fork)

1. Migration: v1 → v2 moves all $BALANCE and the claim reserve; the Core's exchange and Statement conversion work
   against v2.
2. Bid: a real Credit sold to `sellCredit`, adopted, composed and converted, $BALANCE back in v2; the resale loop is
   refused.
3. Redemption: redeemer 1 (on, fork only) burns CC and pays `ccIn * B / S` less the fee, reverting on a stale epoch;
   a fork-only test redeemer exercises vesting and deferred payouts and cannot exceed its bucket or caps.
4. Break-even: a scripted run of fills, conversions and redemptions leaves working funds at or above the cushion.
5. ControllerV3: live parameters pass the band check; loosening is bounded; every consumed view answers.
6. Independent review passed, findings fixed.

## Deliver

Merged code on main; rehearsal evidence in docs/STATUS.md; decisions in docs/DECISIONS.md; the owner command
sequence (dry run first for each): deploy v2 and V3 → migrate → setBalanceModule → setController → readbacks.
