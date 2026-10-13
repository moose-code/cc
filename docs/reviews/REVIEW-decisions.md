# decision and path audit, 2026-10-10

source revision 2407087 (main). author: the director session of 2026-10-10. method: owner instructions from the session transcripts of 2026-10-08 to 2026-10-10, docs/DECISIONS.md decisions 1 to 41, docs/STATUS.md, code reads of src/Core.sol and src/lib/CoreLib.sol, tests in test/Migrate.t.sol, sim/engine.js and sim/README.md. limits: no forge run, no fork read, no new simulation. economic figures marked projection come from the simulator's volume fit (sim/engine.js `COMPARABLE`: 1,944 eth measured over 13 days, extended to 90 days by an exponential fit).

status words: supported (authority current, assumptions evidenced), unproved (authority current, a key assumption has no evidence), contradicted (behavior or evidence conflicts with the purpose), superseded (a later owner decision replaced it). owner approval settles authority. it does not settle the assumptions.

## 1. material decisions

| decision | purpose | authority | key assumption and its evidence | status |
|---|---|---|---|---|
| flat bid per credit (FLOW 1) | buy as many credits as possible early | owner, FLOW 1 | score can wait. owner goal, no evidence needed | supported |
| no inventory gate (FLOW 2) | buying never stops for unsold statements | owner, FLOW 2 | unsold statements wait for phase 2. owner goal | supported |
| every economic setting adjustable at once, no timelock (FLOW 3, 15) | adapt fast | owner, FLOW 3 and 15 | holders accept full trust in the owner key. accepted risk, measured drain pace in `test_ACCEPTED_owner*` | supported, accepted risk |
| bid rule B: drop 0.5 percent per credit, climb 0.5 percent a minute, ceiling 125 percent loosening 2 percent per 10 idle minutes (NEXT 10) | follow the market, avoid stalls | owner, 2026-10-08 and 2026-10-09 | sellers notice a bid above the floor and sell into it (owner, 2026-10-09). simulator only, seller book assumed, no competing bidders modelled (sim/engine.js, sim/README.md section 10) | unproved against competing collection offers |
| a starved pot does not raise the price (owner question 2026-10-09) | no climb because the engine has no eth | owner, 2026-10-09 | `CoreLib._climb` holds a price state above the clamp, `receive` checkpoints before booking (src/lib/CoreLib.sol 228 to 254, src/Core.sol 356). the ceiling still loosens while starved, the price does not | supported |
| spend cap 100 percent, clamp of one average credit (FLOW 37) | spend as sellers come, no slow drip to front run | owner, 2026-10-09 | simulator only, 3 seeds, no competing bidders, and the simulator record is invalid (E-SIM-HEADLINE) | unproved |
| opening bid at market (NEXT 11) and rateCap 10 times the opening bid (owner, 2026-10-09) | open at market, cap the price paid | owner | the launch day rule recomputes `rateStart` from the market and leaves `rateCap` at the fixed 2.0554e14. at the runbook's own example median of 0.0106 eth the cap is 8.4 times the opening bid | contradicted by the runbook at 2407087, see finding 3. fixed: the launch day rule sets both and preflight checks the ratio (fb6c26c) |
| payee 0.75 points to the owner address, protocol 0.25 points (FLOW 31) | owner income, protocol leg | owner, 2026-10-08 | the 90 day payee figure (about 12 eth) is a projection of the volume fit | supported, figure is a projection |
| compose repays nothing, no keeper, the owner composes when nobody does (FLOW 41) | no pot spend on composers | owner, 2026-10-10: "i think we just don't automate the compose at all", "no repayment for compose" | holders compose for free, and gas stays near 0.5 gwei. no evidence for either. the simulator composes automatically at zero cost | unproved, see path A |
| migrate moves eth, exit token and credits, the old engine sells out its own statements (FLOW 33) | move the engine to a new Core | owner, 2026-10-09: "migrate only credits and eth and let v1 sell out its own statements" | after migrate the old engine only liquidates statements. the old engine keeps buying and composing with every later inflow (src/Core.sol doors, `test_OK_theEngineKeepsWorkingAfterAMigration`) | unproved, see path B |
| rescueCoin kept, the Core off the coin allowlist (FLOW 28, 29, NEXT 17) | insurance for stray coin | owner, 2026-10-09: "why remove rescueCoin? that seems helpful" | test/V2PortRestriction.t.sol | supported |
| `coin.lockRecipients()` at launch, `router.lock()` and `coin.lockAllowlist()` later (NEXT 15, 18, 19) | seal the pool side, keep engine migration open | owner, 2026-10-09 | script/Lock.s.sol refuses a repointed recipient | supported |
| statement price 110 percent falling to 75 percent, auction mode, proceeds 50 percent pot and 50 percent buyback (FLOW 17, 6) | statements move, sales need not profit | owner, FLOW 17 | statement demand: 42 fixed price sales over 5 days, arrivals independent of price (sim/README.md 98, 470) | unproved demand, owner accepts unsold statements |
| hourly window pot follows inflows (FLOW 36) | a fee pull inside a sale cannot make the batch revert | director, from a deep invariant failure | `test/Window.t.sol`, invariant 11 clean in the deep run on 06009bd | supported |
| buyListing caller tip: the lower of `tipSavingsBps` (10 percent) of the saving below the bid and `tipCapBps` (2 percent) of the listing price (src/Core.sol 622) | pay a caller to sweep cheap listings into the pile | earlier design, unchanged by the 2026-10-09 tip deletion (that deletion covered the router flush tip only) | the owner said "don't overpay the keeper" (2026-10-08). the tip pays only out of the saving below the bid | supported |

## 2. findings

1. **no valid independent review of the current source.** every review record in docs/reviews/REVIEW-*.md is pinned to a commit with 34 or more later commits under src/ (migrate, rescueNft, adopt, the bid rule, the lens, compose repaying nothing, the dead code sweep). the codex audit (docs/AUDIT-codex.md, commit 32ff35b) is on a branch that is not part of main. NEXT items 1 to 5, 9 and 10 say "built, awaiting review". the test suite and the deep invariants on 06009bd verify the implementation against its own assertions. the review gate needs a fresh reviewer on a frozen candidate.
2. **intent records disagree with each other.** docs/DECISIONS.md says it wins over docs/SPEC.md, docs/SPEC.md says it describes the system as it is and keeps FLOW for reasons, docs/STATUS.md says FLOW 10.6 and 10.7 win while FLOW says 10.9 wins over them. a sweep found 20 statements that would mislead a decision (fixed in the docs commit that follows this audit). repaired by the roles stated in docs/STATUS.md section 2.
3. **an owner parameter drifts with the market.** `rateCap` is stored as an absolute value. the launch day rule recomputes `rateStart` only. the owner set the cap at 10 times the opening bid. a market move on launch day changes that ratio with no code change, and preflight checks only `rateStart <= rateCap`. corrected in docs/RUNBOOK.md (the launch day rule sets both) and by a preflight row that fails unless `rateCap` is 10 times `rateStart` (NEXT item 21, fb6c26c).
4. **simulator evidence rests on a premise that changed.** the batches of sim/README.md ran while compose repaid its caller. sim/README.md keeps them because the repay was under 1 percent of a statement's cost, which addresses the cost basis. decision 41 also removed the incentive to compose. the simulator composes every full page at once and at no cost, so every statement flow figure (statements per day, sale proceeds, buyback) assumes a composer who is no longer paid. those figures are unproved until a composer model or a measured composer exists.
5. **docs/RUNBOOK.md by hand settings commands used a 29 field tuple.** `Settings` has 30 fields. the by hand `setSettings` call encodes a different selector and reverts, and the etherscan constructor arguments would not verify. the script path (`script/SetSettings.s.sol`) is unaffected. fixed in the docs commit.

## 3. path A: compose without a paid caller (the reported failure class)

the reported failures of 2026-10-09 (a router tip kept after the v2 port removed its reason, a repay bound added for a repay the owner then removed) share one cause: a mechanism outlived its premise. this path traces the premise that replaced them.

intent: credits flow into statements (ARCHITECTURE section 1). compose is the only way a statement is made. the owner composes when nobody does (FLOW 41).

implementation: `compose` and `composeExit` need a full page of 80 credits in a pile, pull the router fees first, mint, list, and repay nothing. measured gas 8.71 million (docs/SPEC.md, test/GasCap.t.sol). buying continues while pages wait, so a missing composer delays statements and sale proceeds and stalls nothing else.

counterexamples and acceptance cases:

| case | expected | observed |
|---|---|---|
| nobody composes for a week | buying continues, piles grow, no revert anywhere | holds: no door depends on compose (FLOW 2, invariant 16 "the bid never closes") |
| the owner composes every page for 90 days | the owner pays the gas, the engine pays nothing | holds in code. cost below, unmodelled in the simulator |
| a composer front runs a page | no value to extract: compose pays nothing | holds |

owner cost if the owner composes every page, projection, at the simulator's 90 day credit count (31,495 credits, 394 pages):

| gas price | cost per compose | 90 days | share of the payee projection (about 12 eth) |
|---|---|---|---|
| 0.5 gwei | 0.0044 eth | 1.7 eth | 14 percent |
| 2 gwei | 0.0174 eth | 6.9 eth | 57 percent |
| 10 gwei | 0.087 eth | 34 eth | 286 percent |

status: the decision is the owner's and stays. the evidence for statement flow is invalid until the simulator models a composer, and the owner's backstop cost is now stated. no owner question.

## 4. path B: migration to a successor (an unrelated path)

intent: owner, 2026-10-09: "confirm if we'll be able to deploy a v2 engine later and point the token rewards at it and migrate the v1 engine's assets over to it", then "migrate only credits and eth and let v1 sell out its own statements". FLOW 33: the held statements stay, "the proceeds are booked by collectSales and syncStatement and a later migrate moves them".

implementation: `migrate(maxCredits)` moves `ethPot + ethToBuyback`, the exit token pots and up to `maxCredits` credits from the head of each pile, and resets the window (src/lib/CoreLib.sol 415 to 480). no state marks the old Core as retired. after a migrate the old Core books every later inflow: sale proceeds (`_book`, half to the pot), fees while the router still points at it, and `skim`. `sellForEth`, `buyListing`, `adopt`, `compose` and `composeExit` all work on whatever arrives (src/Core.sol 570 to 712). `spendCapBps` has a floor of 100, so the owner cannot set spending to zero.

the test `test_OK_theEngineKeepsWorkingAfterAMigration` (test/Migrate.t.sol 443) asserts this: fees are booked, 80 credits are bought, a statement is composed and a buyback runs after a migration. docs/SPEC.md section 10 says the same. the code, the test and the as built document agree.

counterexample: migrate everything. a held statement sells for 0.7 eth. `collectSales` books 0.35 eth to the old pot. before the owner's next migrate, a seller sells credits to the old engine at its bid. once a pile holds 80, anyone composes a new statement on the old engine, which only the old engine can sell. its sale books proceeds to the old pot again. the wind down repeats at about half the value each round and lasts as long as the owner keeps calling migrate. meanwhile the old engine bids against the new one for the same credits.

who is affected: the owner (repeated migrate calls and gas, two engines to watch), the new engine (part of the proceeds becomes credits on the old engine, priced by the old engine's rate state), sellers (two bids), coin holders (the buyback half still burns, unchanged).

acceptance case the owner's words imply: after the first migrate, the old engine settles, exits and overprints the statements it holds and sends what it books to the successor. it buys no credits and composes no statements.

status: unproved. the owner's words and FLOW 33 name what moves and that the old engine sells out its statements. neither says whether it may keep buying. the test was written to assert that it does, so it protects a choice the owner has not made. `migrate` also moves the exit token pots, while the owner's words name credits and eth. this is a genuine owner choice (participant rights on the old engine, operating burden, compatibility with a successor). recorded as owner decision OD-1 in docs/STATUS.md with options and a recommendation. no code change until the owner decides.

## 5. what this audit does not cover

security review of the current source (finding 1), the live v2 stack beyond the pinned code hashes, competing bidders in the credit market, and statement demand. each is an open item in docs/STATUS.md.

## 6. independent review and dispositions

a fresh reviewer examined this audit, the records of 01452dd and the skill at 15653ff (read only, 2026-10-10). two fresh takeover sessions examined 2407087 without these records. dispositions of what they found in this repo:

| finding | disposition |
|---|---|
| path B was classed contradicted, the evidence supports unproved | reclassified above |
| option B of OD-1 listed five doors. `sellForExitToken` (src/Core.sol 631) does not call `_pullFees` and stays open | OD-1 in docs/STATUS.md lists six doors and the amendments to guarantee 42 and invariants 11 and 16 that option B needs |
| guarantee 42 was recorded wider than the code proves: above `rateCap` the engine stops buying until the owner acts, and a rising market is followed at 0.5 percent a minute | guarantee narrowed in docs/SPEC.md section 1, the gap recorded as a risk for the owner, OD-3 |
| decisions 43 and 46 attributed director text to the owner | rewritten with the owner's words only |
| FLOW 37 was classed supported on simulator evidence that is itself invalid | reclassified unproved |
| the deploy gate was not part of the runbook | docs/RUNBOOK.md step 6 runs `python3 script/director.py check --gate deploy` first |
| no test migrates into a real second Core and runs `adopt` there. `adopt` sets a migrated credit's cost basis to the successor's bid | recorded in docs/STATUS.md as a gap of the migration path |
| ledger texts: the carry record's reason, the review record's "most recent" claim, the deep run's owner review claim, the scope of this audit | corrected in project/evidence.json |
| the system audit of the untraced paths came after the freeze in the plan | moved before the freeze in docs/STATUS.md |
| a re-review found a director analysis could carry an old review across changed code, and that the 10x preflight row masked the bounds rows of the review matrix | the skill's checker refuses to extend a review over changed code. the matrix isolates each bounds check |
| NEXT 21 pins the ratio at exactly 10 while the owner said "10x to start" | kept: preflight runs at launch, which is the start. a later ratio changes decision 46 and the row together |
| a third fresh takeover found `migrate` moves `ethToBuyback`, the share earmarked for the buyback and burn, into the successor | added to OD-1 in docs/STATUS.md |
