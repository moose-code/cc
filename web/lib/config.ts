import { foundry, mainnet } from "wagmi/chains";
import type { Address } from "viem";

const addr = (v?: string): Address | undefined =>
  v && /^0x[0-9a-fA-F]{40}$/.test(v) ? (v as Address) : undefined;

// NEXT_PUBLIC_CHAIN_ID=31337 selects the local anvil fork (foundry chain).
// Every other value selects mainnet.
export const isLocal = process.env.NEXT_PUBLIC_CHAIN_ID === "31337";
export const chain = isLocal ? foundry : mainnet;

export const rpcUrl =
  process.env.NEXT_PUBLIC_RPC_URL ||
  (isLocal ? "http://127.0.0.1:8545" : "https://eth.drpc.org");

export const addresses = {
  core: addr(process.env.NEXT_PUBLIC_CORE),
  coreLens: addr(process.env.NEXT_PUBLIC_CORE_LENS),
  credits: addr(process.env.NEXT_PUBLIC_CREDITS),
  cc: addr(process.env.NEXT_PUBLIC_CC),
  router: addr(process.env.NEXT_PUBLIC_ROUTER),
};

// Contract links shown in the footer: only those with a configured address.
export type ContractLink = { label: string; address: Address };
export const contracts: ContractLink[] = [
  { label: "cc", address: addresses.cc },
  { label: "core", address: addresses.core },
  { label: "lens", address: addresses.coreLens },
  { label: "credits", address: addresses.credits },
  { label: "router", address: addresses.router },
].filter((c): c is ContractLink => Boolean(c.address));

export const deployBlock = process.env.NEXT_PUBLIC_DEPLOY_BLOCK
  ? BigInt(process.env.NEXT_PUBLIC_DEPLOY_BLOCK)
  : undefined;

// The CC/ETH v4 pool. Params are fixed by the launch config
// (script/config/mainnet.json): the live skim hook, the dynamic-fee flag and
// the tick spacing. Native ETH is currency0 (address(0) sorts first). The pool
// exists once the coin launches; price/quote/swap stay gated until then.
export const pool = {
  hook: (process.env.NEXT_PUBLIC_POOL_HOOK ||
    "0x2f7976bf73dE8e1D49D4c687404e527a75b0e8Cc") as Address,
  fee: Number(process.env.NEXT_PUBLIC_POOL_FEE || 8388608), // 0x800000 dynamic
  tickSpacing: Number(process.env.NEXT_PUBLIC_POOL_TICK_SPACING || 200),
};

// pool reads/quotes/swaps need the coin address (deployed at launch).
export const poolReady = Boolean(addresses.cc);

// Chainlink ETH/USD feed (mainnet, 8 decimals). Always live; drives USD prices.
export const ethUsdFeed =
  "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419" as Address;

// The feed and stats read on-chain only when a lens address is set. Until the
// engine deploys, the UI renders representative sample activity instead.
export const isLive = Boolean(addresses.coreLens && addresses.core);

export const wcProjectId =
  process.env.NEXT_PUBLIC_WC_PROJECT_ID || "credits_engine_demo";
