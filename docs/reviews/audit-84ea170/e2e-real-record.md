# script/dev/e2e-real.sh run on main 84ea170

Result: 37 PASS, 0 FAIL, wall 791 s. Fork: anvil chain id 1 on port 8620 of https://eth.drpc.org at block 26208025 (the
script's pinned default; the live Artcoins v2 stack exists at that block). Cache miss: the deployed and seeded state was
built fresh in this run. Log: scratchpad/logs/e2e-real.log.

Numbers from chain reads (wei unless stated):
- phase 2: ten buys and five sells through the universal router inside the sniper window moved 4,506,639,077,736,739,630 wei
  (4.51 eth) of hook pushes into the Core with the pot still 0 (no door booked); after 10 minutes idle `ethRate` stayed at
  `rateStart` 4.9e15 (unbooked income earns no climb, decision 176).
- phase 3: the keeper's `book` put 4.5067 eth in the pot (threshold 0.1050225 eth) and the rate read 4,922,693,392,191,757 right
  after; eight hours later the bid sat at the cap 1.47e16; the keeper swept strategy listing 35377 and the rate fell to
  1.4505e16 on the fill.
- phase 4: a signed Seaport order for credit 18683 was filled by the keeper through the Seaport adapter; a direct `sellForEth`
  paid exactly `bidOf`; A2 bought credit 35377 through the sale, the return lock refused A2 and allowed A3 after a transfer;
  at the reserve `sellForEth` reverted `PotTooSmall`.
- phase 5: pile 84, the keeper composed; the statement sold with the artist, operator and buyback split; a buyback burned
  17,871,382,234,569,107,919,225,379 base units (1.787 percent of the 1e27 supply); `payeeOn` latched.
- phase 6: the owner set the production module 0x63a5985393907F882053D55D3904230f022C94f1 bound to Jack's pinned
  `ConversionLineageWithdrawals` deployed on the fork; statement 247 composed, reached `atFloor` after warps, redeemed for
  rating times 1e14 into the module.
- phase 7: the funder seeded pool liquidity 164,258,402,685,300,000,000 (L) with 23,702.5 tokens; `setQuote` with minLiquidity
  at half that depth; value mode on with `spendCapBps` 1,000; `referencePrice` 4.9e13 wei per 1e18 base units; a balance sell
  paid 246.56 tokens equal to `balanceBidOf`, royalty 6.164 tokens (250 bps) reached the artist or was owed; six keeper refresh
  ticks; a value mode sell priced inside the bands; a same-block round trip lost 177,461,682,905,660 wei to the pool fee;
  switch off reseeded the eth instance at 4,595,220,000,000,000 against 4,590,810,000,000,000 on.

What was real, what was not (for the acceptance reader):
| element | status |
|---|---|
| Artcoins v2 factory, hook, locker, escrow, mev module, pool manager, Credits, Statements, CreditScore, CreditStrategy, Seaport | real mainnet code and state at block 26208025 |
| the deploy | the real twelve transaction path through `script/deploy.sh local` (preflight, Deploy, postflight, record), signer the owner address impersonated by anvil (`--auto-impersonate`), not the keystore |
| fee income | real swaps through the universal router by a pre-funded trader account; the hook's bounty push is the real code path |
| the keeper | the real binary (`node keeper/src/main.ts --once`) with a throwaway keystore; `LISTING_DELAY_SEC=0` (production 120), `STRATEGY_IDS` pinned to three ids, the next block's base fee forced to 1 gwei before every tick, one tick per 12 second step, no relay (local node) |
| Seaport orders | real EIP-712 orders signed by a throwaway key for credits the script moved to that signer; filled through the real Seaport 1.6 |
| sellers, buyers | pre-funded fixed accounts (A1 to A3, trader, funder) with real credits moved from the CreditStrategy by impersonation |
| time | `evm_increaseTime` warps between phases (10 minutes, 8 hours twice, the credit window, days to `atFloor` and to Jack's `opensAt`) |
| Jack's token | the pinned source built locally and deployed on the fork through CREATE2 by the script, with the Statements owner impersonated to register the renderer and a funder surrendering a page; not the mainnet deployment of that token |
| balance pool | created and seeded by the funder on the fork (full range, 23,702 tokens); depth and spot are synthetic |
| value mode | the real controller and Core code, settings chosen by the script (`referenceMaxStale` 3,600, `spendCapBps` 1,000, tol 100, rate 1,200, step 200) |
| omitted | the private relays, mainnet gas competition, the indexer and the web (checked separately), the deferred launch path (test-launch-only-guards.sh, separate), a live OpenSea listing |

The run proves the code paths and their accounting on a real fork. It does not prove liquidity, timing or incentives of the
real market: the keeper's two minute delay, the relay path, competing bots at the listing gap, real pool depth of the
balance token and real Credits holders' behaviour are outside it.
