import { foundry, mainnet } from "wagmi/chains";
import type { Address } from "viem";

const addr = (v?: string): Address | undefined =>
  v && /^0x[0-9a-fA-F]{40}$/.test(v) ? (v as Address) : undefined;

// NEXT_PUBLIC_CHAIN_ID=31337 selects the local anvil fork (foundry chain).
// Every other value selects mainnet.
export const isLocal = process.env.NEXT_PUBLIC_CHAIN_ID === "31337";

export const rpcUrl =
  process.env.NEXT_PUBLIC_RPC_URL ||
  (isLocal ? "http://127.0.0.1:8545" : "https://eth.drpc.org");

// The mock connector sends wallet requests to chain.rpcUrls.default. The injected
// wallet's "add network" prompt takes id, name, currency and rpc from this definition.
export const chain = isLocal
  ? { ...foundry, name: "anvil", rpcUrls: { default: { http: [rpcUrl] } } }
  : mainnet;

// Local only: the accounts of the deployment record the app can act as. anvil
// runs with --auto-impersonate, so it signs for them without a key.
export const localAccounts: { name: string; address: Address }[] = (() => {
  try {
    const rec = JSON.parse(process.env.NEXT_PUBLIC_LOCAL_ACCOUNTS ?? "{}") as Record<string, string>;
    return Object.entries(rec).flatMap(([name, a]) => (addr(a) ? [{ name, address: addr(a)! }] : []));
  } catch {
    return [];
  }
})();

// The Core. The controller, the coin and the balance module are read from it.
export const core = addr(process.env.NEXT_PUBLIC_CORE);

// Fixed collections (docs/INTEGRATION.md section 1).
export const credits: Address = "0x97630aA70AB14ed9883B41dAfccBc11349723043";
export const statements: Address = "0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b";

// Listing venues (docs/INDEXER.md section 9.1, owner decision 134): the CreditStrategy proxy, and the two adapters the
// Core allows for Core.buyListing (deployment record keys strategyAdapter, seaportAdapter).
export const strategy: Address = "0x8e607209899b5d12Bd3167a6CD0E8E11FEB053d6";
export const strategyAdapter = addr(process.env.NEXT_PUBLIC_STRATEGY_ADAPTER);
export const seaportAdapter = addr(process.env.NEXT_PUBLIC_SEAPORT_ADAPTER);
// First block of the browser scan of CreditStrategy events (chain mode); the proxy deploy block.
export const strategyStartBlock = BigInt(process.env.NEXT_PUBLIC_STRATEGY_START_BLOCK || 26037623);

// The coin/eth v4 pool: the live skim hook, the dynamic-fee flag and the tick
// spacing. The defaults are the mainnet launch params; the local record
// overrides them (scripts/local-env.mjs). Native ETH is currency0.
export const pool = {
  hook: (addr(process.env.NEXT_PUBLIC_POOL_HOOK) ?? "0x2f7976bf73dE8e1D49D4c687404e527a75b0e8Cc") as Address,
  fee: Number(process.env.NEXT_PUBLIC_POOL_FEE || 8388608), // 0x800000 dynamic
  tickSpacing: Number(process.env.NEXT_PUBLIC_POOL_TICK_SPACING || 200),
};

// Chainlink ETH/USD feed (8 decimals).
export const ethUsdFeed: Address = "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419";

export const deployBlock = process.env.NEXT_PUBLIC_DEPLOY_BLOCK
  ? BigInt(process.env.NEXT_PUBLIC_DEPLOY_BLOCK)
  : undefined;

// The indexer (docs/INDEXER.md): history, lists and slow-moving state. Unset, the pages render live state only.
export const indexerUrl = (process.env.NEXT_PUBLIC_INDEXER_URL || "").replace(/\/+$/, "") || undefined;

// Credits composed into one statement (the length of Composed.ids).
export const STATEMENT_SIZE = 80;

// Every engine read and page needs the Core; without it the pages render "engine not deployed".
export const engineDeployed = Boolean(core);

export const wcProjectId = process.env.NEXT_PUBLIC_WC_PROJECT_ID || "credits_engine";
