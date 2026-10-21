# Prompt: independent security audit of the CC Phase 2 release candidate (Codex)

Audit branch `claude/phase-2-system-review-1iillx` of `ripe0x/cc` at commit `8347a12` (pull request 139). The previous audit covered `8c0cdf1` (its prompt is `docs/reviews/PHASE2-AUDIT-PROMPT-8c0cdf1.md`, its repairs are decision 253). This is the delta audit of everything since, plus a fresh adversarial pass over the money paths, before the owner sends the production transactions. Read `AGENTS.md`, `docs/SPEC.md` (the phase 2 rows), `docs/DECISIONS.md` 245 to 260 and `docs/RUNBOOK.md` stages A to D first, then the sources. Report against the code, not the documents: where they disagree, that is a finding.

## What is being audited

Unchanged and deployed, out of scope except as callers: the Core at 0xcdb1889ae12074d750CD9B8531B692015465e0dD, its linked libraries, ControllerV1, the restricted coin CC at 0x28ef14A55DC93CDCB9001FA038A184967146C789 (supply 1e27, the pool manager holds about 72 percent).

The phase 2 contracts, all to be created by `script/Phase2Deploy.s.sol` with every switch off:

- `src/adapters/Phase2BalanceTreasury.sol`: the selected balance module and BALANCE custodian. Converts the Core's Statements (`redeem`), earmarks `conversionToClaimBps` (1,000 at deployment, decision 259) of each measured receipt as claim backing, pays Credit sellers and the artist from working funds (`pay`, inherited debt accrual), pays CC burners the policy's quote capped at `floor(ccIn * claimReserve / totalSupply)` (`redeemCC`), owner controls (switches, fee, earmark, minimum working balance, policy, `fundClaims`, `allocateToClaims`, `returnClaimsToWorking`, `withdrawWorking`, `rescueToken`), a successor migration (`migrateTo`, `receiveMigration`).
- `src/adapters/ProRataRedemptionPolicy.sol`: the quote, `floor(x * C / S)` less a fee.
- `src/ControllerV2.sol`: the issue 113 live spot rule, a persistent Statement ask (1.5x the reference, decision 256), an independent redemption delay.
- The artist and operator split: a Splits v2.2 push split created by the deploy (`script/PushSplit.sol`), 833,333 and 166,667 of 1,000,000, the Core owner as controller; the Core's artist slot points at it after stage B (decision 255).

The live BALANCE token is `InterfaceAuctionWithdrawals` at 0x3620540c994433D7B4a628C46d2ED5F92572eA07 (statements 0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b, SCORE_TO_TOKEN 1e14, 18 decimals, retirement finalized, funding phase 3, transfers open at block 26,241,565). Its runtime equals the pinned upstream build `jckbtchr-vv/credits@54ef94cf` outside the immutables and the 32 byte metadata hash. The upstream source is private: audit through the ABI in `out/upstream-auction-balance.json` and the live bytecode.

The operator layer: `script/Phase2Deploy.s.sol`, `script/Phase2Readback.s.sol`, `script/Phase2Settings.s.sol`, `script/Phase2Claims.s.sol` (the post launch claim activation, decision 258), `script/CreatePushSplit.s.sol`, `script/phase2/calibrate.py`, `script/SetSettings.s.sol` (ControllerV2 support); the keeper (`keeper/`: the `conversionReady` gate and the `distributeSplit` door); the indexer (`indexer/`: the treasury tables, the migration replay helper); the exchange page (`web/`: the claim panel, its accumulating state while redemption is off, the fresh quote before approval).

## The delta since 8c0cdf1

1. The audit repairs of decision 253: `migrateTo` requires the destination Core to have selected the successor; the indexer seeds a treasury's row at its selection block; the deploy refuses integers above uint32, requires the token's runtime code hash and a plan hash on a send; ControllerV2 refuses a zero `minLiquidity` and never prices a pool with zero live liquidity; the panel reads a fresh quote before any approval; the invariant asserts the cap on every burn.
2. The posted Credit to BALANCE payout at 80 percent (`balanceDiscountBps` 2,000 in the stage B patch, decision 254).
3. The split route: `setArtist(split)`, `buyToArtistBps` 300, `saleToArtistBps` 300, `saleToOperatorBps` 0 (decision 255); the push split created by the deploy and accepted only after a simulated distribution pays both recipients and the Core's 50,000 gas push is taken; the keeper's `distributeSplit` door at a 0.25 ETH threshold.
4. The Statement ask at 1.5x (decision 256).
5. The claim earmark at 10 percent (decision 259): the constructor default, the stage A readback row, the margin per 100 BALANCE funded points in the settings preview and the readback (payout, royalty as a share of the payout, earmark; 7.6 at 80 percent).
6. The launch with CC redemption off and `script/Phase2Claims.s.sol` adding the claims later (allocate or fund, enable, disable; plan hash; readback; decision 258).
7. The panel's accumulating state while redemption is off, the owner managed disclosure, the migration replay helper in the indexer.

## Environment

Foundry 1.8.1, solc 0.8.30, the production profile is via_ir (foundry.toml). Fork tests use `MAINNET_RPC_URL=https://gateway.tenderly.co/public/mainnet FORK_BLOCK=26208025`. Run focused tests with `forge test --match-path <file>`; the whole suite and the deep invariants belong to the frozen candidate run and are not yours to repeat. Never send a mainnet transaction, never use a key. The build pins in `script/Checks.sol` and `test/BuildIdentity.t.sol` are the shipped artifacts; `test/Phase2UpstreamBalance.t.sol` runs the real token bytecode.

## Properties to break

Try to break each; a confirmed break with a reproducing test is the deliverable.

1. **Custody.** The treasury's BALANCE can only leave through `pay` (bounded by `available()`), `claim` (recorded debt), `redeemCC` (capped), `withdrawWorking` (free working funds only), `returnClaimsToWorking` (only while redemption is off), `migrateTo` (switches off both sides), and `rescueToken` (never the balance token, CC, Credits or Statements). Find any other path, any way to spend the claim reserve on a Credit seller, any way `available()` exceeds custody less the reserve, the debt and the minimum.
2. **The receipt.** `redeem` measures the receipt and requires at least the rating times the unit; the Core's physical receipt check reads the whole amount with the earmark inside the treasury. Find a Statement whose conversion passes the Core's check while the treasury records less, or a double conversion, or an earmark on anything that is not a conversion.
3. **The cap and the burn.** `redeemCC` pays at most `floor(ccIn * C / S)` with C and S snapshotted before the burn, burns exactly `ccIn` through `burnFrom` on the restricted coin, requires the supply to fall by exactly that, requires the recipient's balance to rise by the payment and custody to fall by it, and records no user debt. Find a burn paid above the share, a burn that does not burn, a payment that is short without reverting, a reentrant second outflow, or an epoch, deadline or minimum the burner cannot rely on.
4. **Backing per CC.** Sequential burns never lower the claim reserve per remaining CC apart from rounding dust; only owner actions do, and each of those advances the epoch. Find an owner action that lowers a burner's terms without the epoch moving.
5. **The switches and the staging.** With conversion and working payments on and redemption off (the launch state), the full Credit to BALANCE flow runs and `redeemCC` reverts whatever the reserve holds. The claims are added later by `Phase2Claims`: find a way the enable step pays before the reserve is funded, a way the keeper or the Core needs the switch, or a state the disable step cannot undo.
6. **Migration.** `migrateTo` needs every switch off on both sides, the same Core or the retired Core's successor, the destination Core to have selected the successor, and the claims fully funded; `receiveMigration` accepts only the predecessor and checks solvency. Find stranded claims, a double import, or a successor that is not what the Core selected.
7. **The policy.** The treasury probes a new policy (code, `isRedemptionPolicy`, a sample under the share) and turns redemption off on replacement. Find a policy that passes the probe and pays above the share later, or a replacement that keeps redemption on.
8. **ControllerV2.** The protected price takes the worse of the prior block sample and the live spot on each side, bounded by the reference band, unusable on stale, zero liquidity or under `minLiquidity`; a same block pool move cannot improve the mover's side. The Statement ask never goes under the reference. Find a same block or two block manipulation that moves a price the Core pays, a reference walk the keeper's refresh cadence allows, or an ask under the BALANCE the Statement converts to.
9. **The split.** The Core pushes ETH to the artist slot with 50,000 gas; the treasury pays BALANCE to it through `pay`. Find a split state in which a Credit purchase or a Statement sale reverts or loses funds, a way the pull split from the splits.org form could become the artist, or a distribution that pays someone other than the two recipients.
10. **The real token.** Transfers open at block 26,241,565 (funding phase 3, retirement finalized). Find a path where the treasury's `pay` or a burner's payment fails under the Core's 600,000 gas bound for the artist call, where `conversionReady` reads true but a conversion reverts, or where the token's own transfer rules strand custody.
11. **The operator layer.** Every send is gated by a plan hash restating the preview; readbacks fail closed on identity, binding, hazard and margin rows. Find a plan hash that does not cover an input that changes the effect, a readback row that passes on a wrong state, or a script that can send without the owner.
12. **Services.** The keeper never attempts a disabled redemption, never distributes a split whose stored config differs from its env (the split reverts `InvalidSplit`), and refuses to start on a bad config. The indexer replays a migration into both rows and throws on a receipt before selection. The panel never enables a transaction while redemption is off, pins the fresh quote's minimum, the epoch and the deadline, and labels its preview as not executable. Find a UI state that implies a claim is open when it is not, or a quote the panel shows that the contract would not pay.

## Also report

- Any arithmetic that can overflow or truncate on realistic inputs (rating times the unit, the earmark, the share, bps products).
- Gas: the treasury's `redeem` and `pay` under the Core's bounds with the real token's transfer; the policy read under `POLICY_GAS`.
- Every place the documents promise something the code does not do, in particular any surface that implies backing is locked rather than owner managed (decision 260).
- Stale numbers describing current behavior (the contribution is 10 percent, the payout 80 percent, the ask 1.5x).

## Deliverable

A written report ordered by severity: location, scenario with numbers, loss or break, minimal fix, and whether you verified it with a test or reasoned it. Say explicitly what you looked for and did not find. No pull request, no commits; put reproducing tests in a scratch directory and name them in the report.
