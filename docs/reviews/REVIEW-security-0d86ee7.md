# security and acceptance review of 0d86ee7 (delta 14c6306..0d86ee7)

reviewer: independent, read only. clone at /private/tmp/sec-0d86ee7, nothing in the original worktree touched.
scope: git diff 14c6306 0d86ee7 -- src script, plus docs/DECISIONS.md decisions 59 to 63, docs/SPEC.md section 1, script/config/mainnet.json.
method: read the diff and the surrounding code, targeted `forge test --match-path` on the fork (MAINNET_RPC_URL tenderly, FORK_BLOCK 26158000), one PoC.
no critical or high finding. two medium, three low, two info. no change to custody, floor, booking or the ethPot path.

## part 1, findings, most severe first

### M1 (medium) the anchor falls atomically, and open listings follow it in the same block
src/ControllerV1.sol `_moveAnchor` (L170-183), `_ask` (L185-191), `startBps` (L123-126), called from `buy` (L144-155).
every `buy` moves the anchor to the mean of the old anchor and the sale price, whatever the price or the size of the sale, and every open listing reprices from the new anchor at once (decision 62, "computed live"). sales at the floor of old listings therefore lower the start price of every fresh listing inside one transaction sequence. a searcher buys the floor-priced listings (a price it would pay anyway), then buys the fresh listings at the reduced ask.
numbers at launch settings (markup 15_000, cap 100_000, floor 7_500, decay 105 h), PoC `test_poc_inBlockAnchorErosion` (test/SecPoC.t.sol in the clone, extends SaleAnchorTest):
- four honest sales at the start price: anchor 10_000 -> 24_413. a fresh listing asks 36_618 bps of cost.
- 105 h later two old listings sit at 7_500. buy #1: anchor 24_413 -> 15_956. buy #2: 11_728.
- the fresh listing now asks 17_591 bps of cost (-52 percent), same block, purchase cost of the two old listings unchanged.
- from the cap: anchor 100_000 -> 53_750 -> 30_625 -> 19_062 -> 13_281 -> 10_390 -> 10_000 after six floor buys, the fresh ask falls from 100_000 to 15_000 bps (-85 percent).
effect: the engine's price memory is erased by one actor in one block; the discount goes to the searcher, not to the market over time. a buy below the anchor is the only requirement.
fix, any of: (a) apply `_moveAnchor` at most once per interval (store `anchorMovedAt`, skip the move when `block.timestamp < anchorMovedAt + N`), (b) let the anchor fall slowly (move up at once, down by a fraction per elapsed time), (c) weight the move by the cost of the sale against a running total. (a) or (b) keep decision 62 for honest flow. owner correction path exists (`setAnchorBps`), which limits the damage to the sales made before the owner reacts.

### L2 (low) every sale moves the anchor by the same amount regardless of size
src/ControllerV1.sol `_moveAnchor`. the move is in bps of cost, so a sale of a statement with a small cost basis moves the anchor as far as a large one while costing proportionally less wei. each buy at the start price multiplies the anchor by 1.25 (10_000 -> 12_500 -> 15_625 ...), the cap 100_000 is reached in 11 buys. a fresh listing then starts at 10x cost and decays over 105 h (sales slow, no loss of funds; the anchor then follows the real sales back down).
how a small-cost statement could exist (not exercised): `buyListing` books cost = price paid (+ tip up to 2 percent), so credits listed on an allowed target at a tiny price enter the pile at a tiny basis; `nextPage` composes the oldest 80, so a whole page needs a near empty pile. whether the credits can be taken back out of the statement depends on the Statements contract (not examined). fix: the same as M1 (a) or (c).

### L3 (low) small buyback slices pay the full gas refund
src/Core.sol `buyback` L889-917 (`SliceTooSmall` at L903, `slice < 2 * maxPay`).
the gas refund is paid whole and the threshold is only twice the largest payment, so anyone can call `buyback` as soon as the pool passes the threshold (every 25 blocks). at basefee >= 10 gwei the threshold is 0.013 eth; measured use about 267k gas + 60k overhead = 0.00327 eth at 10 gwei, so a 0.013 to 0.02 eth slice pays 16 to 25 percent of the slice to the caller (up to 50 percent if the call reaches the 600k cap). the caller's net gain is about its priority fee, the cost to the engine is the refund. at launch settings (slice 0.5 eth) a full slice pays 1.3 percent. inside the owner's amended bound of decision 61 ("at most half the slice"), flagged because the bound is loose for a permissionless call.
fix: raise the factor (for example `slice >= 10 * maxPay` unless the pool already waited a long time), or scale the gas refund with `spent` above a minimum slice. no change needed if "at most half" is the intent.

### I4 (info) house reserve of a buy only listing is set at listing time and lags a raised cap
src/Core.sol `_reserveFor` L688-697 with ControllerV1 `statementPrice` L131-134. reserve = `cost * startCapBps / 10_000`. raising `startCapBps` (or flipping `buyOnly` from false) leaves old listings at the old reserve until `repriceStatement`; a bid at that reserve below the new ask locks `buy` for the auction duration (24 h) and sells at the bid. docs/RUNBOOK.md L483 lists markup, anchor and the mode flip but not a cap raise; in buy only mode the reserve depends on the cap alone, so the markup and anchor entries are for auction mode. `script/SetSettings.s.sol` reprices only after Core `setSettings`, no script covers controller setters. ARCHITECTURE section 7 states the reserve "is never under the live ask", which holds while the cap is not raised. fix: add the cap raise to the RUNBOOK.md list and the REPRICE runbook step.

### I5 (info) buyback sandwich surface unchanged
`swapIn` has no minimum output (docs/ARCHITECTURE section 14, decision 51). the payment is now gas plus a fee instead of 0.5 percent of the slice, so the searcher incentive to call is similar. no new exposure found; not re-measured.

## part 1, attacker models checked with no finding
- caller payment bounds (Core.sol L889-917): paid <= maxPay <= slice/2 in all cases: gas part <= 600k * min(basefee, 10 gwei) = 0.006 eth, fee part <= fee (spent <= budget <= setSlice - maxPay, and `setSlice - maxPay > 0` because slice <= setSlice and slice >= 2 maxPay). `slice - spent - paid >= maxPay - paid >= 0`, no underflow. pot accounting: ethToBuyback = pool - spent - paid, equals the eth that left. fee division rounds down (against the caller). an inflated gas use (ticks crossed, house refund) is capped at 0.006 eth per call.
- reentrancy: `buyback` is nonReentrant, state written before `unlock` and before the final ETH transfer; the payee callback can call nothing guarded (`sellTo`, `skim`, `collectSales`, `buyback` revert). value leaves the Core before the callee runs, so `skim` cannot book `paid`. `buy`: `_busy` set before `sellTo`, anchor written before the external call, refund last, `_busy` cleared after; `sellTo` is nonReentrant and has no ERC721 callback (`transferFrom`). a revert in `sellTo` (live bid) reverts the anchor move.
- `buy` price protection: `msg.value` is the buyer's limit (`Underpaid` otherwise, excess refunded). a front-run that raises the anchor makes the victim revert or pay up to its own `msg.value`; the attacker pays the raised ask for its own statement, so this is griefing without profit.
- arithmetic: `_ask` cannot underflow (start >= 10_000 >= floorBps by constructor and setter bounds: anchor >= 10_000, markup >= 10_000, cap >= markup); anchor <= cap enforced in `setAnchorBps`, `setStartCapBps` (lowers it), `_moveAnchor` (clamp); products fit (cost < 2^128 times start * decay about 5e11). `cost` is nonzero (eth lane credit cost >= 1 wei via `_spend` or `adopt`, page of 80), so the division in `_moveAnchor` is safe. `saleBps` rounds up by under 1 bp for real costs.
- settings that brick a door: `SettingsBounds` requires `buybackSlice >= 2 * (600_000 * buybackMaxBaseFee + keeperFee)`; the maximum of that is 0.13 eth, under the 1 eth slice cap, so every legal combination leaves a valid slice. runtime `maxPay` uses min(basefee, cap) <= the bound's rate. controller setters keep markup <= cap and anchor <= cap in every order; `saleFloorBps` above the controller ask is covered by the `_quote` clamp.
- storage layout: Settings lives at `SettingsStore.SLOT` (3 packed words) in both Core and CoreLib. the delta changes no `CoreState` field. field offsets of `unpack` (word b: slice 0, delay 128, keeperFee 144, maxBaseFee 208; word c: xRateCap 0 ... feeToBuybackBps 192) equal the compiler packing; test/Flow.t.sol random write/read roundtrip passes (67 pass).
- scripts: `SettingsFields` get/set/lo/hi/names are index aligned at 27 entries; `SetSettings.TUPLE` is 27 types in struct order; RUNBOOK.md constructor tuple and jq field list match (27); `_loadSettings`, `_loadSale`, `saleViolation` match the controller bounds; `PostflightChecks._postSettings` compares the full struct (`abi.encode`) and `_postSale` compares all five sale values and `anchorBps == 10_000`; `ControllerV1(core, c.sale)` in NewProd.sol and the verify args use the new Sale tuple `(bool,uint16,uint32,uint32,uint16)`. `script/tools/gen-interfaces.sh --check` rc 0.
- build identity: BUILD_HASH_CORE, CORELIB, CONTROLLER and the CoreLib creation hash in script/Checks.sol equal the artifacts of a fresh `forge build` (test/BuildIdentity.t.sol 5 pass).
- tests run (all pass): BuildIdentity 5, Config 33, SetSettings 10, Flow 67, Sale 74 (9 suites), Fees 76 (9 suites, incl. BuybackPaymentTest 8, BuybackSettingsTest 2).

## part 2, acceptance (owner words from docs/DECISIONS.md)
- 59 (payee 0.75 points, "0.75"): config `router.payeePpm` 112778, pinned by test/Config.t.sol L86. code and config match. ARCHITECTURE section 1 row (parameter, payee 0.75) cites decision 31 and says "owner confirmation pending". MISMATCH: decision 59 records the confirmation.
- 60 (opening bid 100 percent of market, rateCap 10x): `rateStart` 8.9e15, `rateCap` 8.9e16, preflight enforces the x10 ratio. the market price itself cannot be verified from the repo. ARCHITECTURE row (parameter, rateCap) cites 46 and NEXT 11 and says "owner confirmation pending". MISMATCH: decision 60 records the confirmation.
- 61 (gas refund plus keeper fee, "gas refund + keeper fee of like 0.0005", max gas var): config keeperFee 500000000000000 (0.0005 eth), buybackMaxBaseFee 10000000000 (10 gwei), buybackSlice 0.5 eth. code pays `min(measured + 60_000, 600_000) * min(basefee, maxBaseFee) + fee*spent/(setSlice - maxPay)`; `SliceTooSmall` at `slice < 2 * maxPay`; slice bound in SettingsBounds. matches the decision and its amendment. wording gap: FLOW 61 says `min(gas used, BUYBACK_GAS)`, the code and ARCHITECTURE row use gas used + 60,000 (BUYBACK_OVERHEAD_GAS); ARCHITECTURE row is accurate (0.0065 eth launch maximum, 0.065 eth largest settings both recompute). ARCHITECTURE row OK.
- 62 (buy only at launch, anchor, 1.5x, cap 1_000 percent, straight line to 75 percent over 105 h, live from the anchor; amendment: reserve = cap, lower cap lowers anchor): config buyOnly true, markupBps 15000, startCapBps 100000, decayDuration 378000 (= 105 h), floorBps 7500, anchor 10_000 in the constructor. code: start = min(anchor * markup / 10_000, cap); ask line; anchor = max(10_000, mean(anchor, saleBps)) capped; `statementPrice` returns `cost * cap / 10_000` in buy only mode; `setStartCapBps` lowers the anchor. matches. exitAfter 378000 equals the decay. ARCHITECTURE row (behavior, 62, "review pending") accurate. note the in-block behavior of M1 follows from "computed live" and is not described in the decision.
- 63 (compose stays unpaid): no compose payment in the diff. ARCHITECTURE has no row that cites 63; the compose row cites 41 only. MISMATCH (citation).
- other doc drift, all low:
  - docs/DECISIONS.md section 2 table: buybackSlice launch "1 ether", bounds "0.01 to 2 ether"; rateCap "205_540_000_000_000"; code and config: 0.5 eth, 0.01 to 1 eth (and the cross bound), 8.9e16.
  - docs/DECISIONS.md 9.3 L169-170 and decision 17 (row at L152) describe startBps/stepBps/stepEvery and auction mode launch without a superseded mark (decision 62 replaces them; FLOW states superseded text is marked in place).
  - sim/README.md still describes the launch as startBps 11000, stepEvery 3 h, auction mode, and a startBps/stepEvery sensitivity table; sim/engine.js and its test are updated to the new controller.

## verified correct
Settings relayout (27 fields, 3 words), `SettingsBounds` additions, `CoreLib.setSettings` and `unpack`, the interface and ICore additions (`SliceTooSmall`, `Buyback.paid`), controller bounds and setters, the buy path ordering, the config file against decisions 61 and 62, postflight anchor and sale rows, build hashes, verify-args strings, 27 field alignment of SettingsFields and SetSettings.

## not examined
- the economic value of a statement to a buyer (whether the M1 discount is profitable in practice depends on the secondary value of statements).
- Statements contract behavior (decompose or redeem of a page), needed to price L2.
- sandwich profit of the buyback at current pool depth (docs/reviews/REVIEW-sandwich-delegate.md is the last measurement).
- house contract (`createAuction` limits for a 10x reserve), hook and sniper module gas, FeeRouter, CoreLens beyond `priceOf`.
- the full suite, invariants, INVARIANT_DEEP, fork lifecycle (not run by rule).
- sim/ JS beyond the pinned launch values.
