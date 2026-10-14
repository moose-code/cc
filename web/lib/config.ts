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

// The mock connector sends wallet requests to chain.rpcUrls.default.
export const chain = isLocal
  ? { ...foundry, rpcUrls: { default: { http: [rpcUrl] } } }
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

export const deployBlock = process.env.NEXT_PUBLIC_DEPLOY_BLOCK
  ? BigInt(process.env.NEXT_PUBLIC_DEPLOY_BLOCK)
  : undefined;

// Every engine read and page needs the Core; without it the pages render "engine not deployed".
export const engineDeployed = Boolean(core);

export const wcProjectId = process.env.NEXT_PUBLIC_WC_PROJECT_ID || "credits_engine";
