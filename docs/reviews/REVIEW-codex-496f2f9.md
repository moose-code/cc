# Independent audit of `496f2f9` on `main`

2026-10-16. Source was cloned afresh from `https://github.com/ripe0x/cc.git` and checked out at `496f2f9839c0b9e218d02ee4f137ba183038b45c`. The auditor read `AGENTS.md`, `docs/SPEC.md`, decisions 116 to 141, `docs/RUNBOOK.md`, `docs/INTEGRATION.md`, `docs/STATUS.md` and the nine named prior reviews before reading code. No production contract was edited and no mainnet transaction was broadcast.

This file is the report as delivered by the auditor in chat on 2026-10-16; the audit session did not commit it. It is recorded here so later audits can cite it. The fixes it drove: decision 147 (the climb counts unbooked income, PR 48), the spend view (PR 53), the gate fixture by live ownership (PR 37, 54), the stack repoint (PR 31, 36, 39), the one deploy wrapper (PR 35), the bucket-aware acquire and the delta keeper inventory (PR 34), the liveness bounds (decision 143, PR 36). The launch values were kept at decision 141.

## Fork, source identity, and verification method

All fork calls used an Anvil fork of Ethereum mainnet block 26,205,064, after factory creation at 26,202,473, with chain ID 1, `--retries 10 --timeout 60000`, and the deployed ArtcoinsFactoryV2 `0xC27e182ef5D8A1A7C9dd0a27414fEaBA47DF8e3c`. Test-only overlays changed the five stack addresses in `script/config/mainnet.json`, populated `script/config/v2-mainnet.json` with the nine live members, changed the nine `V2_CODEHASH_*` pins and `V2_PIN_BLOCK` in `script/LaunchConfig.sol`, and supplied the live treasury `0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4` in `test/utils/V2Stack.sol`. Those overlays were audit inputs, not proposed contract changes. `STACK=master` was not used.

The live hook has 17,369 runtime bytes and code hash `0x6778602725c0d685c6444cdc70d6616d266939e09d283388a6b79b7bd496ebdc`; the fixture has 17,341 bytes. The auditor compiled `ripe0x/new-material-coin-launcher` at its deploy-record commit `d27c932fe3dee987521897f06972f6efcfdd4cbb` with the `ci` profile. Its runtime is 17,369 bytes and equals the deployed runtime after masking the artifact's 20 immutable slots. The source delta from fixture commit `6d099486` is `HookCalldata.sol` at `d51abc1`: the inner extension must be at least 96 bytes and its byte payload must fit the slice. The hook's fee and refund methods did not change. The live stack shares the fixture's constants hash `0x1b7deab81425bd850537efbb78d999939ab5fe16c424268886a5554d864e23d0` and permission bits `0x28cc`. `test/V2Stack.t.sol` and all 13 `test/V2Port.t.sol` tests passed on this fork.

The unmodified normal suite with the live-stack overlay reported 485 passed, 24 failed, 8 skipped. Most failures start in `Fixture._credits`: a fixed ID list recorded at block 26,158,000 and some IDs had left the CreditStrategy. The remaining distinct failures were stale settings expectations in `RatingReference`, `SaleFloor`, and `SeaportCallerPay`. The simulator parity test passed 1,968 checks. Keeper unit tests passed 31/31. A live-stack rehearsal using `LAUNCH_CONFIG=script/config/mainnet.json` passed its deploy, postflight and trading smoke.

## 1. Security

| ID | Severity | File:line | Claim | Evidence and concrete failure scenario | Structurally correct fix and cost |
|---|---|---|---|---|---|
| S1 | High | `src/lib/CoreLib.sol:544-559`, `:464-470`; `src/lib/SettingsBounds.sol:12-13` | An owner-settable combination can permanently zero the ETH bid. | `dropPerCreditBps=10,000` and `dropFloorBps=0` pass validation. A reference-score credit bought at the 0.025 ETH opening rate sets the stored rate to zero. `_climb` skips recovery when `r==0`; a parity-model run found `ethRate` still zero one hour later with 9.975 ETH in a 10 ETH pot. A zero balance margin opens the balance bid at zero, with the same non-recovery. | Liveness bounds (decision 143): `dropPerCreditBps` at most 9,999, `dropFloorBps` at least 1, `balanceBidMarginBps` at most 9,999. |
| S2 | High, after balance release | `src/lib/CoreLib.sol:845-864, 904-934, 961-969` | The balance bid has a hard 90% par floor, so below-par credits can be bought at materially worse points per token than the market. | With `balanceBidOn=true`, 10 ETH-equivalent module value, par of 0.018 ETH per 433-point credit and market at 80% par, 500 credits / 219,280 points receive 8.2365 ETH-equivalent while their modeled market value is 7.2925, a 12.95% premium. The 10-unit module halves at minute 61.6. | Make the balance floor responsive to independently verified market value, with a safe stale-price/depeg policy; a separate module budget can bound the damage if market data fails. |
| S4 | Medium, owner compromise | `src/Core.sol:1074-1081`, `:1130-1158`; `src/lib/CoreLib.sol:703-736` | The owner key is an unrestricted economic and migration authority; `setController` only probes `nextPage`, and `lockController` does not check ongoing quote behavior. | A replacement can answer the one bounded probe and later return arbitrary prices or stop serving; locking it makes that failure permanent. The owner can also set an arbitrary successor and migrate `ethPot`. `refScore=1`, huge caller fees, zero sale floor and 100% payee share add denial or diversion routes. | Put owner powers behind a multisig with timelock and a separate immediate pause role; require a versioned controller interface and immutable code identity plus a full quote/compose smoke before irreversible lock. |
| S5 | Low | `src/lib/CoreLib.sol:961-969`; `web/app/sell/page.tsx:48-53` | The balance quote can remain positive when the module cannot fund a sale. | `balanceBidOf` replaces a below-floor availability clamp with the floor, while `_fillBalance` reverts `PotTooSmall` when the clamp is below it. The UI can present a payable amount and the holder can pay gas for a revert. | Expose a `balanceBidStatus(id)` that includes executable availability and batch headroom, and use it in UI and keeper. |

Spend-cap assessment. The first purchase bypass is intentional, and the cap controls bucket pace rather than total accumulation. In the rating-priced dump, only 0.13302 / 0.13192 ETH is spent on four credits / 2,552 points before the reference bid drops under market on a 10 / 100 ETH pot. Across all purchases, the measured premium is only 0.84% / 0.80%.

Outflow and control-path audit. Both `sellForEth` overloads share a guarded body: same-block check, bid and bucket spend, pile effect, NFT transfer, then ETH transfer. `buyListing` calls only an owner-allowed adapter's target, limits quote size/gas and verifies one exact NFT plus no net ETH overpayment before spending; Seaport checks one native-price Credit, open order route and allowlisted additional recipients, while Seaport 1.6 itself checks signature/status at execution. The CreditStrategy adapter uses `nftForSale(id)` and its fixed `sellTargetNFT` target. `buyback` reserves the slice before `MANAGER.unlock`, checks a nonzero coin amount and burns before paying the caller. `redeemStatement` unholds before the module call, verifies the token balance increase, and pays the caller last. `migrate` marks retired before ETH and NFT transfers; its separate guard prevents reentry. The forced artist, operator and payee pushes occur after accounting and use bounded gas. These paths revert atomically on failed postconditions. No unprivileged reentrancy or overpay path was demonstrated by the fork checks.

Settings edge sweep. The allowed field widths and coupling rules in `SettingsBounds.sol` avoid arithmetic overflow in the tested score/unit ranges, but they do not guarantee liveness or a sensible price. S1 is a deterministic liveness failure. Setting `refScore` to 1 makes a normal 433-point credit's nominal bid 4.33 million times the rate. Setting `balanceBidMarginBps=10,000` opens its rate at zero. Setting `redeemSlippageBps=10,000` accepts zero proceeds. Near-100% sale cuts leave almost no sale proceeds for pots. These are owner-only choices.

## 2. Intent against decisions 116 to 141

| Decision | Worked example and implementation evidence | Result |
|---|---|---|
| 116, per-point ETH bid | `0.025 × 866/433 = 0.050` ETH for 866 points; `bidOf` uses score/refScore and both intake doors charge that score. | Aligned; a high-score bid can exceed the reference `rateCap`. |
| 117, module custody | At launch no module exists, so redemption gives `NoBalanceModule`; later `available()` bounds a balance sale and `pay` must increase the seller's token balance. | Aligned. |
| 118, swap | A 500-point incoming credit can replace a 433-point pile credit for a 10,000 CC `burnFrom`; the new ID inherits its slot, cost and acquisition time. | Aligned. |
| 119, first launch settings | Credit sale on for 4 h; cost-to-pot 80%; sale buyback 25%; keeper fee 0.0003 ETH at 5 gwei; redemption on but no module; balance margin 1,000. | Aligned. |
| 120, skim | A 1 ETH baseline-volume example skims 0.10 ETH: 0.09 to the Core bounty, 0.01 to the protocol, with `payeePpm=0`. | Aligned on the live hook. |
| 121, one sale decay | A statement reference of 0.025 ETH starts at 0.0375, asks 0.03125 after 6 h, and reaches the 0.025 floor after 12 h. | Aligned. |
| 122, second rate instance | A 0.018 ETH par credit opens at 90%, or 0.0162 ETH-equivalent, and can climb to par when the module is available. | Aligned; S2 is the depeg exposure. |
| 123, sale cuts | From a 1 ETH statement sale: artist 0.025, operator 0.005, buyback 0.2425, buying pot 0.7275. | Aligned. |
| 124, sale-floor order | Launch floor 10,000 bps is below markup 15,000; `setSettings` refuses a floor above live markup. | Aligned while the controller read succeeds. |
| 125, escrow route | A hook push is accepted by `receive`'s two sender comparisons; a claim's ETH is booked whole to the pot. | Aligned; live fork fee/refund tests passed. |
| 126, V2 stack | The code targets V2 interfaces; the live hook matches the launcher deploy commit after immutable masking. The tracked factory and old hash pins pointed to a fixture at the audited commit. | Not launch-ready as tracked at 496f2f9; superseded by PR 31 and 39. |
| 127, renderer | A 30-credit pile renders all 30 in order; a 90-credit pile samples 80 by `prevrandao`. | Aligned, with B2's large-pile cost. |
| 128, pot-scaled ceiling | At 10 ETH and 0.025 per credit, the pot covers 5 pages; multiplier clamps to 4×, making 600 bps idle loosening 2,400 bps per 600 s. The per-minute climb remains 200 bps, unscaled. | Aligned. |
| 129, spend cap | At a 10 ETH opening pot, the first successful purchase snapshots a 0.1 ETH minute budget. Its first purchase passes even if above the budget; subsequent purchases fit that snapshot, and an edit rebases used wei. | Aligned. |
| 130, widened bounds | `dropPerCreditBps=10,000` and `dropFloorBps=0` were valid. | Width policy aligned; S1 demonstrated a liveness violation. |
| 131 | A historical branch/publication instruction, not an engine rule. | Historical. |
| 132, indexer | Ponder indexes engine activity and the web selects indexed reads when healthy. | Aligned. |
| 133, chain fallback | At 6 blocks behind head the app switches to chain mode; an individual indexer query failure quarantines it for 5 blocks. | Aligned. |
| 134, header acquire | A listing at 0.020 with bid 0.025 and enough pot exposes the button and its 0.020 label. | Aligned; bucket headroom was omitted (I2, fixed in PR 34). |
| 135, listings | `/listings` sorts by ask/bid gap, rechecks the best 100 on chain, estimates remaining bids, and caps OpenSea to the cheapest 200. | Aligned as an estimate. |
| 136, prelaunch keeper | Six named doors, estimate/recheck before send, one receipt awaited, separate keystore signer, daily budget. | Aligned in code. |
| 137, 2-minute wait | `listingDelaySec` defaults to 120 and `observe` drops a listing when no longer sweepable. | Aligned. |
| 138, caller compensation | At 8.5 million counted compose gas and 3 gwei, payment is 0.0258 ETH including the 0.0003 tip, bounded by pot. | Aligned. |
| 139, private relay | Default send tries MEV Blocker, then Flashbots Protect with the same signed raw transaction; mainnet refuses an empty relay list. | Aligned in code. |
| 140, dev seed at cap | `Scenario.s.sol` reads live `bucketSeconds` before spaced sales. | Aligned. |
| 141, launch bid values | Tracked launch settings are 500/200/200, cap 100 bps. The published grid's 0.005 market case reproduced at 0.8821/2.7133 ETH on 10/100 ETH pots. | Aligned as configured. |

| ID | Severity | File:line | Claim | Evidence and concrete consequence | Fix |
|---|---|---|---|---|---|
| I1 | High | `script/config/mainnet.json:4-17`; `script/LaunchConfig.sol:17-45`; `docs/RUNBOOK.md:9-11` | The tracked release package still identified the superseded fixture. | The fork needed live addresses, all nine live code hashes, the live treasury and a pin block after 26,202,473 to pass `V2Stack` checks. | Repoint all environment records and pins as one reviewed release candidate (done in PR 31, 36, 39). |
| I2 | Medium | `web/lib/useListings.ts:25-26`, `:137-143`; `web/components/Header.tsx:150-168` | Copy and `clears` state implied `buyListing` is executable from ask, bid and pot alone. | When the bucket budget is exhausted `CoreLib.spend` reverts even if ask < bid and ask < pot. | Incorporate `spendState` and a simulation into acquire eligibility (done in PR 34). |
| I3 | Medium | `docs/SPEC.md:141`; `docs/reviews/REVIEW-129-spendcap.md:20-53`; `sim/market.mjs` | The SPEC promoted a numerical conclusion from 50/50-era assumptions as if it described launch 500/200/200. | Re-running the spend-cap simulator at the current values gives 124 credits, 76,695 points, 0.8954 ETH and first reference crossing at 4 minutes. | Date and scope the historical table, regenerate current launch evidence (done in PR 36). |
| I4 | Low | `docs/RUNBOOK.md:11`, `:236`; `docs/SPEC.md:222`, `:226` | Operator examples contained live-value errors (deploy fee 0.069 vs 0, 0.5% climb vs 2%, pin block 26,158,000). | An owner could overfund or mis-time the sweep. | Generate numerical runbook values from the selected launch record (done in PR 36). |

## 3. Launch values and strategy

Method. The auditor drove the parity-tested `sim/engine.js` Core with 12-second blocks, no new fees or deposits, opening ETH pot 10 or 100, and the tracked launch settings. A reproducible census uses 500 credits cycling through 152, 224, 296, 368, 440, 512, 584, 656 and 728 points, shuffled with seed 129. The rating-priced market ask is 0.018 × max(1, points / 400) ETH; below 400 points it stays at 0.018.

The independent old-grid reproduction used 500 offers at a flat 0.005 ETH over six hours: 0.8821 ETH / 118 credits / 76,328 points on 10 ETH, and 2.7133 / 327 / 177,288 on 100 ETH. These round to EXPOSURE-129-grid.md's 0.88 / 2.71.

| Stress and horizon | Pot | ETH spent; balance paid separately | Credits; points | Bid first under market | Recovery after selling | Pot half-life |
|---|---:|---:|---:|---:|---:|---:|
| 500 rating-priced front-runners, six hours | 10 / 100 | 2.8091 / 2.8080 | 106 / 106; 61,904 / 61,904 | 1.2 / 0.2 min | 14.2 / 14.2 min | none |
| Floor falls linearly to 20% in ten minutes, then holds; 500 offers, six hours | 10 / 100 | 0.9968 / 0.9920 | 131 / 130; 75,712 / 75,344 | 10.2 / 10.2 min against the final floor | 97.6 / 95.4 min | none |
| 35 organic arrivals/hour at 0.018, no refill, 24 hours | 10 / 100 | 9.9887 / 10.2411 | 549 / 563; 237,717 / 243,779 | 30.6 / 30.6 min | not by 24 h / 19.2 min | 688 min / none |
| Wave of 200 reference credits accepting any positive bid | 10 / 100 | 0.6662 / 1.8447 | 200 / 200; 86,600 / 86,600 | 1.2 / 0.2 min against 0.018 | 195.2 / 69.2 min after clearance | clears in 7 / 1 min |
| 13,132 strategy credits, all 371-point at repriced 0.018, 24 hours | 10 / 100 | 9.9819 / 11.8398 | 553 / 656; 205,163 / 243,376 | 0.4 / 0.4 min | not by 24 h / 10.6 min | 601.8 min / none |
| Post-$BALANCE release, 500 sellers take the higher of the ETH or balance bid at 80% of market; 10 / 100 ETH module value | 10 / 100 | 2.9573 + 6.3340 / 3.0015 + 6.2953 balance ETH-equivalent | 500 / 500; 219,280 / 219,280 | Neither route falls under market before clearance | At reference at clearance | ETH none; module: opening block / none |

The first row buys 106 credits and 61,904 points for 2.8091 / 2.8080 ETH, or 22,037 / 22,046 points per ETH. Those same credits have a contemporaneous rating-priced market ask of 2.78568 ETH, so the engine pays only 0.84% / 0.80% above the modeled market. On the 10 ETH pot, only 0.13302 ETH buys four credits before the reference bid is first under market at 1.2 minutes.

Realistic high pot. A 48-hour full-simulator run at the 0.025 opening bid and a 0.018 credit market, with live bid-clearing offers, 150 new offers/hour, 13,132 strategy credits, credit/statement buyers, fee booking and buybacks enabled, no manual funding, using CREDITSTR's recorded 1,557 ETH first-day volume as the analogue:

| Analogue first-day volume fraction | First-day volume | Peak pot across seeds | Pot at 24 h | When peak occurred |
|---|---:|---:|---:|---:|
| 10% | 156 ETH | 18.65 to 18.85 ETH | 8.47 to 8.87 ETH | 8.0 to 9.4 h |
| 25% | 389 ETH | 51.11 to 52.06 ETH | 43.22 to 43.65 ETH | 10.5 to 11.2 h |
| 50% | 779 ETH | 104.76 to 104.89 ETH | 97.68 to 98.94 ETH | 11.0 to 11.3 h |
| 100% | 1,557 ETH | 213.64 to 214.91 ETH | 207.78 to 210.57 ETH | 13.8 to 15.2 h |

100 ETH is a realistic high planning case conditional on roughly half that launch's volume; 200 ETH is a strong-tail case. At one quarter of analogue volume, 50 ETH is the high case and the 10 ETH row the weak-launch case.

One-value sensitivities (each row changes only the named setting from the tracked baseline; dump columns are six-hour ETH outlay for the 0.005 ETH 500-credit offer set on a 10 / 100 ETH pot; flat/hour is filled reference credits per hour averaged over hours 12 to 23 with a continuously available 0.018 ETH ask and a refilled pot):

| Value examined | Dump ETH, 10 / 100 pot | Flat credits/hour | Market-priced dump ETH, 10 / 100 |
|---|---:|---:|---:|
| Baseline: drop 500, climb 200, recovery 200, cap 100, bucket 60, floor 5,000, rateCap 0.075, multiplier 40,000, idle 600, refScore 4,330,000, rateStart 0.025 | 0.8821 / 2.7133 | 23.17 | 2.8091 / 2.8080 |
| Drop 300 bps | 1.5468 / 3.2787 | 39.00 | 4.7426 / 4.7389 |
| Climb 100 bps/min | 0.8821 / 2.7133 | 11.58 | 1.8071 / 1.8060 |
| Recovery 400 bps/min | 1.4559 / 3.6065 | 23.17 | 3.4436 / 3.4414 |
| Spend cap 50 bps/bucket | 0.9119 / 1.7499 | 23.17 | 2.8115 / 2.8080 |
| Bucket 30 sec | 0.8912 / 2.7010 | 23.17 | 2.8087 / 2.8080 |
| Drop floor 3,000 bps | 0.8821 / 1.5117 | 23.17 | 2.8091 / 2.8080 |
| Rate cap 0.050 ETH | 0.8821 / 2.7133 | 23.17 | 2.8091 / 2.8080 |
| Climb multiplier cap 20,000 bps | 0.8821 / 2.7133 | 23.17 | 2.8091 / 2.8080 |
| Idle loosen 300 bps/step | 0.8821 / 2.7133 | 23.17 | 2.8091 / 2.8080 |
| RefScore 5,000,000 | 0.9430 / 2.6276 | 26.83 | 3.1878 / 3.1878 |
| RateStart 0.019485 ETH and rateCap 3× it | 0.8002 / 2.5414 | 23.17 | 2.6984 / 2.6984 |

Recommendation. Keep the launch bid values drop 500, climb 200, recovery 200, spendCapBps 100, bucketSeconds 60, dropFloorBps 5,000, climbMultiplierCapBps 40,000, idleLoosenBps 600 and refScore 4,330,000 (as tracked at 496f2f9; decisions 145 and 146 later converted the unit and removed the floor and cap). The one-value table shows how they trade acquisition pace against six-hour spend. In the market-priced dump the baseline buys 61,904 points at only 0.8% to 0.84% above market. The auditor withdrew an earlier recommendation to cut the multiplier to 2× and rate cap to 2×. On deploy morning, recompute rateStart from the last 24 hours of fulfilled OpenSea sales, normalize each to the reference score, and retain the reviewed cap ratio.

Rule-level assessment. A pot that shrinks because it bought credits close to market has done useful work; the six-hour ETH total alone is not a failure. The rule that remained wrong for the stated acquisition goal is the later balance bid's fixed 90% par floor when redeemable credits trade at 80% par.

| ID | Severity | File:line | Claim | Evidence and concrete consequence | Fix |
|---|---|---|---|---|---|
| L1 | Medium | `docs/reviews/EXPOSURE-129-grid.md:14-35`; `src/lib/CoreLib.sol:297-321` | The published dump limit evaluated ETH leaving the pot without valuing the credits and points acquired. | The 0.018 rating-priced case buys 106 credits / 61,904 points for 2.81 ETH, only 0.84% over the same inventory's market ask. | Reframe the grid around points/ETH, premium to current market, time to under-market bid, and liquidity capacity. |
| L2 | High, after balance release | `src/lib/CoreLib.sol:904-934, 961-969` | At a 20% below-par market, the balance floor forces over-market point acquisition until module liquidity is used. | 500 fills / 219,280 points receive 8.2365 ETH-equivalent against 7.2925 market value, a 12.95% premium. | Market-aware floor/depeg handling and an independent emergency budget. |
| L3 | Medium | `docs/reviews/EXPOSURE-129-grid.md:24-35`; `sim/market.mjs` | "35 organic sellers/hour" is not the same as 35 economically filled credits/hour. | At a firm 0.018 ask and no top-ups, 10 ETH buys 549 in 24 h and queues 305 arrivals. | Publish firm-ask, inventory and funding assumptions beside each throughput chart. |
| L4 | Medium | `script/config/mainnet.json:22-24`; `docs/RUNBOOK.md:21` | A stale deploy-morning median can silently misprice the opening point bid. | A launch on another day without refreshing opens against yesterday's market. | Recompute and record the last-24-hour fulfilled-sale median on deploy morning. |

## 4. Best practice and legibility

Contract and gas review. The purchase doors use checks/effects/interactions; the exception is the intentionally external listing execution before final accounting, protected by the Core guard and exact postconditions. Custom errors generally name the failed condition; `BadQuote` and `BadModule` intentionally collapse failed external calls. The compiled Core runtime was 24,305 bytes, leaving 271 bytes under EIP-170's limit; CoreLib 20,814 and ControllerV1 12,037. The hot-path cost documented in INTEGRATION.md is about 400,000 gas for one direct ETH credit, 470,000 for a strategy listing and 480,000 for a Seaport listing; `test/GasCap.t.sol` passed on the live fork.

Test and gate quality. The normal full suite on the deployed fork produced 485 pass / 24 fail / 8 skip. Twenty-one failures began in stale fixture credit ownership. Three distinct assertion failures remained: `RatingReference.t.sol` expected the removed refScore bound; `Sale.t.sol` assumed statement cost binds the reference, although the controller uses max(cost, valueOf(rating)); `Seaport.t.sol` treated a 10% opening-bid gap at 2 gwei as within 0.0001 ETH of break-even, but measured profit was minus 0.000198538 ETH. The invariant suite has non-vacuity checks for its budget ghost and takes a real snapshot/trial sell in invariant 16; no tautological invariant warranted a finding.

Deployment and integration. ArtifactLoader sorts immutable AST IDs numerically, verifies mask ranges and strips link placeholders before comparing runtime identity. Preflight pins all nine live stack code hashes and the deployer/config hash. The release workflow had two divergent shells at 496f2f9: `deploy.sh` supported only local Anvil and wrote the JSON record; the RUNBOOK mainnet step used Forge directly with no record writer (fixed in PR 35).

Keeper. The live config requires an external keystore and password file, rejects either within the repository, refuses remote impersonation, requires a private relay, and logs sanitized transaction errors. Net keeper profit and a hard daily loss ceiling are not mathematically guaranteed: estimateGas is a pre-send observation. Strategy refresh called unbounded `Credits.tokensOf(strategy)` and then up to 9 Multicall3 batches of 1,500 `nftForSale` reads every 600 seconds (fixed by the delta inventory in PR 34).

Events. The caller payment at the end of compose and redeem has no amount event; the indexer works around it by taking a state snapshot for each Core event.

| ID | Severity | File:line | Claim | Evidence and concrete consequence | Fix |
|---|---|---|---|---|---|
| B1 | High, release gate | `test/utils/CreditIds.sol`; `test/utils/Fixture.sol:378-400`; `test/RatingReference.t.sol:100-114`; `test/Sale.t.sol:225-240`; `test/Seaport.t.sol:472-479` | The deployed-stack gate was red for fixture ownership and three obsolete assertions. | Full suite 485/24/8; ID 40,126 no longer belonged to the impersonated strategy at the fork block. | Fresh-block credit selector with explicit ownership/listing predicates; rewrite three promises (done in PR 37 and 54). |
| B2 | Medium | `src/CoinRenderer.sol:60-80`; `src/interfaces/Interfaces.sol:47` | The renderer reads the entire pile to sample only 80 credits. | About 2,200 gas per additional pile credit; a 13,132-credit pile adds roughly 28.7 million gas and exceeds a 30-million-gas `eth_call` cap. | Expose bounded random-access pile IDs or a deterministic O(80) reservoir index. Post-launch; the renderer is replaceable. |
| B3 | Medium | `script/deploy.sh:14, 81-92`; `docs/RUNBOOK.md:24-28`; `indexer/ponder.config.ts:14` | Mainnet deployment and app record creation were separate manual paths. | A successful contract deployment could leave web/keeper/indexer without a loadable record. | One environment-parameterized deploy orchestrator writing a validated chain-1 record from postflight (done in PR 35). |
| B4 | Medium | `keeper/src/listings.ts:98-124`; `keeper/src/config.ts:211` | Strategy inventory polling scaled with all holdings. | 13,132 held IDs and about 9 batches of 1,500 prices every 600 seconds. | Event-indexed ownership/listing cache with deltas (done in PR 34). |
| B5 | Low | `keeper/src/exec.ts:68-80, 95-130`; `keeper/src/ledger.ts:56-75` | Estimate/recheck and the daily ledger reduce losses but do not make keeper overpay impossible. | A call estimated at 470,000 gas can consume more or revert in the included block. | Reserve worst-case gas-limit × max-fee before sending, reconcile against receipts. Post-launch. |
| B6 | Low | `src/Core.sol:879-886`; `indexer/src/index.ts:34-38` | Caller compensation is an ETH pot state change without its own event amount. | Event-only consumers cannot recover the exact pot delta. | Emit a CallerPaid amount or include it in compose/redeem events. Post-launch; Core bytes. |

Comment and naming findings, one line per affected file, addressed in PR 36 unless noted:

| File:line | Concrete cost | Fix |
|---|---|---|
| `src/Core.sol:874-878` | Said both caller-payment settings are zero at launch, while mainnet.json sets 0.0003 ETH and 3 gwei. | State the skip condition without claiming the launch value. |
| `src/lib/CoreLib.sol:458-460` | Said the multiplier is fixed between fills, but fund/book changes its pot numerator. | State that the last-fill denominator is fixed and the pot can change. |
| `src/ControllerV1.sol:224-226` | NatSpec named the removed 800,000 to 8,000,000 refScore bound. | Point to the actual SettingsBounds rule. |
| `src/CoinRenderer.sol:15-20` | Explained the 80-credit sample but hid that the read walks every pile credit. | State full-pile work. |
| `script/deploy.sh:2-4, 23-26` | Called the default stack "live" although the tracked config named the fixture factory. | Derive the named address from config. |
| `test/utils/Fixture.sol:35-52, 378-400` | Described fixed credits as present at the pin. | Resolve fresh ownership and assert fixture preconditions (PR 37). |
| `test/RatingReference.t.sol:100-114` | Promise described removed numerical bounds. | Name the current invariant bound (PR 37). |
| `test/Sale.t.sol:222-240` | Test called its input "cost" and asserted cost × markup while production prices max(cost, valueOf(rating)). | Use "reference" and assert the max (PR 37). |
| `test/Seaport.t.sol:472-479` | Comment promised a 10% gap breaks even at 2 gwei; measured minus 0.000198538 ETH. | Derive the gap from observed gas (PR 37). |
| `sim/engine.js:178, 185-223` | Unused LOOSEN_MINUTES constant; rateStart comment named 0.0089 ETH. | Remove the dead constant and derive labels from config. |
| `keeper/src/listings.ts:22, 98-124` | CHUNK meant both score and price batch size. | Give each batch its own noun. |
| `web/app/listings/page.tsx:38-146` | "Core would accept" treated a priced listing as executable while the spend bucket could reject it. | Show executable headroom (PR 34). |
| `docs/STATUS.md:15` | Said 445 tests while the recent-fork suite enumerated 517 results. | Generate test totals from the frozen candidate gate. |
| `docs/RUNBOOK.md:21, 139, 236` | 0.5%-per-minute claim conflicted with the 2% launch climb; the 3× cap instruction had to be checked against the refreshed rateStart. | Correct the climb text and retain the reviewed cap ratio. |

## Combined fixes, ordered by severity

1. Before a launch gate: repoint every environment, hash pin, fixture ownership source and runbook to the deployed C27e182e stack; make the full suite and deep invariants pass on a recent chain-1 fork, then freeze/rehearse that same candidate (I1 and B1).
2. Before approving owner powers and widened settings: repair the zero-rate liveness combination, document destructive settings, and protect the owner/controller/successor authority with governance and an emergency pause (S1 and S4).
3. Before enabling the balance bid: establish independent module-spend and depeg rules, and make balance quotes report actual fillability (S2, L2 and S5).
4. Before approving economic parameters: use the realistic 10 / 50 / 100 ETH pot cases to monitor acquisition quality: credits and points bought per ETH, executed premium to current market, crossing time, and remaining capacity. No rolling ETH limiter is justified by the modeled dump.
5. Before publishing integrations: make acquire eligibility spend-bucket aware, refresh the deploy-morning median with a recorded sample, retire superseded numerical copy, and generate a chain-1 deployment record from postflight (I2 to I4, L3 to L4 and B3).
6. After launch, with bounded tickets: make renderer sampling O(80), give the keeper a bounded event-indexed strategy inventory and worst-case transaction budget, emit caller-payment amounts, and repair the per-file comments and names (B2, B4 to B6).

Verdict on launch readiness at 496f2f9. Do not broadcast that commit as tracked. The deployed hook source preserves the required fee/refund/lock behavior and the core outflow checks showed no demonstrated unprivileged drain, but the tracked stack pins were for a retired fixture, the recent-fork full suite was red, and a valid owner setting could zero the bid. The market-priced ETH dump is productive acquisition in this model, not a 2.81 ETH loss. The normal release path is a new reviewed candidate with live-stack data and repaired gate fixtures, a refreshed opening median, and one frozen full/deep/rehearsal pass. The balance-side depeg rule is a separate gate before that bid is enabled.
