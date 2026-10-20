# CC product and newcomer review

Review date: 2026 10 20. Base `main` revision: `74558d203918293174cdeebece080a1be1532089`.

Scope: mechanisms, participant incentives, product explanation, and visual presentation. This is a product assessment, not a contract security audit or a new release acceptance. Read `AGENTS.md` and `docs/CONTEXT.md` for the current agent entrypoint and intended public vocabulary. Current settings must be checked onchain.

## Verdict

The engine has an actual economic story. `$CC` trading sends ETH toward purchasing Credits. The acquisition price changes after fills. Credit inventory has two permitted onward paths: individual resale or 80 Credit composition into a Statement, followed by resale. Successful sales replenish the pot and designate ETH for future CC buybacks. The artist receives compensation on each purchase and on resale.

This is more compelling than an operator wallet accumulating NFTs. The project should describe CC as a continuously participating market actor that can buy, distribute, and compose existing art. However, **keeping the engine running** and **keeping every acquired NFT circulating** are different claims. The first can continue while fees and buying room exist; the second is constrained by cost and value based sale floors and actual buyer demand.

## What is strongest

1. **Visible causal activity.** Trading, bids, acquisitions, composition, sales, and burns have inspectable onchain paths. A landing page can show events rather than only promise potential future treasury activity.
2. **Distinctive pricing mechanism.** The ETH bid is per 100 Credit rating points and responds to acquisitions and available capital. It is not a uniform NFT offer.
3. **Inventory has more than one path.** Individual Credit sales allow collectors to acquire items before they are composed, and composition creates a different kind of sellable inventory. That creates a reason to keep watching.
4. **Artist aligned economics.** A 2.5 percent purchase royalty is paid on top of seller proceeds, and a separate 2.5 percent is deducted from engine NFT resale proceeds at configured launch values. This differentiates CC from strategies that use an artist's collection without paying into its economy.
5. **No invisible team token allotment in the launch configuration.** One billion CC are seeded into the initial Artcoins pool liquidity via the factory and locker; there is no coin extension allocation. This is worth explaining to speculative participants.

## Material limitations

### 1. Declining markets still create inventory risk

The ETH bid changes with completed acquisitions, not continuous observation of a global Credit market price. When offers clear, fills lower the rate. While the engine is funded the rate can climb again. In a market selloff, the engine may buy at prices that later prove too high.

At the reviewed phase one settings, individual Credit asks decline only to a floor based on recorded cost and value. Statement asks also settle at a reference and cost floor. A deep downward repricing can leave both types of inventory held indefinitely until buyer demand returns, the owner modifies settings or future approved functionality changes the rule. Composition requires batches of 80 eligible Credits, so inventory below that threshold cannot progress through composition alone.

Fees from continued CC trading can support fresh acquisitions independently of older inventory sales, but without new fees or sale proceeds the pot can eventually become too small to keep buying. Buybacks funded by sales slow with NFT turnover.

**Recommendation:** tell users that CC is designed for recurring participation through changing conditions, not that it guarantees liquidations or never stops. If unconditional downmarket turnover is a true requirement, a separately reviewed below cost sale mechanism with explicit loss financing, limits, and anti manipulation safeguards is an economic product change. Do not quietly solve it with copy.

### 2. Trading costs are unusually prominent

The baseline pool skim is 6.9 percent. The configured opening skim begins at 69 percent and decays to baseline in 69 minutes. This is relevant to every prospective CC trader; it can deter repeat trading, hinder organic volume and reduce the future fee stream that the engine depends on. Present the current fee directly in the trade UI, with the opening countdown while active. Show the baseline split as 6.21 percent of trading volume to the Core and 0.69 percent to the protocol fee leg. Distinguish from NFT royalties. A high opening fee is an explicit trade cost and should not be framed as free anti bot protection.

### 3. Sale proceeds are not identical for Credits and Statements

The old homepage statement split displayed 25 percent to buyback and 75 percent to the pot as if both shares applied to gross proceeds. That omitted the artist and operator deductions. At the current defaults, the actual gross Statement sale allocations are 72.75 percent pot, 24.25 percent buyback, 2.5 percent artist, 0.5 percent operator. An individual Credit sale instead books up to 80 percent of its recorded acquisition cost back to the pot, bounded by proceeds net of artist and operator cuts, with the remainder to buyback. There is no one fixed buyback percent for a Credit resale. The FAQ and landing graphic now distinguish these rules.

Buyback allocation is not a same transaction burn. A separate permissionless buyback call executes a bounded CC swap and burns the acquired tokens. Slippage, fee sharing and caller constraints apply.

### 4. Operator powers are economically meaningful

The Core and controller are not immutable market rules. The owner can change bids, sale timing and floors, royalty recipients or percentages within bounds, pause key doors and select replacement modules; locks can narrow some rights but must be verified individually. The owner can migrate permitted Core inventory to a successor. `Autonomous` describes executable public rules, not the absence of privileged control. The public FAQ should say so without a page of security boilerplate.

### 5. Public launch state and configured numbers need reconciliation

At the reviewed base, `deployments/1.json` reports a deployed Core and an unlaunched predicted coin. The same record's `openingRate = 0.0097` ETH per 100 points, `controllerDecayHours = 1` and `controllerCreditWindow = 3600` seconds differ from tracked `script/config/mainnet.json` values of 0.0056, 4 hours and 4 hours respectively. The current authoritative state is whatever the deployed contracts actually report at the moment. Avoid an FAQ answer that gives a stale exact countdown, opening bid, or sale curve. The current FAQ describes the rules and links to live values instead.

The historical indexer can be behind despite newer chain fallback reads. Live order discovery and purchase simulation must revalidate price, owner and executable listing. Presentation should not imply the website's listing table guarantees execution.

## Newcomer presentation audit

The existing landing flow communicates five steps but initially assumes readers know why Credits matter. Add one short sentence and a source link to Jack Butcher's artwork. Only teach concepts specific to this engine: Credits have rarity ratings, 80 become a Statement, and CC uses them as inventory. Do not teach Ethereum or NFT basics to an audience already likely to know them.

The lifecycle should emphasize **three loops**, visually separated:

- $CC trading produces new buying power regardless of whether old NFTs have sold.
- Each Credit acquisition adjusts the bid and gives inventory both an individual sale and a composition path.
- Completed Credit and Statement sales return capital to the pot and can finance CC buybacks.

Do not depict the loop as automatic profit, guaranteed perpetual motion or every Credit eventually selling.

The most useful graphics are:
1. A branching inventory diagram (individual resale versus composition). The proposed FAQ includes this.
2. A rising and falling ETH bid trace (illustrative, not an implied forecast). The proposed FAQ includes this.
3. A sale proceeds bar with real gross percentages and distinct artist, Artcoins protocol, operator and CC buyback destinations. The proposed FAQ includes the Statement bar and textual protocol fee explanation. An expanded future trading fee panel could show the separate trade skim.
4. Real Credits and Statements artwork from existing site components, not AI generated imitations of Jack's artwork.

## Recommended copy order

A single strong homepage explanation should answer what the system does and why it keeps acting. Follow with a basic Credits origin and source link, the public bid and its movement, the two inventory outcomes, a money flow and a short FAQ. Keep the full `Core` and controller call reference in `/docs`.

For the FAQ, prioritize actual user questions:
- Is the engine merely buying and relisting?
- What happens if market prices fall?
- Is the ETH bid a guaranteed floor?
- Can a holder sell directly and what limits execution?
- How are the artist and Artcoins protocol paid?
- When does CC actually burn coins?
- Who got the coin supply and who controls settings?

This review recommends communication changes only. It does not authorize modifications to production price floors, coin fee parameters, contract authority or mainnet launch.
