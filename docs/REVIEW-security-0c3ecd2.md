# security review of the frozen candidate 0c3ecd2 (credits engine)

reviewer: independent, read only. own clone at /private/tmp/sec-0c3ecd2, commit 0c3ecd2, out/ and cache/ copied from the worktree. the original worktree is untouched. src/ is identical to 97c1866 (`git diff 97c1866 0c3ecd2 -- src` is empty); the delta from the last reviewed code (50cec6f) is decision 71 (`buyListing` pays its caller by the keeper rule) and the rename `buybackMaxBaseFee` to `keeperMaxBaseFee`.

## scope

- src/: Core.sol, ControllerV1.sol, FeeRouter.sol, CoreLens.sol, lib/CoreLib.sol, lib/SettingsBounds.sol, lib/SettingsStore.sol, lib/RateStore.sol, lib/Halving.sol, interfaces/Interfaces.sol (full read; ICore, ICoreLens, IControllerV1, ICoreLib checked by `gen-interfaces.sh --check`, rc 0).
- script/: Deploy.s.sol, Resume.s.sol, Preflight.s.sol, Postflight.s.sol, Lock.s.sol, SetSettings.s.sol, SystemDeployer.sol, SystemResumer.sol, NewProd.sol, Builder.sol, Checks.sol, PostflightChecks.sol, PostflightV2.sol, PostflightPool.sol, LaunchConfig.sol, SettingsFields.sol, Report.sol, tools/check-preflight.sh (delta), config/mainnet.json.
- docs read: ARCHITECTURE.md (all, sections 10 and 14 as the trust boundary), FLOW.md decisions 56 to 71, the four earlier reviews.
- method: line by line read against the attacker models of the brief, one fork PoC (test/sec/SecTip.t.sol in the clone, untracked), targeted `forge test --match-path` runs on the fork (MAINNET_RPC_URL tenderly gateway, FORK_BLOCK 26158000).

result: no critical, high or medium finding. one low finding in the new `buyListing` payment (L1), one low carried open from the acceptance review (L2), five info items.

## findings, most severe first

### L1 (low, intent mismatch) the `buyListing` caller sets part of the measured cost and takes the whole gap between the bid and the listing price
src/Core.sol:528-547. the payment cap is `ceiling - cost` (Core.sol:544-545), where `cost` is the fall of the Core balance during the target call (Core.sol:537-539). the caller writes the target calldata. Seaport 1.6 lets the fulfiller append consideration items beyond `totalOriginalConsiderationItems` (or additional recipients beyond `totalOriginalAdditionalRecipients` in a basic order). the maker signature covers only the original items. the Core is the fulfiller, so it pays those extra items from `value`, and they count as `cost`.

sequence, launch settings (`rateStart` 8.9e15, `rateCap` 2.67e16, keeperFee 0.0005 eth, keeperMaxBaseFee 10 gwei), base fee 1 gwei, PoC `test_poc_keeperTakesTheWholeGapWithASeaportTip` (passes on the fork):
1. a third party lists a credit at 70 percent of the bid: 0.00623 eth against a bid of 0.0089 eth.
2. honest fill: `value` 0.00623, the caller is paid 0.000952 eth (gas plus fee), the pot spends 0.007182 eth.
3. tip fill: the caller appends one additional recipient, itself, of 0.00267 eth and sends `value` 0.0089. `cost` is 0.0089, `paid` is 0. the caller receives 0.00267 eth (the whole gap), the pot spends 0.0089 eth (the full bid), the booked basis is 0.0089.

the engine never pays more than its bid for the credit (`cost + paid <= ceiling` holds, invariants 2 and 7 hold), and the same gap is open through a second route that needs no `buyListing`: buy the listing on Seaport and sell the credit with `sellForEth` at the bid in one transaction. so the loss is the same as the existing arbitrage and no rule of section 10 is crossed. what differs from the record:
- FLOW decision 71 says the payment is "never more than the bid minus the listing price"; the code bounds it by the bid minus the measured cost, which the caller can raise.
- ARCHITECTURE section 1 rows 28 and 35 state the caller earns gas plus 0.0005 eth ("a gap above 0.0014 eth earns about 0.00054 eth"). a caller earns the whole gap. competing bots bid priority fees for whole gaps, so the owner keeper of decision 69 (fills after 10 minutes through a private relay) wins only listings whose gap nobody wants, and the engine keeps a saving only on those fills.
- the caller also runs its own code inside the measured call (the tip recipient receives eth with all gas), so the counted gas can be raised to `BUYLISTING_GAS` and include EIP-3529 refunds (up to 20 percent of the transaction gas). this is bounded by the same gap.
fix: the owner chooses one. (a) state in decision 71 and rows 28 and 35 that any caller can take the gap, so `buyListing` pays at most the bid for a credit and the gap belongs to the fastest caller, the same outcome as an outside purchase followed by `sellForEth`. (b) if the engine must keep the gap on its own fills, add an allowed target adapter that accepts only a basic ETH_TO_ERC721 order for `Credits` with `additionalRecipients.length == totalOriginalAdditionalRecipients` and the Core as recipient, forwards the refund to the Core, and swap it in with `removeTarget(SEAPORT)` and `addTarget(adapter)` (no Core change, targets are unlocked at launch). (b) protects only the `buyListing` route; the `sellForEth` arbitrage stays, so (a) is the consistent statement in either case.

### L2 (low, open from ACCEPTANCE-50cec6f L2) the metadata guard matches one case sensitive marker
script/Checks.sol:301-308, unchanged. on chain id 1 the row fails only for an empty value or a value containing `PLACEHOLDER`. `placeholder`, `TODO`, `tbd`, `ipfs://` and a single space pass. the coin admin can repair both strings with `updateImage` and `updateDescription` until `renounceAdmin`, so the cost is a wrong first impression of the coin and one owner transaction. fix as proposed before: a case insensitive marker and a shape check (scheme prefix and a minimum length), or an owner acceptance recorded in FLOW.

### I1 (info) the Deploy dry run balance row is unreliable, and IGNORE_BALANCE removes the authoritative one
docs/DEPLOY.md step 4 records that the `Deploy` dry run reads the owner balance 0.07 to 0.08 eth too high and passes it. check-preflight.sh:50 drops the step 4 balance row when IGNORE_BALANCE=1. an operator who carries IGNORE_BALANCE=1 from a pin block rehearsal into the launch day run gets no balance gate. failure: the broadcast stops when the owner runs out of eth, the Core and router exist without a launch, Resume finishes it. cost is gas and time. fix: refuse IGNORE_BALANCE when FORK_BLOCK is unset or is the latest block, or print the balance row in the Deploy output with the warning that it reads high.

### I2 (info) the deterministic deployer creations can be front run and stop a `--slow` broadcast
the lens (`CoreLens{salt: LENS_SALT}`, NewProd.sol:22-24) and `CoreLib` go through 0x4e59...956C. anyone can create the same code at the same address once the Core exists (the lens constructor reads `FEE_SOURCE` of the Core), between the Core receipt and the lens transaction. the owner's lens transaction then reverts and forge stops before the launch. the code at the address is the compiled lens either way (CREATE2 binds the init code), and Resume (`_ensureLens`, SystemResumer.sol:85-93) skips an existing lens and sends the launch. a front run of `CoreLib` before the first transaction makes Deploy fail with a moved nonce; rerunning preflight and Deploy recovers. cost is gas only. no change needed; the runbook can name the case.

### I3 (info) the stored rate has no lower bound (status of REVIEW-security finding 7)
CoreLib.sol:248 and :220, unchanged. with a thin pot a seller who gives credits away for dust still drops the price state by `dropPerCreditBps` per fill, because `_spend` drops the stored rate and the clamp applies to the read only. reaching 0 from 8.9e15 takes about 7,300 credits; halving the bid in one minute bucket takes about 139 credits (about 1.2 eth of credits at the opening bid) and needs the pot empty first. the attacker pays with its credits and the engine keeps them. `setRate` restores the bid.

### I4 (info) residual `ethToBuyback` below `2 * maxPay` cannot leave a retired Core
Core.sol:753. after `migrate` the retired Core books only statement sales into `ethToBuyback`. a remainder under `2 * (BUYBACK_GAS * min(basefee, keeperMaxBaseFee) + keeperFee)` reverts `SliceTooSmall` (about 0.0016 eth at 0.5 gwei with the launch fee). the owner lowers `keeperFee` to 0 to release almost all of it. dust size.

### I5 (info) stale text in code and runbook
- Core.sol:181-183: `PAGE_GAS` comment says a full page costs about 73,000 gas and the cap is about 7 times that; ARCHITECTURE section 14 item 38 measures 238,062 cold.
- Core.sol:422: the `_ask` comment ("bounded read of a module...") sits above `_st()`.
- PostflightChecks.sol:238: the row detail says 9 immutable sites of the controller; DEPLOY.md:119 and test/PostflightSlots.t.sol say 13.
- DEPLOY.md:119 says the split start may be "at most an hour after" the window; `_postSplitStart` (PostflightChecks.sol:478-497) requires it exactly.

## status of earlier findings

REVIEW-security.md (1e2c4b3):
- 1 config hash binds the config only: fixed. six build pins (Checks.sol:73-79, rows at 360-381), the git rows in check-preflight.sh. BuildIdentity 5 pass after a fresh `forge build` of the clone.
- 2 masked identity hides divergent library sites: fixed. `runtimeSlotsMatch` (PostflightV2.sol:158-180) checks every library site and every immutable site (PostflightChecks.sol:380-403, controller at 233-239). PostflightSlots 8 pass.
- 3 change flags honored by Deploy and Resume: fixed (`_requireNoChangeFlags`, SystemDeployer.sol:178-184, called first in Deploy.s.sol:23 and Resume.s.sol:15).
- 4 `sellForEth` without `minOut` on a thin pot: accepted by decision 58 (ARCHITECTURE row 42).
- 5 reserve wording: moot, the house is removed (decision 68).
- 6 stale `rateStart` range: fixed (ARCHITECTURE item 22).
- 7 no lower bound on the stored rate: open, info (I3).

REVIEW-security-0d86ee7.md:
- M1 in-block anchor erosion: fixed. a sale at or below the anchor leaves it (ControllerV1.sol:217-218).
- L2 anchor move independent of size: mitigated by `anchorMinCost` (decision 70) and accepted (items 44, 46).
- L3 small buyback slices pay the full refund: accepted by the decision 61 amendment (payment at most half the slice).
- I4 house reserve: moot. I5 buyback sandwich: accepted (item 17).

REVIEW-d77b82c.md:
- F1 dust pot anchor pump: mitigated by `anchorMinCost`; the priced residual is ACCEPTANCE L1, accepted under decision 68.
- F2 untested buyback gas cap: fixed (Fees.t.sol:1178); the new `BUYLISTING_GAS` cap has its test (CoreUnit.t.sol:761).
- F3 doc drift: partly fixed; remaining drift in I5. I1 and I3: runbook and economics, unchanged. I2 (caller payment up to 1.37 eth per compose at the largest settings): open, owner setting, off at launch.

ACCEPTANCE-50cec6f.md:
- L1 priced anchor pump: accepted (decision 68). L2 metadata guard: open (L2 above).
- D1 controller CORE sites: fixed in DEPLOY.md:119 (thirteen); the postflight row text still says 9 (I5). D5 "market value of a page": fixed. D2 to D4, D6, D7: documentation, not rechecked line by line.
- E1 no deep run: closed by docs/DEEP-RUN-97c1866.log (src unchanged since 97c1866).
- C1, C2: owner confirmations, outside code.

## verified correct

- custody: eth leaves only through `sellForEth`, `buyListing`, the three caller payments, `buyback` (swap and payment), `migrate`; exit token through `sellForExitToken`, `buybackExit`, `migrate`; credits through `compose` (into the statement), `migrate`, `rescueNft` (outside piles); statements through `sellTo`, `exitStatement`, `rescueNft` (no record); coin through `rescueCoin` and burns. the only Core approval is Credits to Statements. no ERC-1271, no fallback, no Seaport or conduit approval, so a Seaport call made by the Core moves at most `value` of eth. every eth outflow is subtracted from the pot it comes from (`_spend`, `_payCaller`, `ethToBuyback += slice - spent - paid`, `_moveEth`).
- pot accounting: `ethPot + ethToBuyback <= balance` and `xPot + xToBuyback <= exitToken balance` on every path; a donation or forced send inside a measured call lowers the measured cost and keeps pot and balance equal (`_buy` asserts in Seaport.t.sol). PoC fill: pot and balance fell by 0.0089 eth each.
- `buyListing` payment: `cost <= value <= ceiling <= ethPot` with `ethPot` frozen during the measurement (router flush reverts `Measuring`, every door guarded), so `cost + paid <= ceiling`, no underflow in `ceiling - cost`, payment last under the guard.
- reentrancy: solady storage guard (v0.1.25, slot 0x929eee149b4bd21268) on every state changing door; the library `_enter` and `_leave` use the same slot and value convention; `receive` reverts only for the router during a measurement; `unlockCallback` takes the pool manager only and only the Core can be the unlocker of its own callback; ControllerV1 `_busy` covers the refund callback; FeeRouter `_busy` covers payee callbacks (100,000 gas each).
- arithmetic and rounding: `_climb` cannot overflow or revert (target <= 1e18, `lnWad` argument >= 1e18, `expWad` input < 42e18); `drop`, `Halving.halve` (zero after 256 half lives), exit quote `mulDivUp`, exit bid and sale splits round toward the Core; the controller floor clamp uses the Core floor formula.
- storage: `CoreState` repeats the Core declaration order field by field (no inherited storage; solady guard at its own slot); Settings 24 fields pack into 4 words and `unpack` offsets match (a: 0..144, b: slice 0, delay 128, keeperFee 144, keeperMaxBaseFee 208, c: x fields 0..48, half life 64, slice credits 96, rateCap 112, lane shares 176 and 192, d: callerFee 0, callerMaxBaseFee 64); `RateStore` and `SettingsStore` slots cannot collide. CoreLayout 3 pass.
- settings bounds: every combination keeps the buyback slice above twice the largest payment, the exit opening price at or above 1e12 at set time, the rate bounds on `rateCap`; no in-bounds combination bricks `migrate` (exit token failure is skipped and retried, eth goes to an owner chosen successor).
- scripts: Deploy requires CONFIG_HASH, CONTROLLER_NONCE, DEPLOYER equal to the signer, the factory owner, all preflight rows, then the postflight of the simulated result; addresses of controller, router, Core, lens and coin are predicted and checked after each creation; the Core constructor rejects a router without code, so a moved nonce costs gas only. Resume refuses a Core it did not create (row "router: created by the deployer one nonce before the Core") and runs the postflight before anything is sent. the lens is bound by its CREATE2 address. SetSettings tuple and SettingsFields are 24 fields in struct order. mainnet.json values equal `Mainnet.defaultSettings` and `defaultSale`; `rateCap == 3 * rateStart`; the empty `image` and `description` fail preflight on chain id 1.
- targeted tests, all pass on the fork: BuildIdentity 5, CoreLayout 3, Seaport 29 (3 suites), PostflightSlots 8, CoreUnit 78, Fees 76, Config 32, Resume 22, Migrate 35, CallerPay 12, Rescue 12, Adopt 21, Sale 67, ReviewDeploy 18, PullFees 17, SecTip PoC 1.

## not examined

the full suite, invariants and INVARIANT_DEEP (barred by the run rule); a real broadcast and `--slow` against a live node; the live CreditStrategy (whether `sellTargetNFT` refunds excess value, which decides whether L1 also applies to that target), Statements and Credits internals (admin powers over the Credits approval given to Statements), the v2 hook, escrow, locker and factory beyond the pinned reads; CoreLens beyond its constructor and the postflight rows; sim/, project/evidence.json, script/director.py; EIP 7702 authorizations of the owner on chain id 0; the market behaviour behind the keeper economics of decisions 69 and 71.
