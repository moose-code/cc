# Phase 3: treasury v2, ControllerV3, the burn stage

Status: spec for owner approval, 2026-10-22. Supersedes nothing until the owner approves it; then record the
decisions in docs/DECISIONS.md (next free number) and keep this file current.

## 1. Why

Phase 2 is live (stages A, B, C; see docs/STATUS.md section 1). Three problems surfaced in operation:

1. The $BALANCE bid cannot move. The Core's payout is `score * unitPerPoint * (10_000 - balanceDiscountBps) / 10_000`
   (CoreLib.sol:1211), at most 100% of par, flat (decision 164). Credits list at 108-115% of par, so the 80% offer
   fills only from holders who want $BALANCE; arbers never fill it. The treasury holds ~570k $BALANCE that cannot be
   put to work without an owner action.
2. Burn to redeem cannot work as built. v1 pays a CC burn a pro-rata share of the claim reserve, capped in the
   treasury at `floor(ccIn * C / S)`. With C ~57k $BALANCE against a ~$77k CC market cap, a burn returns ~4% of
   market value; no policy fixes this (decision 260).
3. The ETH bid stalls when $BALANCE falls. In value mode the ETH bid is `shared bps x valuePerPoint` with the shared
   instance capped at `balanceBidCapBps` (now 11,000). A $BALANCE dip lowers every bid and nothing loosens it.

Owner constraints (hard):
- The protocol never sells $BALANCE (no swap of treasury $BALANCE for ETH, no ETH pot refill from $BALANCE).
- Permissionless operation: buying, burning and funding run by onchain rule; the owner sets parameters and can pause.
- The goal of the burn stage is to burn CC, using $BALANCE as the incentive.
- Stay break-even or better over time (section 6).

## 2. Scope

| # | Component | Change |
|---|---|---|
| T1 | Treasury v2 | permissionless, climbing $BALANCE bid for Credits (`sellCredit`) that hands Credits to the Core through `adopt` |
| T2 | Treasury v2 | funding by rule: a working cushion, a surplus budget, no owner withdrawals needed to operate |
| T3 | Treasury v2 | the burn stage: CC burn bonds (burn now, $BALANCE vests, longer vest = higher premium) |
| T4 | Treasury v2 | v1 behaviour kept: Statement conversion, claim reserve accounting, `available()` for the Core's exchange |
| T5 | Treasury v2 | return-lock and resale-loop protection on the adopt route |
| T6 | Treasury v2 | optional one-way locks on owner powers (`withdrawWorking`, migration) |
| C1 | ControllerV3 | value-mode band check with headroom at the live margin |
| C2 | ControllerV3 | idle loosening: the ETH bid premium rises slowly while nothing is bought, bounded |
| C3 | ControllerV3 | views the treasury needs (resale floor of an id; anything T5 needs) |
| O1 | Indexer | handlers for v2 and V3 events; one batched reindex on a temp machine |
| O2 | Web | /exchange shows the better of the Core offer and the v2 bid; burn bond page; FAQ/flowchart |
| O3 | Keeper | refresh as needed for V3; no new paid doors |

Out of scope: any Core change (immutable), selling $BALANCE, buyback settings (owner decides separately).

## 3. Treasury v2 design

Start from `src/adapters/Phase2BalanceTreasury.sol` (v1). Keep its interface to the Core byte-for-byte compatible
(`unitPerPoint` stays the constant 1e14 = SCORE_TO_TOKEN; `available()`, `redeem`, `payOwed`/working payments, the
conversion path and its measured receipt). The Core reads `unitPerPoint` in `redeemStatement` (Core.sol:1047) and
ControllerV2/V3 read it for valuation; it must not become dynamic.

### 3.1 Accounting buckets

- `claimReserve` (v1 meaning; backs the legacy pro-rata claim, which stays off), `totalOwed` (v1), and:
- `cushion` (owner parameter, e.g. 150k): working funds kept for the Core's flat exchange.
- `bidBudget` and `bondBudget`: earmarks funded only from surplus by rule (section 6). Neither is ever paid from the
  claim reserve, the debt or the cushion.
- `available()` (what the Core's exchange may spend) = working funds above the earmarks, never below 0.

### 3.2 T1, the $BALANCE bid (`sellCredit(uint256[] ids, uint256 minOut)`, anyone)

- Price per point = `bidBps / 10_000 x unitPerPoint` in $BALANCE, where `bidBps` is a Rate state like the Core's:
  climbs `climbPerMinBps` while idle, drops `dropPer100PointsBps` per 100 points filled, bounded
  `[bidFloorBps, bidCapBps]` (e.g. 8,500 .. 11,500).
- Protected: the bid in ETH terms (points x $BALANCE price x bidBps) must not exceed the ETH bid of the same Credit
  times `(1 + bidOverEthBps)`; read the protected price from the controller (`valuePerPoint`/`spotPrice` pattern).
  A failed or stale read pauses the bid (no payout), never pays on an unsafe price.
- Each fill: pay the seller from `bidBudget` (artist royalty on top through the split, as the Core does: same
  `buyToArtistBps`), transfer the Credit to the Core, call `Core.adopt([id])` (public; CoreLib.adopt), require the
  Core now records it in the pile.
- Caps: per-call, per-period (e.g. per hour) and the budget itself. `minOut` slippage guard for the seller.

### 3.3 T5, loop protection (must solve before build)

The Core's return lock (`creditSoldAt`, `returnLockSeconds`) guards its intake doors but not `adopt`, and the Core
exposes no view of `creditSoldAt`. Risk: buy a Credit from the engine's resale, sell it to the v2 bid.
Required: the v2 bid for an id must stay below the engine's current resale price for that id by a margin, or the
id must be refused within `returnLockSeconds` of an engine sale. Options to evaluate: a ControllerV3 view of the
id's resale floor (C3); the v2 treasury recording `CreditSold` facts it can verify; refusing ids the Core sold
(the Core emits `CreditSold`; onchain verification needs a view). Pick the simplest sound one and state it.

### 3.4 T3, the burn stage: CC burn bonds (`bond(uint256 ccIn, uint8 tier, uint256 minOut)`, anyone)

- The caller's CC is transferred in and burned at once (the coin's `burn`); supply falls immediately.
- Payout in $BALANCE = `ccIn x rate x (1 + premium[tier])`, vesting linearly over `tierSeconds[tier]`,
  claimable any time (`claim(bondId)`). Default tiers: 7d +5%, 30d +15%, 90d +30% (owner parameters, bounded).
- Rate ($BALANCE per CC) = protected ratio: `min(CC TWAP, CC spot) / max(BALANCE TWAP, BALANCE spot)` in ETH, read at
  the bond call. CC needs a manipulation-resistant reference: reuse the controller's reference pattern for the CC
  pool (ControllerV3 or a small oracle in the treasury), with step/rate bounds and a staleness pause.
- Liability is committed at bond time: `bondBudget` decreases by the full payout when the bond is created, so vesting
  can never overdraw. Unvested balances stay in the treasury.
- Caps: per-call, per-period, per-wallet-per-period; pause.
- The legacy pro-rata `redeemCC` stays disabled; keep the function only if migration compatibility needs it.

### 3.5 T2, funding by rule (`sweep()`, anyone)

- Surplus = working funds above `cushion + bidBudget + bondBudget + reserved liabilities`.
- `sweep()` moves surplus into `bidBudget` and `bondBudget` in owner-set shares (and optionally into `claimReserve`),
  subject to the break-even rule (section 6). No owner transfer needed to keep either running.

### 3.6 Migration

v1 has `migrateTo(successor)` (owner) and v2 implements `receiveMigration(claimAmount)` (the v1 successor interface).
Sequence: deploy v2 → v1 `setSwitches` as needed → `migrateTo(v2)` (moves funds, imports claims) → Core
`setBalanceModule(v2)` (not locked) → readback. Rehearse on a fork of the head first.

## 4. ControllerV3 (start from `src/ControllerV2.sol`)

- C1: the band check `(1+step)(1+tol)(1-margin) < 1` has zero headroom at margin 1,000 (STATUS, stage C notes).
  Reformulate or widen so the live parameters pass with room.
- C2: idle loosening for value mode: while no Credit has been bought for `idleStepSeconds`, raise the premium
  applied in `valuePerPoint(false)` by `idleLoosenBps` per step up to a bound, reset on a fill (Core exposes
  `lastFillTime()`). Bounded so a stale or falling $BALANCE cannot inflate the bid without limit.
- C3: views T1/T5 need (resale floor of an id, protected prices for CC if the CC reference lives here).
- Keep every V2 view and event the Core, keeper, indexer and web read (tolerant reads exist for V1/V2 differences).
- Switch: Core `setController(V3)` (not locked) after the treasury migration, or in the same window.

## 5. Off-chain

- Indexer: v2/V3 events (bid fills, bonds, claims of vested $BALANCE, sweeps, controller settings). Put any API-only
  code in `indexer/src/api` (excluded from the build id). One reindex on a temporary machine
  (memory: indexer-reindex-cost; ~40 min warm).
- Web: /exchange best offer; a burn-bond page (tiers, live rate, vesting claims); FAQ and flowchart (burn stage now
  live, not "future"); market-compare reads v2.
- Keeper: refresh V3's reference(s) when needed (same refresh rule as today).

## 6. Break-even rules (encode onchain where possible)

Per-point facts: conversion returns 1.00 $BALANCE per point (0.90 working, 0.10 claim at 1,000 bps); the Core's flat
exchange costs 0.824 per point at 80% (+3% royalty).

1. Spend only realized surplus: `bidBudget` and `bondBudget` grow only from `sweep()` of working funds above the
   cushion; over any window, treasury working funds never fall below the cushion.
2. Bid ceiling vs exit path: Credits bought above par lose `(bidBps x 1.03 - 1.00)` per point if converted. Route
   them to ETH first: their Statements get a longer redemption delay (e.g. 7 days) so ETH buyers can take them; set
   the Statement multiplier so ETH sales actually happen (1.5x has produced zero sales).
3. Bonds are paid from surplus only and committed at creation; the premium schedule is bounded so the expected cost
   per CC burned stays within the budget the surplus provides.
4. ETH-bought Credits that convert are pure $BALANCE inflow (no $BALANCE paid out); keep the ETH bid buying (C2) so
   the surplus that funds the bid and the bonds keeps arriving.
5. Report the realized result: a public view of cumulative in/out per bucket so break-even is checkable.

## 7. Settings to decide alongside (no code)

`statementRedeemDelaySeconds`, `statementSaleMultiplierBps`, `conversionToClaimBps`, buyback settings
(`saleToBuybackBps`, `feeToRedeemBurnBps`, `creditCostToPotBps`), `balanceBidCapBps`, `callerFee`.

## 8. Acceptance (one run each, on a fork of the head with the live contracts; decision 265)

1. Migration rehearsal: v1 → v2 moves every $BALANCE, imports the claim reserve, Core points at v2, the Core's
   exchange and Statement conversion work unchanged against v2.
2. Bid: a real Credit bought on the fork's market state, sold to `sellCredit`, adopted into the pile, composed and
   converted, $BALANCE back in v2. The resale loop of 3.3 is refused.
3. Bonds: CC burned (supply falls), vesting claims pay exactly, budget cannot be overdrawn, price manipulation of
   either pool within one block does not change the payout beyond bounds.
4. Break-even: a scripted sequence of fills, conversions and bonds leaves working funds ≥ cushion.
5. ControllerV3: the live parameters pass the band check; idle loosening is bounded; every view the Core/keeper/
   indexer read answers.
6. Independent review of v2 + V3 (money, authority, migration): findings fixed before any send.

## 9. Operating rules for the session

Deploy from the main checkout, `--slow`, a no-keystore dry run with a gas estimate before every owner send, owner
runs every send with `--account ripe0x` on `https://gateway.tenderly.co/public/mainnet`. Tests and sims use the
deployed contracts on a pinned fork (no redeploys or stand-ins of live contracts). Never use the owner's Alchemy
key. Whole-suite runs only on a frozen candidate with `CANDIDATE_RUN=1`; per change, run only the touched tests.
