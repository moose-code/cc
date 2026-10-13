// Minimal hand-written ABIs. Only the members the UI reads/decodes, kept in sync
// with src/interfaces/ICoreLens.sol, ICore.sol and IControllerV1.sol at c1fed1b.
// Not the full generated interface on purpose.

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

// Events the engine feed decodes from Core / ControllerV1 logs.
export const coreEventsAbi = [
  {
    type: "event",
    name: "FeesAdded",
    inputs: [{ name: "amount", type: "uint256", indexed: false }],
  },
  {
    type: "event",
    name: "CreditBought",
    inputs: [
      { name: "id", type: "uint256", indexed: true },
      { name: "from", type: "address", indexed: true },
      { name: "cost", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Composed",
    inputs: [
      { name: "sid", type: "uint256", indexed: true },
      { name: "ids", type: "uint256[80]", indexed: false },
      { name: "format", type: "uint8", indexed: false },
      { name: "cost", type: "uint256", indexed: false },
      { name: "caller", type: "address", indexed: true },
    ],
  },
  {
    type: "event",
    name: "CreditSold",
    inputs: [
      { name: "id", type: "uint256", indexed: true },
      { name: "buyer", type: "address", indexed: true },
      { name: "price", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "StatementSoldTo",
    inputs: [
      { name: "sid", type: "uint256", indexed: true },
      { name: "buyer", type: "address", indexed: true },
      { name: "price", type: "uint256", indexed: false },
      { name: "toBuyback", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "StatementExited",
    inputs: [
      { name: "sid", type: "uint256", indexed: true },
      { name: "received", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Buyback",
    inputs: [
      { name: "caller", type: "address", indexed: true },
      { name: "amountIn", type: "uint256", indexed: false },
      { name: "paid", type: "uint256", indexed: false },
    ],
  },
] as const;

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
