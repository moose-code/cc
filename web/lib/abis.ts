// Hand-written ABIs: the members the UI reads, and every event of the Core,
// ControllerV1 and FeeRouter, kept in sync with src/interfaces/ICoreLens.sol,
// ICore.sol, IControllerV1.sol and IFeeRouter.sol.

import { parseAbi } from "viem";

export const statementViewComponents = [
  { name: "id", type: "uint256" },
  { name: "cost", type: "uint256" },
  { name: "composedAt", type: "uint64" },
  { name: "rating", type: "uint256" },
  { name: "priceReference", type: "uint256" },
  { name: "askingPrice", type: "uint256" },
  { name: "exitEligible", type: "bool" },
] as const;

export const coreLensAbi = [
  {
    type: "function",
    name: "snapshot",
    stateMutability: "view",
    inputs: [],
    outputs: [
      {
        name: "s",
        type: "tuple",
        components: [
          { name: "ethRate", type: "uint256" },
          { name: "ethPrice", type: "uint256" },
          { name: "pileSize", type: "uint256" },
          { name: "pileHead", type: "uint256" },
          { name: "pageReady", type: "bool" },
          { name: "ethPot", type: "uint256" },
          { name: "ethToBuyback", type: "uint256" },
          { name: "ethRedeemBurn", type: "uint256" },
          { name: "xPot", type: "uint256" },
          { name: "unbookedEth", type: "uint256" },
          { name: "routerBalance", type: "uint256" },
          { name: "routerOwed", type: "uint256" },
          { name: "flushToCore", type: "uint256" },
          { name: "flushToPayees", type: "uint256" },
          { name: "controller", type: "address" },
          { name: "successor", type: "address" },
          { name: "exitModule", type: "address" },
          { name: "exitToken", type: "address" },
          { name: "exitMode", type: "uint256" },
          { name: "unitPerPoint", type: "uint256" },
          { name: "controllerLocked", type: "bool" },
          { name: "exitModuleLocked", type: "bool" },
          { name: "targetsLocked", type: "bool" },
          { name: "successorLocked", type: "bool" },
          { name: "creditSaleOn", type: "bool" },
          { name: "creditWindow", type: "uint256" },
          { name: "refScore", type: "uint32" },
          { name: "chosenComposeOn", type: "bool" },
          { name: "minCcToChoose", type: "uint256" },
          { name: "statements", type: "tuple[]", components: statementViewComponents },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "choosable",
    stateMutability: "view",
    inputs: [{ name: "id", type: "uint256" }],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "creditPriceOf",
    stateMutability: "view",
    inputs: [{ name: "id", type: "uint256" }],
    outputs: [{ name: "price", type: "uint256" }],
  },
  { type: "function", name: "CREDITS", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "STATEMENTS", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;

export const erc20Abi = [
  {
    type: "function",
    name: "totalSupply",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "a", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint8" }],
  },
  {
    type: "function",
    name: "symbol",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "string" }],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
  },
] as const;

// Chainlink aggregator: latest price (int256, 8 decimals for ETH/USD).
export const chainlinkAbi = [
  {
    type: "function",
    name: "latestRoundData",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
] as const;

// v4 StateView: packed pool slot0.
export const stateViewAbi = [
  {
    type: "function",
    name: "getSlot0",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [
      { name: "sqrtPriceX96", type: "uint160" },
      { name: "tick", type: "int24" },
      { name: "protocolFee", type: "uint24" },
      { name: "lpFee", type: "uint24" },
    ],
  },
] as const;

// v4 Quoter. Declared view so viem eth_calls it (the contract reverts-and-
// catches internally; eth_call ignores mutability).
export const quoterAbi = [
  {
    type: "function",
    name: "quoteExactInputSingle",
    stateMutability: "view",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          {
            name: "poolKey",
            type: "tuple",
            components: [
              { name: "currency0", type: "address" },
              { name: "currency1", type: "address" },
              { name: "fee", type: "uint24" },
              { name: "tickSpacing", type: "int24" },
              { name: "hooks", type: "address" },
            ],
          },
          { name: "zeroForOne", type: "bool" },
          { name: "exactAmount", type: "uint128" },
          { name: "hookData", type: "bytes" },
        ],
      },
    ],
    outputs: [
      { name: "amountOut", type: "uint256" },
      { name: "gasEstimate", type: "uint256" },
    ],
  },
] as const;

// Universal Router entrypoint.
export const universalRouterAbi = [
  {
    type: "function",
    name: "execute",
    stateMutability: "payable",
    inputs: [
      { name: "commands", type: "bytes" },
      { name: "inputs", type: "bytes[]" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [],
  },
] as const;

// Permit2: allowance granted to the Universal Router for an ERC20 input.
export const permit2Abi = [
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "token", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [
      { name: "amount", type: "uint160" },
      { name: "expiration", type: "uint48" },
      { name: "nonce", type: "uint48" },
    ],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "spender", type: "address" },
      { name: "amount", type: "uint160" },
      { name: "expiration", type: "uint48" },
    ],
    outputs: [],
  },
] as const;

// Core actions and views the UI uses.
export const coreAbi = [
  { type: "function", name: "compose", stateMutability: "nonpayable", inputs: [], outputs: [] },
  {
    type: "function",
    name: "composeChosen",
    stateMutability: "nonpayable",
    inputs: [
      { name: "ids", type: "uint256[80]" },
      { name: "format", type: "uint8" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "sellForEth",
    stateMutability: "nonpayable",
    inputs: [
      { name: "ids", type: "uint256[]" },
      { name: "minOut", type: "uint256" },
    ],
    outputs: [],
  },
  { type: "function", name: "controller", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "exitToken", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "HOOK", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "POOL_FEE", stateMutability: "view", inputs: [], outputs: [{ type: "uint24" }] },
  { type: "function", name: "TICK_SPACING", stateMutability: "view", inputs: [], outputs: [{ type: "int24" }] },
  { type: "function", name: "ethRate", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "ethPrice", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "ethPot", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "settings",
    stateMutability: "view",
    inputs: [],
    outputs: [
      {
        name: "",
        type: "tuple",
      components: [
        { name: "dropPerCreditBps", type: "uint16" },
        { name: "dropFloorBps", type: "uint16" },
        { name: "climbPerMinBps", type: "uint16" },
        { name: "ceilBps", type: "uint16" },
        { name: "idleLoosenBps", type: "uint16" },
        { name: "saleFloorBps", type: "uint16" },
        { name: "saleToBuybackBps", type: "uint16" },
        { name: "recoveryClimbPerMinBps", type: "uint16" },
        { name: "recoveryGapBps", type: "uint16" },
        { name: "peakHalfLife", type: "uint32" },
        { name: "buybackDelay", type: "uint16" },
        { name: "exitMode", type: "uint8" },
        { name: "exitSlippageBps", type: "uint16" },
        { name: "exitBidMarginBps", type: "uint16" },
        { name: "redeemBurnBps", type: "uint16" },
        { name: "buybackSlice", type: "uint128" },
        { name: "keeperFee", type: "uint64" },
        { name: "keeperMaxBaseFee", type: "uint48" },
        { name: "rateCap", type: "uint64" },
        { name: "callerFee", type: "uint64" },
        { name: "callerMaxBaseFee", type: "uint48" },
        { name: "feeToBuybackBps", type: "uint16" },
        { name: "feeToRedeemBurnBps", type: "uint16" },
      ],
      },
    ],
  },
  {
    type: "function",
    name: "pilePage",
    stateMutability: "view",
    inputs: [
      { name: "startAfter", type: "uint256" },
      { name: "n", type: "uint256" },
    ],
    outputs: [{ name: "ids", type: "uint256[]" }],
  },
  {
    type: "function",
    name: "creditInfo",
    stateMutability: "view",
    inputs: [{ name: "id", type: "uint256" }],
    outputs: [
      { name: "inPile", type: "bool" },
      { name: "cost", type: "uint256" },
      { name: "acquiredAt", type: "uint64" },
    ],
  },
] as const;

// ControllerV1 sale doors. The address is snapshot().controller.
export const controllerAbi = [
  { type: "function", name: "buy", stateMutability: "payable", inputs: [{ name: "sid", type: "uint256" }], outputs: [] },
  { type: "function", name: "buyCredit", stateMutability: "payable", inputs: [{ name: "id", type: "uint256" }], outputs: [] },
  { type: "function", name: "buyCredits", stateMutability: "payable", inputs: [{ name: "ids", type: "uint256[]" }], outputs: [] },
  { type: "function", name: "priceOf", stateMutability: "view", inputs: [{ name: "sid", type: "uint256" }], outputs: [{ name: "price", type: "uint256" }] },
  { type: "function", name: "referenceOf", stateMutability: "view", inputs: [{ name: "sid", type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "atFloor", stateMutability: "view", inputs: [{ name: "sid", type: "uint256" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "paused", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
] as const;

// Credits NFT: holdings and the Core approval.
export const creditsAbi = [
  { type: "function", name: "tokensOf", stateMutability: "view", inputs: [{ name: "owner", type: "address" }], outputs: [{ type: "uint256[]" }] },
  {
    type: "function",
    name: "isApprovedForAll",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "operator", type: "address" },
    ],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "setApprovalForAll",
    stateMutability: "nonpayable",
    inputs: [
      { name: "operator", type: "address" },
      { name: "approved", type: "bool" },
    ],
    outputs: [],
  },
] as const;

// Every event of the Core, ControllerV1 and FeeRouter. The Core and the router
// both emit OwnershipTransferStarted and OwnershipTransferred with one
// signature, listed once.
export const engineEventsAbi = parseAbi([
  // Core
  "event FeesAdded(uint256 amount)",
  "event Skimmed(uint256 eth, uint256 exitToken)",
  "event CreditBought(uint256 indexed id, address indexed from, uint256 cost)",
  "event ListingBought(uint256 indexed id, address indexed target, address indexed caller, uint256 cost, uint256 paid, uint256 rate)",
  "event EthRateFill(uint256 spent, uint256 rate, uint256 pot)",
  "event Composed(uint256 indexed sid, uint256[80] ids, uint8 format, uint256 cost, uint256 price, address indexed caller)",
  "event SettingsSet((uint16 dropPerCreditBps, uint16 dropFloorBps, uint16 climbPerMinBps, uint16 ceilBps, uint16 idleLoosenBps, uint16 saleFloorBps, uint16 saleToBuybackBps, uint16 recoveryClimbPerMinBps, uint16 recoveryGapBps, uint32 peakHalfLife, uint16 buybackDelay, uint8 exitMode, uint16 exitSlippageBps, uint16 exitBidMarginBps, uint16 redeemBurnBps, uint128 buybackSlice, uint64 keeperFee, uint48 keeperMaxBaseFee, uint64 rateCap, uint64 callerFee, uint48 callerMaxBaseFee, uint16 feeToBuybackBps, uint16 feeToRedeemBurnBps) settings)",
  "event RateSet(uint256 rate)",
  "event StatementExited(uint256 indexed sid, uint256 received)",
  "event Buyback(address indexed caller, uint256 amountIn, uint256 paid)",
  "event StatementSoldTo(uint256 indexed sid, address indexed buyer, uint256 price, uint256 toBuyback)",
  "event CreditSold(uint256 indexed id, address indexed buyer, uint256 price)",
  "event OwnershipTransferStarted(address indexed owner, address indexed pending)",
  "event OwnershipTransferred(address indexed from, address indexed to)",
  "event ControllerLocked()",
  "event ExitModuleLocked()",
  "event TargetsLocked()",
  "event ControllerSet(address controller)",
  "event ExitModuleSet(address exitModule, address exitToken, uint256 unitPerPoint)",
  "event UnitPerPointRefreshed(address exitModule, uint256 unitPerPoint)",
  "event RedeemBurnReleased(uint256 amount)",
  "event TargetAdded(address target)",
  "event TargetRemoved(address target)",
  "event CoinRescued(address indexed to, uint256 amount)",
  "event NftRescued(address indexed token, uint256 indexed id, address indexed to)",
  "event SuccessorSet(address successor)",
  "event SuccessorLocked()",
  "event CreditAdopted(uint256 indexed id, uint256 cost)",
  "event Migrated(address indexed successor, uint256 eth, uint256 exitTokens, uint256 credits)",
  "event EngineRetired(address indexed successor)",
  "event ExitTokenMigrationSkipped(address indexed successor, uint256 amount)",
  "event CreditCostToPotBpsSet(uint16 bps)",
  "event ChosenComposeOnSet(bool on)",
  "event MinCcToChooseSet(uint96 min)",
  // ControllerV1
  "event AnchorBpsSet(uint32 anchorBps)",
  "event AnchorHalfLifeSet(uint32 anchorHalfLife)",
  "event AnchorMinCostSet(uint128 anchorMinCost)",
  "event AnchorMoved(uint256 indexed sid, uint256 saleBps, uint32 anchorBps)",
  "event Bought(uint256 indexed sid, address indexed buyer, uint256 price)",
  "event CreditFloorBpsSet(uint16 creditFloorBps)",
  "event CreditSaleOnSet(bool on)",
  "event CreditStartBpsSet(uint32 creditStartBps)",
  "event CreditWindowSet(uint32 creditWindow)",
  "event ExitPoolKeySet(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)",
  "event FastDecayBpsPerHourSet(uint16 fastDecayBpsPerHour)",
  "event FloorBpsSet(uint16 floorBps)",
  "event KneeBpsSet(uint32 kneeBps)",
  "event MarkupBpsSet(uint16 markupBps)",
  "event PausedSet(bool paused)",
  "event RefScoreSet(uint32 refScore)",
  "event SlowDecayBpsPerHourSet(uint16 slowDecayBpsPerHour)",
  "event StartCapBpsSet(uint32 startCapBps)",
  // FeeRouter
  "event Claimed(address indexed payee, uint256 amount)",
  "event EngineSet(address indexed previous, address indexed engine)",
  "event Flushed(address indexed engine, uint256 toEngine, uint256 toPayees)",
  "event Locked(address indexed engine)",
  "event PayeeOwed(address indexed payee, uint256 amount)",
  "event PayeePaid(address indexed payee, uint256 amount)",
  "event PayeesSet(address[] payees, uint32[] ppm)",
  "event SplitStartSet(uint64 at)",
  "event SplitStarted(uint256 at)",
]);

// ERC-721 metadata read for the token art.
export const tokenUriAbi = parseAbi(["function tokenURI(uint256 id) view returns (string)"]);

// Pool hook: fee schedule of the CC/ETH pool, and the pool's MEV skim module.
export const hookAbi = parseAbi([
  "function skimConfig(bytes32 poolId) view returns ((uint24 baselineSkimBps, uint16 bountyBps, uint24 maxReferralBpsOfVolume, uint24 lpFeePips, address bountyRecipient, address protocolRecipient))",
  "function poolInfo(bytes32 poolId) view returns ((uint16 version, bool restricted, uint40 createdAt, address launcher, address token, address locker, address mevModule, address extension))",
]);
export const mevAbi = parseAbi(["function currentSkimBps(bytes32 poolId) view returns (uint24 skimBps, bool active)"]);

// FeeRouter views: the payees' share of each flush.
export const routerAbi = parseAbi([
  "function payeePpmTotal() view returns (uint32)",
  "function splitOn() view returns (bool)",
]);

// ERC-20 Transfer; the coin burn is Transfer(core, address(0), amount).
export const transferEventAbi = [
  {
    type: "event",
    name: "Transfer",
    inputs: [
      { name: "from", type: "address", indexed: true },
      { name: "to", type: "address", indexed: true },
      { name: "value", type: "uint256", indexed: false },
    ],
  },
] as const;
