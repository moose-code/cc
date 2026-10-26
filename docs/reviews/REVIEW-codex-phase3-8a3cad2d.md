# Phase 3 independent audit: 8a3cad2d

2026-10-25. Scope: ripe0x/cc PR 190, commits 0e72ead1, 0d133b1d and 8a3cad2d against 3af76e48. The later remote docs commit 8c604fa3 is outside this audit. Work branch: codex/phase3-audit-8a3cad2d. The five new deployments, their owner script, generated and handwritten interfaces, and the keeper's new floor door were reviewed. Unchanged live Core and Phase 2 contracts were read only for integration. Every chain send in this audit went to a local Anvil fork of block 26,251,200 with the owner impersonated; no mainnet send or secret was used.

## Verdict

**Phase 3 service activation: do not treat this candidate as ready.** The keeper's market-floor post is deterministically rejected after simulation, so the posted floor becomes stale. A partial sweep-share setting also lets public callers allocate more than the configured fraction of working surplus. The planned 2,500 bps controller spread is not pinned by deploy or readback, and the current tests use the earlier 1,000 bps setting. The local fork sequence sent successfully through ENS; its final readback failed 5 of 37 rows because the readback assumes the bid is still off and the price posts are fresh.

## Security

### SEC-01 | High | keeper/src/decide.ts:687-701; keeper/src/exec.ts:123-124

**Claim.** The new unpaid postMarketFloor door never passes the executor's post-simulation check when gas has a positive cost. Its case is missing from recheck's unpaid-door branch, so it falls through to the profitable-payment rule with payment zero.

**Test evidence.** The affected keeper tests passed 58/58 but test/decide.test.ts:619 checks only decide(), not recheck(). Direct execution of the source function with measured gas 60,000, base fee 0.3 gwei, tip 0.05 gwei and a 0.00005 ETH refresh cap returned ok=false, payment=0 and cost=23,250,000,000,000 wei, below that cap. Command and result are in Verification.

**Failure scenario.** After migration posts 0.0087 ETH, OpenSea observes a moved bid or the post ages past half of six hours. decide() queues postMarketFloor. Executor estimates gas and calls recheck(); it skips the transaction every time. After six hours, ControllerV3 rejects sales whose ask the posted term would lift with StaleFloor. The keeper is not a treasury spender, so this is availability and sale-pricing failure, not BALANCE custody loss.

**Minimal structural fix.** Put postMarketFloor in recheck's unpaid controller-door branch and add a test that takes its decided call through recheck and Executor.run().

### SEC-02 | Medium | src/adapters/BalanceTreasuryV2.sol:416-427

**Claim.** With shares summing below 10,000 bps, repeated public sweeps allocate the same original surplus again. Each call uses the remaining surplus as a new base, while the comment and the owner's share setting imply the unshared part stays working.

**Test evidence.** A temporary fork test, test_repeatedSweepAllocatesBeyondTheConfiguredShare, passed at the live pin. After migration it changed the market share to zero, unallocated that bucket, and called sweep twice. The bid's 2,500 bps share received its first 25% and then another positive 25% of the remainder; the total exceeded 25% of the original surplus. The temporary test was removed after execution. Current launch shares are 2,500 + 7,500 = 10,000, so this path needs a later allowed owner share change.

**Failure scenario.** Working funds are 100 above a zero cushion and a spender has the sole 5,000 bps share. Any caller sweeps 50, then 25, then 12.5, approaching all 100 instead of retaining 50 working. The configured cushion remains untouched, but every working unit above it can eventually enter that spender's bucket.

**Minimal structural fix.** Track newly sweep-eligible receipts so one tranche is shared once, or require total shares of 10,000 whenever sweep is enabled.

### SEC-03 | Medium | packages/engine/src/opensea.mjs:494-505

**Claim.** An invalid or absent consideration quantity is silently replaced by one, which can overstate a collection offer's per-item bid. The parser also accepts an offer with an expired endTime.

**Test evidence.** Executing fetchCollectionBid with a mocked 0.09 ETH WETH offer returned 0.009 ETH when startAmount was "10", then 0.09 ETH when it was "garbage". The command and output are below. Trait offers were filtered. The keeper's current execution defect in SEC-01 stops automatic posts, but does not make this input rule correct.

**Failure scenario.** A malformed API response describes a ten-item, 0.09 ETH total offer but omits or corrupts startAmount. The keeper treats it as a 0.09 ETH per-item observation. Once SEC-01 is fixed, a nonzero post can move 10% per 600-second post toward this false price; an unseeded first post can jump to it. Elevated asks can make Credits unsellable. An expired offer can be selected as best although no buyer remains.

**Minimal structural fix.** Reject offers without a positive integer quantity and reject offers whose time or active status cannot be established. Keep the last valid observation rather than inventing a quantity.

### SEC-04 | Medium | src/ControllerV3.sol:584-606; keeper/src/decide.ts:383-390

**Claim.** The posted floor does not guarantee an ask above the current executable collection bid plus spread after a rapid bid rise. Both keeper and controller clamp each keeper post to 10% above the last post.

**Test evidence.** Executing postMarketFloorNeeded with a 0.0087 ETH last post and a 0.02 ETH observation produced a 0.00957 ETH target. At the shipped 300 bps spread, the term asks 0.0098571 ETH, below 0.02 ETH. It needs nine paced upward posts to reach 0.02 ETH. This is arithmetic on the exact source; an actual OpenSea execution was not placed.

**Failure scenario.** A low-point Credit has points and cost floors at or below 0.0098571 ETH, while a genuine 0.02 ETH flat collection offer remains executable. A buyer purchases it from V3 at 0.0098571 ETH and tenders it to the offer, a gross 0.0101429 ETH difference before fees and gas. A compromised poster can create a similar gap by stepping the floor downward: from 0.0087, one step yields a 0.0080649 ETH ask, six steps in an hour about 0.00476224 ETH. The keeper key has this price-feed power but no treasury draw authority.

**Minimal structural fix.** If the collection bid is a strict lower bound, pause affected sales while a verified observation exceeds the clamped post, or permit a verified upward jump while retaining the downward clamp. State explicitly if a lagged floor is instead the accepted rule.

### SEC-05 | Medium | script/Phase3.s.sol:160-179, 326-356

**Claim.** Deploy copies ControllerV2's spread once, but neither the deploy preview nor the later readback checks the required 2,500 bps spread. The documented V2 spread send is required before the switch, which does not ensure it occurs before deploy.

**Test evidence.** The pinned live fork's V2 spread was 1,000. The 19 existing Phase3 tests passed using that setting, and test/Phase3.t.sol:330 asserted an 11,000 floor multiplier. Source arithmetic at ControllerV3.sol:710-717 gives 11,000 with a 1,000 spread and 10,000 Core cap, versus 12,500 after a 2,500 spread. The Anvil migration readback passed 37/37 without a spread row.

**Failure scenario.** The owner deploys V3 while V2 is at 1,000, then raises live V2 to 2,500, then runs migrate and the Core cap send. V3 retains 1,000 and sells qualifying Credits at 1.1 par rather than the intended 1.25 par. All existing deployment readback rows can pass.

**Minimal structural fix.** Make 2,500 an explicit deploy precondition or constructor input independent of the current V2 value; check the stored V3 spread and floor multiplier in migration readback. Exercise the planned 2,500 setting in a focused fork test before deployment.

### SEC-06 | Low | src/ControllerV3.sol:577-590

**Claim.** The downward step uses floor division, so a 1 wei prior post permits a 0 wei post despite stepBps=1,000. A zero prior post is then treated as an unrestricted first post.

**Test evidence.** At last=1 wei, lo=floor(1 × 9,000 / 10,000)=0. The poster can post zero after the cadence, then an arbitrary uint128 floor at the next cadence. From the shipped 0.0087 ETH seed, repeated zero targets reach zero after 332 ten-minute steps, about 55 hours 20 minutes. No live keeper transaction was executed.

**Failure scenario.** A compromised keeper holds the poster key and steps the floor down to 1 wei, posts zero, then jumps it high or low without a bounded step. At zero, the market term drops out and low-point Credits sell on their other floors. This does not lower their asks below the points or Core-cost terms.

**Minimal structural fix.** Round the lower bound upward, and use a separate hasPosted flag so zero does not reopen the first-post exemption.

## Best practice

### BP-01 | Medium | script/Phase3.s.sol:237-253, 316-322

**Claim.** STEP=bid has no decoded preview or readback before its owner send, and the migrate preview omits treasury token/coin identity checks that v1 later performs. The bid step can set its switch on before activeAt even though spending still refuses until activation.

**Test evidence.** A no-keystore Anvil STEP=bid dry run immediately after migration exited 0, estimated 52,934 gas, and printed no phase-3 preview rows. BalanceTreasuryV2.sol:635-641 does not check activeAt in setSpenderOn; draw does check it at line 398. A later local bid send after one day succeeded. The migrate preview checks t.core and predecessor but not t.balanceToken or t.ccToken before _moveTreasury changes the Core module.

**Failure scenario.** An operator uses STEP=bid early or with stale address environment variables; the script starts broadcasting once the signer matches the Core owner, without showing the selected module, spender registration, activation time and expected bid identity. An incorrect treasury token can clear the custom migrate preview and be caught only by v1.migrateTo during full simulation. The repository's no-keystore dry-run requirement reduces this operational risk, but does not make the preview claim true.

**Minimal structural fix.** Before _start, assert the selected module, exact immutable bindings, registered spender, expected code identity and activeAt, then print and require a preview; read the switch back after the send. Add token/coin identity to _migratePreview.

### BP-02 | Medium | script/Phase3.s.sol:326-407

**Claim.** STEP=readback is hardcoded for the immediate post-migration state and fails after the script's own delayed bid step. It also requires the market floor and CC reference to remain fresh after a one-day activation wait.

**Test evidence.** Local Anvil deploy and migrate succeeded; migrate readback passed 37/37. After the Core cap send, a one-day warp, bid enablement and ENS, STEP=readback exited 1 at 32/37. It rejected the intended bid-on state, the stale floor and the stale CC reference. Its "redeemer 2 prices a burn" row failed as a consequence of the stale reference.

**Failure scenario.** The owner follows every documented step and runs readback the next day. The tool reports a failed deployment even though the selected modules, pinned code and custody remain correct. The failed rows obscure a genuine mismatch in the same output.

**Minimal structural fix.** Make readback accept an explicit expected phase, and distinguish immutable wiring from time-sensitive service freshness. Verify the bid-on state and live floor/CC refresh in their respective stages.

### BP-03 | Low | src/adapters/CreditBid.sol:150-160, 208-210

**Claim.** quoteCredit can return a positive quote that sellCredit cannot settle, because it checks seller payout against drawable() and total payout against bucket, but not seller plus artist against remaining period and lifetime room. The two draws are individually capped.

**Test evidence.** Source path: set perPeriod equal to the seller payout, keep bucket at least payout plus 3% royalty, and query quoteCredit. It returns positive. sellCredit's seller draw consumes the period, and the royalty draw reverts OverCap. No temporary fork execution was made for this case. EVM atomicity rolls back transfer, adoption and seller payment, so the artist is not silently omitted.

**Minimal structural fix.** Quote against aggregate period and lifetime room while checking each draw's perCall cap, or expose a quote that clearly states it is not execution-safe.

### BP-04 | Low | test/Phase3.t.sol:247-275, 277-338; keeper/test/decide.test.ts:619-659

**Claim.** Three test promises exceed their assertions. test_breakEvenRunKeepsWorkingAboveTheCushion only asserts working >= cushion and solvent over two cycles, not economic break-even. test_controllerV3BandLooseningAndViews does not call priceOf or atFloor despite saying every consumed view answers. The keeper postMarketFloor test stops at decide and misses recheck, where SEC-01 lives.

**Test evidence.** The named tests passed in the 19/19 Forge and 58/58 affected keeper runs. Core.sol:625-629 can record zero when priceOf fails, so a held Statement alone does not establish a nonzero composition price. At bid cap 10,000, a 100 BALANCE par Credit pays 100 to the seller plus the live 3% artist royalty; conversion at exactly par returns 100 before the 10% contribution to the switched-off pro-rata bucket. Total custody can decline by 3 despite working staying at the cushion. The cushion is a withdrawal/allocation bound, not a profitability bound.

**Minimal structural fix.** Assert custody and bucket changes for an economic scenario, check a composed Statement's priceOf and resulting recorded price, and take the new keeper call through recheck and executor.

### BP-05 | Informational | docs/STATUS.md:43-52; docs/DECISIONS.md:505-515; docs/specs/PHASE3.md:38-54

**Claim.** Status still describes migrate as 15 sends, while the exact local rehearsal produced 18 successful receipts: v1 off, Core module switch, v1 migration, cushion, bid register/share, market register/share, bid settings, v2 switches, sweep, two pool keys, CC quote, Statement sales, floor settings/post, controller switch. The pre-switch V2 spread of 2,500 with the still-live Core cap of 11,000 yields floorMultBps 13,750, not 12,500; it becomes 12,500 after the later Core cap send. The PHASE3 specimen band of 8,500–11,500 is superseded by decision 285's 8,000–10,000. Decision 284's "including artist royalty" per-call cap is now per draw under decision 292; one sellCredit can consume seller amount plus royalty across two draws.

**Test evidence.** The local migration's broadcast receipts were 18/18 status 0x1, actual gas 1,941,849. The phase-3 fork asserted 11,000 at its historical 1,000 spread. The code applies perCall separately in _useCaps().

**Minimal structural fix.** Reconcile the operator packet's transaction count and both spread states, and state whether the 20,000 BALANCE limit applies to each treasury draw or the complete bid fill.

### BP-06 | Informational | src/adapters/BalanceTreasuryV2.sol:706-738; test/Phase3.t.sol:427-453

**Claim.** The last-resort successor handshake checks self-reported getters and selected-module status, not implementation identity or an import postcondition. The test uses another real BalanceTreasuryV2 and cannot disprove a lying successor.

**Test evidence.** Source path: an owner-selected hostile successor reports the expected core, coin, BALANCE token, predecessor and off switches, accepts the transferred custody, and makes receiveMigration a no-op. Old v2 has already cleared the exported pro-rata bucket. This needs owner selection; it is not a permissionless caller path. No hostile successor was deployed in the fork.

**Minimal structural fix.** Pin and rehearse the exact intended successor code before a future migration and assert its custody and imported bucket after receiveMigration. Disclose that the single owner can transfer the non-debt/non-committed custody through this path.

## Properties attacked without a demonstrated break

1. **Custody and spender caps.** With the fixed live BALANCE token at the pinned fork, the 19 Phase3 cases and source accounting found no unregistered draw, cross-bucket payment, use of debt/committed backing, or cushion spend by allocate, sweep or withdrawWorking. draw and redeemCC decrement the originating bucket under the treasury's transient lock, and exact seller payment checks both treasury and recipient balances. periodUsed and lifetimeUsed are bounded against uint128 caps before their casts; the 24-hour reset is measured from periodStart; unallocate bumps the spender epoch. drawable is the minimum of its bucket, perCall, remaining period and remaining lifetime when on, active, selected and unpaused. A hostile registered spender can send its own bucket to any permitted recipient, within each draw/period/lifetime cap after the one-day delay, and no more; owner cap/share/allocation changes can expand that authority. The keeper signer has no draw authority. A BALANCE token that debits the treasury by amount but credits a recipient less is outside the observed live-token behavior: _payOrAccrue measures custody decrease rather than recipient receipt, so its "undelivered" number would undercount under such hypothetical fee semantics. The exact draw reverts on a short recipient receipt.
2. **Reentrancy and bid atomicity.** The separate keccak256(name)-1 transient lock slots match their source values; the bid lock spans credit transfers, Core.adopt and both sequential draws, while each treasury draw takes and releases its own lock. The second draw's revert rolls back the first draw, Credit transfers and adoption. claim/release decrement their earmark before transfer and revert atomically on a failing recipient. The 60,000 gas accrual reserve leaves gas after a bounded transfer call for custody read and owed writes under the present token behavior; this audit did not run a gas-exhaustion campaign against a malicious replacement token. No route found for BALANCE or Credits to rest in CreditBid after a successful fill.
3. **Bid bounds.** The bid is at most score × 1e14, and its eth cap rounds down through fullMulDiv at the protected controller sale value. _fillBps reclamps at every fill to strictly below the live floorMultBps, including after setBid or a Core cap change. ControllerV2 resales have no V3 creditSoldAt record; until the six-hour Core return lock has elapsed after switch, their buyer can attempt the new bid. The script's one-day spender activation blocks the actual draw during that window even if its switch was turned on early. The migrated initial bucket was 90,761.0653636 BALANCE; a compromised CreditBid is limited by that bucket and its 20,000 per-draw and 60,000 per-day caps unless the owner changes them.
4. **Migration and exchange window.** The live v1 handshake checks the selected successor, same coin and token, predecessor, off switches and unmigrated state. v2 receiveMigration checks actual custody against imported pro-rata backing plus every earmark. v2 migrateTo retains debt and committed payouts, exports the pro-rata bucket with the rest of custody, sets migrated before transfer and permanently refuses later switch-on; claims and releases remain payable. Between setBalanceModule(v2) and v2.setSwitches(true,true), Core's BALANCE exchange sees available()=0 and fails its payout path, rather than spending lost funds. This is temporary unavailability across distinct owner transactions; the local full migration completed. Hostile successor limitations are BP-06.
5. **Market-floor mechanics.** The deployed bounds are spread <=10,000, step 1..10,000 and minSeconds >0. A non-poster reverts, and the owner is unpaced/unclamped. maxStale=0 or never posted yields (0,true); a stale post reverts only when its term would lift that Credit. The additive max cannot lower the points or Core-cost ask, and buyCredit/buyCredits revert atomically on a stale lifted Credit. A floor of 1 wei is economically inert before it reaches zero. A very high post lifts asks and can stop stale lifted sales but does not itself transfer custody. A dark keeper leaves existing posts to age; the points-priced Credits continue to sell. The term does not enter the Core's eth bid, BALANCE exchange, compose, or Statement pricing paths. SEC-01, SEC-04 and SEC-06 qualify the claimed collection-bid protection.
6. **Controller and deployment identity.** The unchanged Core probe signatures nextPage, atFloor, pastWindow, priceOf, valuePerPoint, balanceClampFor and markupBps remain present; the 19 focused cases exercised most, with the priceOf assertion gap in BP-04. Runtime ControllerV3 is 21,635 bytes, 2,941 below EIP-170. The five creations used plain CREATE and CreditBid was constructed on the new treasury. Every scripted send is inside startBroadcast and _start refuses a non-owner signer; migrate's five contract pins matched masked live code. ENS's registry owner and selected-module checks passed on the fork. A wrapped name would fail the registry-owner equality; an owner-initiated resolver swap to another code-bearing resolver could clear the current generic-code check because the expected resolver address is not pinned. No secret was printed in the commands or logs inspected.
7. **Keeper input and ABI boundaries.** The keeper requires an observed bid, applies cadence and step clamp, and drops an observation older than three refresh periods. An OpenSea outage leaves the last observation briefly, then no post; a 429 gets one 1.5-second retry; a revoked key behaves as an API failure. The key is read from keeper configuration and no inspected path logs it. Source-to-artifact comparison matched 13 ControllerV3, 32 treasury v2 and 17 CreditBid handwritten ABI entries, including spender tuple order and indexed event fields; generated interface check exited 0. BuildIdentity's 15 artifact pins and production profile checks passed 7/7. SEC-01 and SEC-03 remain.
8. **Economics and authority.** From 570,081.5490344 BALANCE custody, migration left a 57,037.28758 pro-rata bucket, 90,761.0653636 bid bucket, 272,283.1960908 market bucket and 150,000 working cushion. Initial sweep shares were 25% bid, 75% market, 0% pro-rata; later conversions still contribute 10% to the off pro-rata bucket. No source path found for a non-owner to extract outside its registered rule/bucket. The owner can alter shares, caps, switches, cushion and working withdrawals, and can replace the controller/module before their locks; a future successor remains owner-selected. The bid/composition/conversion/sweep loop can lose the artist royalty and other costs even while the cushion invariant passes.

## Verification commands and results

- git diff --name-only 3af76e48 8a3cad2d: 28 changed files; 19 changed security-source items inspected, plus docs and tests. git status --short stayed clean after removing the temporary proof.
- MAINNET_RPC_URL=https://mainnet.gateway.tenderly.co forge test --match-path test/Phase3.t.sol: exit 0, 19/19 at block 26,251,200. The first sandbox run failed DNS; the first approved retry with LIVE_STAGE=B failed setup because that legacy fixture redeploys an obsolete Phase 2 state whose zero quote trips ControllerV3's referenceTriple guard. The successful run omitted LIVE_STAGE and used the actual deployed Phase 2 contracts.
- MAINNET_RPC_URL=https://mainnet.gateway.tenderly.co forge test --match-path test/BuildIdentity.t.sol: exit 0, 7/7, including all 15 pinned artifacts.
- script/tools/gen-interfaces.sh --check: exit 0, no diff.
- MAINNET_RPC_URL=https://mainnet.gateway.tenderly.co forge test --match-path test/Phase3AuditPoC.t.sol --match-test test_repeatedSweepAllocatesBeyondTheConfiguredShare: exit 0, 1/1 at the live pin; temporary test removed.
- cd keeper && node --test test/decide.test.ts test/controller-v3.test.ts test/executor.test.ts: exit 0, 58/58. cd keeper && npm run typecheck: exit 0. cd web && npx tsc --noEmit: exit 0. Offline npm ci supplied each worktree's missing ignored dependencies without changing lockfiles. The whole keeper npm test was not used because the repository guard reserves broad suites for a frozen candidate.
- cd keeper && node --input-type=module -e 'import {recheck} from "./src/decide.ts"; const r=recheck({door:"postMarketFloor"},{},undefined,60000n,{baseFee:300000000n},{doors:{postMarketFloor:{maxBaseFee:3000000000n,tip:50000000n}},refresh:{maxCostEth:50000000000000n},margin:50000000000000n}); console.log({ok:r.ok,costWei:String(r.cost),paymentWei:String(r.payment)}); if(r.ok || r.cost>50000000000000n) process.exit(1)': exit 0, {ok:false,costWei:"23250000000000",paymentWei:"0"}.
- node --input-type=module -e 'import {fetchCollectionBid} from "./packages/engine/src/opensea.mjs"; const offer=(q)=>({price:{currency:"WETH",decimals:18,value:"90000000000000000"},protocol_data:{parameters:{consideration:[{startAmount:q}]}},order_hash:"0xabc"}); for(const q of ["10","garbage"]){globalThis.fetch=async()=>new Response(JSON.stringify({offers:[offer(q)]}),{status:200}); const r=await fetchCollectionBid({key:"dummy",slug:"demo"}); console.log(q,String(r?.bidWei))}': exit 0, 10 => 9,000,000,000,000,000 wei; garbage => 90,000,000,000,000,000 wei.
- cd keeper && node --input-type=module -e 'import {postMarketFloorNeeded} from "./src/decide.ts"; const p="0x6b9411DD51DF1E41015cD8293C1BBC3E881a4aee"; const r=postMarketFloorNeeded({isV3:true,timestamp:1200n,floorPoster:p,floorStepBps:1000n,floorMinSeconds:600n,floorMaxStale:21600n,floorPostedWei:8700000000000000n,floorPostedTime:600n,marketBidWei:20000000000000000n},{poster:p,tolBps:100}); console.log(r.ok,String(r.target),String(r.target*10300n/10000n))': exit 0, true 9,570,000,000,000,000 wei target and 9,857,100,000,000,000 wei ask.
- Local Anvil: anvil --quiet --accounts 0 --fork-url https://mainnet.gateway.tenderly.co --fork-block-number 26251200 --chain-id 1 --port 8545; cast rpc anvil_impersonateAccount 0xCB43078C32423F5348Cab5885911C3B5faE217F9 --rpc-url http://127.0.0.1:8545. Each owner step first ran forge script without --broadcast or a keystore, then with --unlocked --broadcast --slow against localhost only. STEP=deploy: 4/4 preview, dry gas 14,680,291, 5/5 receipts status 0x1, actual gas 11,292,533. STEP=migrate: 37/37 readback, dry gas 2,743,534, 18/18 receipts status 0x1, actual gas 1,941,849. Core SET_balanceBidCapBps=10000: dry gas 328,994, local send successful. After evm_setNextBlockTimestamp 1792795265 and evm_mine, STEP=bid: dry gas 52,934, 1/1 receipt status 0x1, actual gas 38,324. STEP=ens: 4/4 preview and 1/1 resolver readback, dry gas 58,067, 1/1 receipt status 0x1, actual gas 42,040. STEP=readback after those steps: exit 1, 32/37, with the five state/time-dependent rows listed in BP-02. Anvil was stopped after evidence capture.

## Limits

The fork is a historical block and the OpenSea cases use mocked responses; no production API or mainnet transaction was exercised. This was a focused diff audit, not a full-suite, invariant, hostile-token, or formal proof campaign. The live BALANCE token's exact-transfer behavior was used in the fork; hypothetical fee-on-transfer behavior is explicitly qualified above. The indexer is outside this commit scope. The local script rehearsal used the V2 spread at the pin (1,000), not the planned 2,500 pre-switch send; SEC-05 records that missing planned-order coverage. No fixes were made to the audited source.
