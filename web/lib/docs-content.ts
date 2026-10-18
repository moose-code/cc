// Contract docs use current engine interfaces and a pinned snapshot for the deployed helper.
// Keep signatures and behavior in sync with each referenced source revision.
export type DocEntry = {
  signature: string;
  description: string;
  detail?: string;
  access?: string;
  errors?: string;
};

export type DocSection = {
  id: string;
  title: string;
  intro?: string;
  entries?: DocEntry[];
  points?: string[];
};

export type DocPage = {
  slug: string;
  group: "Start here" | "Guides" | "Contracts";
  title: string;
  eyebrow: string;
  summary: string;
  source?: string;
  sourceSnapshot?: string;
  sourceRevision?: string;
  mainnetAddress?: string;
  sections: DocSection[];
};

export const docPages: DocPage[] = [
  {
    slug: "",
    group: "Start here",
    title: "Overview",
    eyebrow: "Documentation",
    summary: "Guides and contract reference for the CC engine.",
    sections: [
      {
        id: "journeys",
        title: "Common tasks",
        points: [
          "Read a Credit bid with Core.bidOf or Core.balanceBidOf. Read a Statement ask with ControllerV1.priceOf.",
          "Read Credit scores and traits, or a Statement's total score, with CreditScoreLens.",
          "Sell Credits through Core.sellForEth or Core.sellForBalance after approving the Core.",
          "Buy a Statement with ControllerV1.buy. Buy Credits with buyCredit or buyCredits.",
          "Track activity through contract events. A Statement sale emits ControllerV1.Bought and Core.StatementSoldTo.",
        ],
      },
      {
        id: "before-you-call",
        title: "Before a transaction",
        points: [
          "Read the deployed addresses and active switches. The balance module and balance bid can be unset or off.",
          "Quotes change with time, settings, and state. Simulate the call before sending it.",
          "Use a minimum output where available. Owner settings take effect immediately.",
          "Amounts use raw token units. Credit scores use 10,000 units per point. The ETH bid rate is per 100 points.",
        ],
      },
    ],
  },
  {
    slug: "guides/read",
    group: "Guides",
    title: "Read the engine",
    eyebrow: "Guide / reads",
    summary: "Use contract views for current quotes and the event stream for historical actions.",
    sections: [
      {
        id: "credit",
        title: "A Credit bid",
        entries: [
          { signature: "Core.bidOf(uint256 id) → uint256", description: "Current ETH bid for this Credit, including its score and the live rate." },
          { signature: "Core.balanceBidOf(uint256 id) → uint256", description: "Current balance-token bid, zero if the module cannot fund the payout and royalty. Check settings.balanceBidOn separately." },
          { signature: "Core.spendState() → (bucket, budget, spent)", description: "Remaining ETH purchase budget in the current bucket. A positive bid does not guarantee this bucket can buy." },
        ],
      },
      {
        id: "statement",
        title: "A Statement sale",
        entries: [
          { signature: "Core.statementInfo(uint256 sid) → (held, cost, composedAt)", description: "Check custody and cost before reading a sale quote." },
          { signature: "ControllerV1.priceOf(uint256 sid) → uint256", description: "Current ETH ask. The curve and reference can move with time and settings." },
          { signature: "ControllerV1.atFloor(uint256 sid) → bool", description: "Whether the Statement is eligible for the floor-based redemption rule." },
        ],
      },
      {
        id: "scores",
        title: "Scores and traits",
        entries: [
          { signature: "CreditScoreLens.creditScore(uint256 creditId) → uint256", description: "Credit score in ten-thousandths of a point, including for burned Credits." },
          { signature: "CreditScoreLens.statementScore(uint256 statementId) → uint256", description: "Stored total score across a Statement's pages, including overprints." },
        ],
      },
      {
        id: "history",
        title: "History comes from events",
        points: [
          "Use CreditBought, CreditSold, Composed, StatementSoldTo, and StatementRedeemed for activity; pair each log with its transaction and block.",
          "SettingsSet, SaleSet, CreditSaleSet, QuoteSet, and BalanceModuleSet change how later quotes should be interpreted.",
          "A current view is not a historical quote. Read at the historical block or replay the relevant settings and events.",
        ],
      },
    ],
  },
  {
    slug: "guides/write",
    group: "Guides",
    title: "Call the engine",
    eyebrow: "Guide / transactions",
    summary: "Approve assets, read quotes, simulate calls, and set output limits.",
    sections: [
      {
        id: "sell",
        title: "Sell Credits",
        points: [
          "Approve the Core to transfer each Credit. Read bidOf or balanceBidOf, then simulate the chosen sell call against the latest block.",
          "Use the minOut overload to bound payment. For balance sales, the expectedToken overload also pins the token address if the owner replaces the module before inclusion.",
          "The return lock, reserve, spend cap, module availability, and active switches may prevent a quoted sale from executing.",
        ],
        entries: [
          { signature: "Core.sellForEth(uint256[] ids, uint256 minOut)", description: "Sell one or more Credits for ETH. The caller receives the bid; the artist royalty is paid on top." },
          { signature: "Core.sellForBalance(uint256[] ids, uint256 minOut, address expectedToken)", description: "Sell for the current module's balance token, with minimum output and token pinning." },
        ],
      },
      {
        id: "buy",
        title: "Buy from the engine",
        entries: [
          { signature: "ControllerV1.buy(uint256 sid) payable", description: "Buy a held Statement at its current ask. Send at least priceOf(sid)." },
          { signature: "ControllerV1.buyCredit(uint256 id) payable", description: "Buy one held Credit while the Credit sale is enabled. Its price declines over the sale window." },
          { signature: "ControllerV1.buyCredits(uint256[] ids) payable", description: "Buy multiple held Credits in one call; simulate the aggregate payment first." },
        ],
      },
      {
        id: "automation",
        title: "Permissionless maintenance",
        points: [
          "Core.book, buyback, compose, collectEscrow, and refreshReference are callable maintenance doors, each with its own readiness checks.",
          "Do not assume a keeper reward exceeds transaction gas. Simulate the exact call and inspect the current settings.",
        ],
      },
    ],
  },
  {
    slug: "guides/lifecycle",
    group: "Guides",
    title: "Lifecycle",
    eyebrow: "Guide / operating model",
    summary: "Contract behavior during launch, balance activation, locks, and migration.",
    sections: [
      {
        id: "phases",
        title: "Operating phases",
        points: [
          "Launch: the ETH bid and Credit and Statement sales can run. The balance bid is off until the owner sets a module and enables it.",
          "Balance phase: the module must advertise available tokens before balance bids can fill. Value mode additionally needs a usable controller quote.",
          "Retirement: Core.migrate transfers the bid pot and pile to a successor. The old Core can continue its held Statement sale and redemption paths.",
        ],
      },
      {
        id: "authority",
        title: "Authority and locks",
        points: [
          "The owner can change economic settings immediately, pause sales, select a controller and module, manage adapters, and nominate a successor.",
          "Controller, balance module, adapter, and successor locks are one-way. Read their onchain flags rather than assuming they have been applied.",
        ],
      },
      {
        id: "failure",
        title: "Common failure conditions",
        points: [
          "NoBalanceModule and BalanceBidOff mean the balance route is unavailable. NoQuote blocks a protected value-mode sale quote; the ETH bid may use its last good value rate.",
          "ReturnLocked and SpendCapReached can block an ETH sale even while bidOf is positive.",
          "Paused, InWindow, NotReady, and BelowFloor distinguish sale timing and floor conditions from a missing asset.",
        ],
      },
    ],
  },
  {
    slug: "contracts/core",
    group: "Contracts",
    title: "Core",
    eyebrow: "Contract / custody + execution",
    summary: "The Core holds ETH and Credits, owns the bid and pile, composes Statements, and is the authority boundary for settings and modules.",
    source: "src/interfaces/ICore.sol",
    sections: [
      {
        id: "quotes",
        title: "Quotes and state",
        entries: [
          { signature: "bidOf(uint256 id) → uint256", description: "Live ETH bid for a Credit ID.", access: "view" },
          { signature: "bidForScore(uint256 score) → uint256", description: "Live ETH bid for a raw score.", access: "view" },
          { signature: "balanceBidOf(uint256 id) → uint256", description: "Funded balance bid for an ID, zero if the module cannot pay it and its royalty. Check balanceBidOn before selling.", access: "view" },
          { signature: "ethRate() → uint256", description: "ETH rate for the reference score of 100 points.", access: "view" },
          { signature: "spendState() → (uint64 bucket, uint128 budget, uint128 spent)", description: "Current ETH purchase bucket and spend.", access: "view" },
          { signature: "pilePage(uint256 startAfter, uint256 n) → uint256[]", description: "Page through Credits held in the pile.", access: "view" },
          { signature: "heldStatements() → uint256[]", description: "Statement IDs still held by the Core.", access: "view" },
          { signature: "settings() → Settings", description: "All current owner-controlled economic settings.", access: "view" },
        ],
      },
      {
        id: "credit-doors",
        title: "Credit doors",
        entries: [
          { signature: "sellForEth(uint256[] ids, uint256 minOut)", description: "Transfer approved Credits in and pay the caller in ETH.", errors: "ReturnLocked, SpendCapReached, PotTooSmall, Slippage" },
          { signature: "sellForBalance(uint256[] ids, uint256 minOut, address expectedToken)", description: "Transfer approved Credits in and pay in the module token. The token pin guards replacement.", errors: "BalanceBidOff, NoBalanceModule, BalanceTokenChanged, Slippage" },
          { signature: "buyListing(address adapter, uint256 id, bytes params)", description: "Buy one approved venue listing at or below the bid, subject to the ETH spend budget.", errors: "AdapterNotAllowed, AboveBid, SpendCapReached" },
          { signature: "swapCredit(uint256 inId, uint256 outId)", description: "Swap an eligible pile Credit for a holder's Credit of equal or higher score, burning the CC fee." },
        ],
      },
      {
        id: "statement-doors",
        title: "Statement doors",
        entries: [
          { signature: "compose() / compose(uint8 format)", description: "Compose 80 eligible pile Credits into a Statement when the next page is ready." },
          { signature: "composeChosen(uint256[80] ids, uint8 format)", description: "Choose the 80 Credits when the choice switch and CC holding requirement permit it." },
          { signature: "redeemStatement(uint256 sid)", description: "Redeem an eligible held Statement through the configured balance module.", errors: "NoBalanceModule, RedeemOff, NotEligible" },
          { signature: "sellTo(uint256 sid, address buyer) payable", description: "Controller-only settlement of a Statement sale.", access: "Controller only" },
        ],
      },
      {
        id: "operations",
        title: "Maintenance and authority",
        entries: [
          { signature: "book() / collectEscrow() / buyback()", description: "Book fee income, collect escrow, and burn CC with the buyback allocation.", access: "Permissionless, guarded by readiness" },
          { signature: "setSettings(Settings settings)", description: "Replace the complete settings struct, effective immediately.", access: "Owner only" },
          { signature: "setBalanceModule(address module)", description: "Bind or replace the module while unlocked.", access: "Owner only" },
          { signature: "migrate(uint256 amount)", description: "Move the bid pot and pile to the configured successor and retire the Core.", access: "Owner only" },
        ],
      },
      {
        id: "events",
        title: "Events to index",
        entries: [
          { signature: "CreditBought(id, from, cost, toArtist)", description: "A Credit entered the Core from a seller." },
          { signature: "ListingBought(id, adapter, caller, cost, paid, rate, toArtist)", description: "The Core swept an external listing." },
          { signature: "Composed(sid, ids, format, cost, price, caller)", description: "The pile became a Statement." },
          { signature: "StatementSoldTo(sid, buyer, price, toBuyback, toArtist, toOperator)", description: "The Core settled a Statement sale." },
          { signature: "SettingsSet(settings) / BalanceModuleSet(module, token, unit)", description: "Owner changes that alter subsequent calls and quotes." },
        ],
      },
    ],
  },
  {
    slug: "contracts/controller",
    group: "Contracts",
    title: "ControllerV1",
    eyebrow: "Contract / sale pricing",
    summary: "The Controller quotes and executes the engine's Statement and Credit sales. In value mode it protects quotes with a rate-limited balance pool reference.",
    source: "src/interfaces/IControllerV1.sol",
    sections: [
      {
        id: "prices",
        title: "Price reads",
        entries: [
          { signature: "priceOf(uint256 sid) → uint256", description: "Current Statement ask in wei.", access: "view" },
          { signature: "referenceOf(uint256 sid) → uint256", description: "Reference used by the Statement sale curve.", access: "view" },
          { signature: "atFloor(uint256 sid) → bool", description: "Whether a held Statement has reached the redemption floor rule.", access: "view" },
          { signature: "creditPrice(uint256 id) → uint256", description: "Current sale price for a held Credit.", access: "view" },
          { signature: "nextPage() → (bool ready, uint256[80] ids, uint8 format)", description: "Whether the Core can compose the next page.", access: "view" },
          { signature: "valuePerPoint(bool forSale) → (uint256 value, bool ok)", description: "Protected balance value per point and quote usability.", access: "view" },
          { signature: "spotPrice() → (uint256 spot, bool ok)", description: "Current pool spot and read status; it is distinct from the stored reference.", access: "view" },
        ],
      },
      {
        id: "sales",
        title: "Sale calls",
        entries: [
          { signature: "buy(uint256 sid) payable", description: "Buy a held Statement; the Controller settles through Core.sellTo.", errors: "NotForSale, Underpaid, NoQuote" },
          { signature: "buyCredit(uint256 id) payable", description: "Buy one pile Credit while the sale is enabled.", errors: "CreditSaleOff, NotForSale, Underpaid" },
          { signature: "buyCredits(uint256[] ids) payable", description: "Buy several eligible pile Credits in one payment.", errors: "CreditSaleOff, NotForSale, Underpaid" },
        ],
      },
      {
        id: "reference",
        title: "Reference and configuration",
        entries: [
          { signature: "refreshReference() → bool", description: "Move the stored reference toward a sampled spot when its cadence permits.", access: "Permissionless" },
          { signature: "referencePrice() → uint256 / referenceTime() → uint40", description: "Stored value and timestamp used by protected quotes.", access: "view" },
          { signature: "setBalancePoolKey(PoolKey key, uint256 expectedSpot)", description: "Set or reseed the pool key with an expected spot guard.", access: "Owner only" },
          { signature: "setQuote(Quote quote) / setSale(Sale sale) / setCredit(CreditSale credit)", description: "Change the quote bounds and sale policies.", access: "Owner only" },
        ],
      },
      {
        id: "events",
        title: "Events to index",
        entries: [
          { signature: "Bought(sid, buyer, price)", description: "Statement purchase; pair with Core.StatementSoldTo in the same transaction." },
          { signature: "AnchorMoved(sid, saleBps, anchorBps)", description: "A sale changed the curve anchor." },
          { signature: "ReferenceRefreshed(referencePrice, spot)", description: "Stored reference sampled a pool price." },
          { signature: "SaleSet(sale) / CreditSaleSet(credit) / QuoteSet(quote)", description: "Policy changes that affect later quotes." },
        ],
      },
    ],
  },
  {
    slug: "contracts/balance-module",
    group: "Contracts",
    title: "StatementBalanceModule",
    eyebrow: "Contract / balance custody",
    summary: "The module redeems Statements through the balance token, holds proceeds, and pays balance bids on Core instruction.",
    source: "src/interfaces/IStatementBalanceModule.sol",
    sections: [
      {
        id: "reads",
        title: "Reads",
        entries: [
          { signature: "available() → uint256", description: "Unowed balance available for bids. Zero until upstream retirement completes and the token opening time arrives.", access: "view" },
          { signature: "unitPerPoint() → uint256", description: "Fixed token unit per rating point used by this module.", access: "view" },
          { signature: "owed(address account) → uint256", description: "Payment accrued to an address after an incomplete token transfer.", access: "view" },
          { signature: "balanceToken() → address / core() → address", description: "Immutable bindings; compare with Core.balanceModule and Core.balanceToken.", access: "view" },
        ],
      },
      {
        id: "calls",
        title: "Calls",
        entries: [
          { signature: "redeem(uint256 statementId) → uint256 out", description: "Withdraw balance tokens for a transferred Statement and check its rating minimum.", access: "Core only", errors: "OnlyCore, RedeemedBelowRating" },
          { signature: "pay(address to, uint256 amount)", description: "Pay a Core-directed seller; an incomplete transfer can accrue an owed balance.", access: "Core only", errors: "OnlyCore, InsufficientAvailable" },
          { signature: "claim(address to) → uint256 amount", description: "Send the accrued owed[to] balance to that same address. Anyone may trigger the claim.", access: "Permissionless" },
          { signature: "migrateReserve() → uint256 amount", description: "Move unowed reserve to a same-token module of the retired Core's successor.", access: "Permissionless after retirement", errors: "CoreNotRetired, InvalidSuccessor" },
        ],
      },
      {
        id: "events",
        title: "Events to index",
        entries: [
          { signature: "PaymentAccrued(to, amount)", description: "A payment was owed after transfer shortfall." },
          { signature: "OwedClaimed(to, amount)", description: "An owed balance was claimed." },
          { signature: "ReserveMigrated(successor, module, amount)", description: "Unowed reserve moved to the successor module." },
        ],
      },
    ],
  },
  {
    slug: "contracts/credit-score-lens",
    group: "Contracts",
    title: "CreditScoreLens",
    eyebrow: "Contract / scores + traits",
    summary: "Read Credit scores, rarity, traits, and Statement totals from the deployed mainnet helper.",
    source: "src/interfaces/ICreditScoreLens.sol",
    sourceSnapshot: "web/docs-sources/ICreditScoreLens.sol",
    sourceRevision: "5875fbdbd830e85f4fb884a74c98f92c6a26a822",
    mainnetAddress: "0x7a3f3967cBB63E8d56e3f093069C62A25eebBda6",
    sections: [
      {
        id: "credit-reads",
        title: "Credit reads",
        entries: [
          { signature: "creditScore(uint256 creditId) → uint256 score", description: "Score in ten-thousandths of a point. For example, 1,324,012 means 132.4012 points.", access: "view", errors: "UnknownCredit for a never-minted ID" },
          { signature: "creditScores(uint256[] creditIds) → uint256[] scores", description: "Scores in input order, preserving duplicates. An empty input returns an empty array; an unknown ID reverts the whole call. Chunk large batches to fit the RPC call gas limit.", access: "view", errors: "UnknownCredit for any never-minted ID" },
          { signature: "creditRarity(uint256 creditId) → uint256 rarity", description: "Raw sum of rarity trait points, including the doubled eights contribution. It is not a percentile or the Credit score.", access: "view", errors: "UnknownCredit for a never-minted ID" },
          { signature: "creditTraits(uint256 creditId) → (mask, active, occupied, eights, band)", description: "Numeric CreditScore traits: active plate mask, inked bits, occupied cells, count of ASCII 8s, and registration band (0 to 5).", access: "view", errors: "UnknownCredit for a never-minted ID" },
        ],
      },
      {
        id: "statement-read",
        title: "Statement read",
        entries: [
          { signature: "statementScore(uint256 statementId) → uint256 score", description: "Stored total across all pages, including overprints. A never-composed ID returns zero. This read does not indicate ownership or redemption eligibility.", access: "view" },
        ],
      },
      {
        id: "sources",
        title: "Data sources",
        points: [
          "The helper reads the fixed Ethereum mainnet Credits, CreditScore, and Statements contracts. It has no write methods or events.",
          "Burned Credits retain their scores and traits. A Statement's total can change after an overprint.",
          "Registration bands: 0 Registered, 1 Nudge, 2 Slip, 3 Skew, 4 Drift, 5 Loose.",
          "All scores use 10,000 units per point. Preserve the raw integer for calculations.",
        ],
      },
    ],
  },
  {
    slug: "contracts/adapters",
    group: "Contracts",
    title: "Listing adapters",
    eyebrow: "Contract / venue boundary",
    summary: "An adapter prices one venue listing and returns the exact call the Core may execute. The Core approves adapters one by one.",
    source: "src/interfaces/IListingAdapter.sol",
    sections: [
      {
        id: "interface",
        title: "Shared interface",
        entries: [
          { signature: "price(uint256 id, bytes params) → (address target, uint256 value, bytes data, address offerer)", description: "Quote a listing for exactly one Credit and return its execution target, ETH value, calldata, and seller.", access: "view" },
          { signature: "Core.buyListing(address adapter, uint256 id, bytes params)", description: "The Core checks its allowlist, bid, budget, and resulting custody before executing the returned call." },
        ],
      },
      {
        id: "strategy",
        title: "CreditStrategyAdapter",
        points: [
          "Reads CreditStrategy.nftForSale(id); zero means NotForSale.",
          "Ignores params and returns the strategy's sellTargetNFT(id) call.",
          "The strategy is the offerer for the returned quote.",
        ],
      },
      {
        id: "seaport",
        title: "SeaportBasicAdapter",
        points: [
          "Decode params as BasicOrderParameters for a Seaport 1.6 basic order.",
          "Accept only an open native-ETH sale of exactly the requested Credit; payout recipients must be the seller or allowlisted.",
          "The Core owner can change allowed recipients. After adapters are locked, recipients can be removed but not added.",
        ],
        entries: [
          { signature: "setAllowedRecipient(address recipient, bool allowed)", description: "Maintain the Seaport payout allowlist.", access: "Core owner" },
          { signature: "RecipientSet(recipient, allowed)", description: "Allowlist change to index." },
        ],
      },
    ],
  },
];

export const docGroups = ["Start here", "Guides", "Contracts"] as const;

export function docHref(page: DocPage) {
  return page.slug ? `/docs/${page.slug}` : "/docs";
}

export function docPage(slug: string) {
  return docPages.find((page) => page.slug === slug);
}

export function entryId(section: DocSection, index: number) {
  return `${section.id}-${index + 1}`;
}
