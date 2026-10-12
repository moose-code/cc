// Minimal hand-written ABIs. Only the members the UI reads/decodes, kept in sync
// with src/interfaces/ICoreLens.sol and the events in src/Core.sol /
// src/ControllerV1.sol. Not the full generated interface on purpose.

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
          { name: "ethPileSize", type: "uint256" },
          { name: "ethPileHead", type: "uint256" },
          { name: "exitPileSize", type: "uint256" },
          { name: "exitPileHead", type: "uint256" },
          { name: "ethPageReady", type: "bool" },
          { name: "exitPageReady", type: "bool" },
          { name: "ethPot", type: "uint256" },
          { name: "ethToBuyback", type: "uint256" },
          { name: "xPot", type: "uint256" },
          { name: "xToBuyback", type: "uint256" },
          { name: "unbookedEth", type: "uint256" },
          { name: "routerBalance", type: "uint256" },
          { name: "routerOwed", type: "uint256" },
          { name: "flushToCore", type: "uint256" },
          { name: "flushToPayees", type: "uint256" },
          { name: "controller", type: "address" },
          { name: "successor", type: "address" },
          { name: "controllerLocked", type: "bool" },
          { name: "exitModuleLocked", type: "bool" },
          { name: "targetsLocked", type: "bool" },
          { name: "successorLocked", type: "bool" },
          {
            name: "statements",
            type: "tuple[]",
            components: [
              { name: "id", type: "uint256" },
              { name: "lane", type: "uint8" },
              { name: "cost", type: "uint256" },
              { name: "composedAt", type: "uint64" },
              { name: "askingPrice", type: "uint256" },
            ],
          },
        ],
      },
    ],
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
      { name: "lane", type: "uint8", indexed: false },
      { name: "cost", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Composed",
    inputs: [
      { name: "sid", type: "uint256", indexed: true },
      { name: "lane", type: "uint8", indexed: false },
      { name: "format", type: "uint8", indexed: false },
      { name: "cost", type: "uint256", indexed: false },
      { name: "caller", type: "address", indexed: true },
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
    name: "Buyback",
    inputs: [
      { name: "caller", type: "address", indexed: true },
      { name: "amountIn", type: "uint256", indexed: false },
      { name: "paid", type: "uint256", indexed: false },
    ],
  },
] as const;
