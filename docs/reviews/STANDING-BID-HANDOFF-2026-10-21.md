# Standing bid handoff, branch `claude/phase-2-standing-bid-1iillx`

Built autonomously overnight on 2026-10-21 from the phase 2 branch `claude/phase-2-system-review-1iillx` at `c7a2443`, under the owner's instruction "redemption is the path", the first principles design of the walkthrough, and decisions 258 to 260. The branch is the second built version of CC redemption, beside the pro rata version of the parent branch, so the owner can compare the two and scrap one. Implementation checks only; this is not a release claim and no candidate gate has run. Nothing was sent to mainnet.

## 1. what this branch is

The pro rata claim (parent branch) pays a CC burner its share of the pot, which ignores the market and clears only when CC trades below it. This branch keeps that share as the floor and adds a standing bid: the treasury pays the coin pool's protected price in BALANCE plus a premium, from a daily budget the owner sets. A holder who sells on the pool pays the hook's skim; a holder who redeems gets market plus the premium, so redeeming is the better door and sell pressure drains supply through the protocol. A bot has to buy on the pool first, so the premium is only reachable by holders.

Everything deploys exactly as the parent branch does: the budget at zero, CC redemption off, the pro rata policy installed. The bid is added after launch in five owner sends (stage D of the runbook), no migration.

## 2. the compact table

| item | state |
|---|---|
| contracts | `Phase2BalanceTreasury` gains the bid budget and the cap `max(share, budget)`; `StandingBidPolicy` is new; `ControllerV2`, `ProRataRedemptionPolicy`, the Core and the coin are unchanged |
| scripts | `script/StandingBid.s.sol` (deploy, configure, install, budget, enable, each its own reviewed send with a plan hash), `Phase2Readback` bid rows and a hazard row, `Phase2Deploy` unchanged in use |
| services | keeper `refreshBidReference` door; indexer `BidBudgetSet` and `BidPaid` with budget columns and the policy version; the claim panel shows the bid beside the pool door and marks the one that pays more |
| local | `BID=1 PHASE=phase2 script/dev/local.sh` runs the whole stack with the bid live on anvil |
| verified | see section 5 |
| deployed | nothing |

## 3. decisions made on the owner's behalf, for review

Each is recorded in docs/DECISIONS.md (258 to 260) and is a small change if the owner wants otherwise.

1. **The premium is 100 bps, bounded at 500.** Under the pool's 690 bps skim, so a pool round trip cannot farm it. Raise it toward 500 to pull more sellers to the bid; never above the skim.
2. **The budget is an absolute amount per day with an absolute carry maximum**, not a share of the pot. The owner states what the pot may spend. The activation script refuses a maximum above a quarter of the claim reserve without `ALLOW_LARGE_BID_BUDGET=1`, because a maximum at or above the reserve lets one burn take the whole reserve at the bid.
3. **A payment above the share consumes the whole payment from the budget**, not only the excess. "Budget" means what the pot releases to the bid per day.
4. **A burn the budget does not cover is quoted the share, never a partial fill.** The panel shows the capacity in CC and the burner sizes to it.
5. **The budget is capped at the claim reserve**, so the solvency rule stays `out <= claimReserve`; accrual above a small reserve is kept, not forfeited, when a bid settles.
6. **A budget change advances the epoch; the policy's own settings do not.** The panel's fresh quote and the burner's minimum out are the protection; every policy move lowers or keeps the quote, so a loosely set minimum can at worst land at the floor.
7. **The balance leg is ControllerV2's protected sale price**, the higher side. The bid is unusable until ControllerV2 is selected with a live BALANCE pool reference (stage C), and any controller change drops every quote to the share.
8. **The CC leg's tolerance is bounded at 100 bps and its rate at 1,000 bps per hour; the recommended settings are tolerance 0, rate 200, step 100, 600 seconds between refreshes, one day staleness.** The adversarial review showed a pump held across blocks lifts the bid by the band at once and by the rate per hour, so the CC leg prices at the lower of the sample, the live spot and a slow reference. After a real rally the bid lags the market until the reference catches up; that is intended for a protocol bid.
9. **The keeper's refresh door is unpaid** and runs only while CC redemption is on (`BID_REFRESH_ALWAYS=1` lifts that).
10. **The pool quote on the panel is an estimate**: the v4 quoter's sell of the entered CC net of the skim and impact, valued in BALANCE at the balance pool's spot; a slot0 fallback ignores impact and says so.
11. **The treasury's policy read bound rose from 200,000 to 300,000 gas**; the policy's read measured about 112,000 on the fork.
12. **The probe for a new policy** accepts a sample up to the larger of the old 0.25e18 and the live budget, plus a second sample whose share dwarfs any budget; install the policy before setting the budget, as the script sequences.

## 4. the activation ladder after launch, unsent

Stage D of docs/RUNBOOK.md, each a separate reviewed send with the owner keystore and the Tenderly gateway:

```
STEP=deploy    TREASURY=<treasury> forge script script/StandingBid.s.sol --rpc-url https://gateway.tenderly.co/public/mainnet
STEP=configure TREASURY=<treasury> POLICY=<policy> BID_QUOTE_MIN_LIQUIDITY=<units> ...
STEP=install   TREASURY=<treasury> POLICY=<policy> ...
STEP=budget    TREASURY=<treasury> BID_BUDGET_PER_DAY=<units> BID_BUDGET_MAX=<units> ...
STEP=enable    TREASURY=<treasury> ...
```

Each step previews, prints a plan hash, and sends only with `SEND=1 STANDING_BID_PLAN_HASH=<printed> --broadcast --account ripe0x`. The keeper's `refreshBidReference` door starts refreshing once redemption is on. The panel and the indexer light up on their own.

## 5. verification

Filled at the end of the build; see docs/STATUS.md section 1 for the final counts and commit.

## 6. what the adversarial review found and what was done

An independent review of the contract diff on the fork: no solvency break, no way to pay above the reserve, no silent gas fallback, no reentrancy. One medium economic finding (the cross block pump above) led to the bounds of decision 8; two low findings (the carried budget clipped to the reserve, the panel views ignoring the fee) were fixed; the probe and the capacity view were hardened. Unverified after the repairs: a second independent review of the final code, the CANDIDATE_RUN suite, and the real BALANCE token's pool behind ControllerV2 once it exists.

## 7. the previous pull request

The owner asked for the pro rata branch to get the same post deployment claim activation path. That follow up is recorded in decision 260 and lands on `claude/phase-2-system-review-1iillx` after this branch.
