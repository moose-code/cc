// The keeper's configuration: every value comes from the environment, parsed once at start. The keystore and its
// password file are paths, and the OpenSea key and the alert webhook are read from the shell environment and kept out
// of the logs.

import { existsSync, readFileSync, realpathSync } from "node:fs";
import { dirname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { getAddress, parseEther, parseGwei, type Address } from "viem";

export type Door = "buyListing" | "buyback" | "compose" | "collectEscrow" | "book" | "redeemStatement";
export const DOORS: readonly Door[] = ["buyListing", "buyback", "compose", "collectEscrow", "book", "redeemStatement"];

// the owner key never signs a keeper transaction (decision 57)
export const OWNER: Address = "0xCB43078C32423F5348Cab5885911C3B5faE217F9";

// launch default relays (decision 139): MEV Blocker first, Flashbots Protect as the fallback
export const DEFAULT_RELAYS = ["https://rpc.mevblocker.io", "https://rpc.flashbots.net/fast"];
// public mainnet read fallbacks behind RPC_URLS (docs/RUNBOOK.md section 0 and .env.example list archive capable ones)
export const PUBLIC_RPCS = ["https://gateway.tenderly.co/public/mainnet", "https://eth.drpc.org", "https://ethereum-rpc.publicnode.com"];

export interface Deployment {
  chainId: number;
  core: Address;
  controller: Address;
  seaportAdapter: Address;
  strategyAdapter: Address;
  deployBlock?: number;
}

export interface DoorPolicy {
  // the most base fee the keeper sends at; the transaction's maxFeePerGas is this plus the tip
  maxBaseFee: bigint;
  // the priority fee the keeper pays
  tip: bigint;
}

export interface Config {
  rpcUrls: string[];
  relayUrls: string[];
  record: Deployment;
  signer:
    | { kind: "keystore"; path: string; passwordFile: string }
    | { kind: "impersonate"; address: Address }
    | { kind: "address"; address: Address };
  dryRun: boolean;
  doors: Record<Door, DoorPolicy>;
  // the margin every paid door must clear above its own gas cost, wei
  margin: bigint;
  // the gross gas spend allowed per UTC day, wei
  dailyBudget: bigint;
  // a listing must be seen sweepable this long before the keeper sweeps it (decision 137)
  listingDelaySec: number;
  tickMs: number;
  breakerThreshold: number;
  breakerPauseSec: number;
  receiptTimeoutSec: number;
  stateDir: string;
  alertWebhook?: string;
  // ETH balance under which the keeper alerts
  lowBalance: bigint;
  strategy: { mode: "tokensOf" } | { mode: "ids"; ids: bigint[] } | { mode: "off" };
  strategyRefreshSec: number;
  opensea: { key?: string; refreshSec: number; pages: number; sign: number; file?: string };
  doorsOn: Set<Door>;
}

type Env = { [k: string]: string | undefined };

const list = (v: string | undefined) => (v ?? "").split(",").map((s) => s.trim()).filter(Boolean);
const num = (env: Env, k: string, d: number) => {
  const v = env[k];
  if (v === undefined || v === "") return d;
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0) throw new Error(`config: ${k} must be a non negative number`);
  return n;
};
const gwei = (env: Env, k: string, d: string) => parseGwei(env[k] || d);
const ether = (env: Env, k: string, d: string) => parseEther(env[k] || d);

// the nearest ancestor of `from` that holds a .git entry (a directory, or the file of a git worktree)
function repoRoot(from: string): string | undefined {
  for (let d = resolve(from); ; d = dirname(d)) {
    if (existsSync(join(d, ".git"))) return d;
    if (dirname(d) === d) return undefined;
  }
}

// whether a path resolves inside the repository working tree of the process directory or of this package
export function insideRepo(path: string, cwd: string = process.cwd()): boolean {
  const abs = resolve(cwd, path);
  let real = abs;
  try {
    real = realpathSync(abs);
  } catch {}
  return [cwd, dirname(fileURLToPath(import.meta.url))].some((from) => {
    const root = repoRoot(from);
    return root !== undefined && (real === root || real.startsWith(root + sep));
  });
}

const isLocal = (url: string) => /^https?:\/\/(127\.0\.0\.1|localhost|\[::1\])(:|\/|$)/.test(url);

// the deployment record of docs/RUNBOOK.md section 7 (`deployments/<chainId>.json`)
export function readRecord(path: string): Deployment {
  const r = JSON.parse(readFileSync(path, "utf8"));
  for (const k of ["core", "controller", "seaportAdapter", "strategyAdapter"]) {
    if (!/^0x[0-9a-fA-F]{40}$/.test(r[k] ?? "")) throw new Error(`config: record ${path} has no ${k}`);
  }
  return {
    chainId: Number(r.chainId),
    core: getAddress(r.core),
    controller: getAddress(r.controller),
    seaportAdapter: getAddress(r.seaportAdapter),
    strategyAdapter: getAddress(r.strategyAdapter),
    deployBlock: r.deployBlock === undefined ? undefined : Number(r.deployBlock),
  };
}

// launch defaults per door: the paid keeper doors at the 5 gwei `keeperMaxBaseFee`, compose and redeem at the 3 gwei
// `callerMaxBaseFee` (decision 138), the unpaid doors at 3 gwei. a door never sends above its ceiling
// the default tips: compose spends about 8.5 million gas, so its 0.0003 eth `callerFee` covers a tip of at most about
// 0.035 gwei; the other doors use under 1.5 million gas
const DOOR_DEFAULT_TIP: { [d in Door]: string } = {
  buyListing: "0.05",
  buyback: "0.05",
  compose: "0.02",
  collectEscrow: "0.05",
  book: "0.05",
  redeemStatement: "0.05",
};

const DOOR_DEFAULT_BASEFEE: { [d in Door]: string } = {
  buyListing: "5",
  buyback: "5",
  compose: "3",
  collectEscrow: "3",
  book: "3",
  redeemStatement: "3",
};

export function loadConfig(env: Env, readRec: (p: string) => Deployment = readRecord): Config {
  const recordPath = env.RECORD ?? `deployments/${env.CHAIN_ID ?? "1"}.json`;
  const record = readRec(recordPath);
  const rpcUrls = list(env.RPC_URLS);
  if (record.chainId === 1 && !rpcUrls.every(isLocal)) {
    // mainnet: the listed rpcs first, then the public fallbacks, at least two in all
    for (const u of PUBLIC_RPCS) if (!rpcUrls.includes(u)) rpcUrls.push(u);
  }
  if (rpcUrls.length === 0) throw new Error("config: RPC_URLS is empty");
  const local = rpcUrls.every(isLocal);
  if (!local && rpcUrls.length < 3) throw new Error("config: a live chain needs RPC_URLS plus at least two public fallbacks");

  const relayUrls = env.RELAY_URLS === undefined ? (local ? [] : DEFAULT_RELAYS) : list(env.RELAY_URLS);
  if (!local && relayUrls.length === 0) throw new Error("config: a live chain sends only through a private relay (RELAY_URLS)");

  let signer: Config["signer"];
  if (env.IMPERSONATE) {
    // an anvil node signs for an impersonated account; refused anywhere but a local node
    if (!local) throw new Error("config: IMPERSONATE is for a local anvil node only");
    signer = { kind: "impersonate", address: getAddress(env.IMPERSONATE) };
  } else if (env.KEYSTORE) {
    if (!env.KEYSTORE_PASSWORD_FILE) throw new Error("config: KEYSTORE needs KEYSTORE_PASSWORD_FILE");
    for (const [k, v] of [["KEYSTORE", env.KEYSTORE], ["KEYSTORE_PASSWORD_FILE", env.KEYSTORE_PASSWORD_FILE]]) {
      if (insideRepo(v)) throw new Error(`config: ${k} resolves inside the repository working tree; keep key material outside it`);
    }
    signer = { kind: "keystore", path: env.KEYSTORE, passwordFile: env.KEYSTORE_PASSWORD_FILE };
  } else if (env.KEEPER_ADDRESS && env.DRY_RUN === "1") {
    // a dry run simulates from the keeper address without a key
    signer = { kind: "address", address: getAddress(env.KEEPER_ADDRESS) };
  } else {
    throw new Error("config: set KEYSTORE and KEYSTORE_PASSWORD_FILE (or KEEPER_ADDRESS with DRY_RUN=1)");
  }

  const doors = {} as Config["doors"];
  for (const d of DOORS) {
    const K = d.replace(/[A-Z]/g, (c) => "_" + c).toUpperCase();
    doors[d] = {
      maxBaseFee: gwei(env, `MAX_BASEFEE_GWEI_${K}`, env.MAX_BASEFEE_GWEI || DOOR_DEFAULT_BASEFEE[d]),
      tip: gwei(env, `MAX_PRIORITY_GWEI_${K}`, env.MAX_PRIORITY_GWEI || DOOR_DEFAULT_TIP[d]),
    };
  }

  const strategy: Config["strategy"] =
    env.STRATEGY_IDS === "off"
      ? { mode: "off" }
      : env.STRATEGY_IDS
        ? { mode: "ids", ids: list(env.STRATEGY_IDS).map(BigInt) }
        : { mode: "tokensOf" };

  const doorsOn = new Set<Door>(env.DOORS ? (list(env.DOORS) as Door[]) : DOORS);
  for (const d of doorsOn) if (!DOORS.includes(d)) throw new Error(`config: unknown door ${d}`);

  return {
    rpcUrls,
    relayUrls,
    record,
    signer,
    dryRun: env.DRY_RUN === "1",
    doors,
    margin: ether(env, "MARGIN_ETH", "0.00005"),
    dailyBudget: ether(env, "DAILY_BUDGET_ETH", "0.2"),
    listingDelaySec: num(env, "LISTING_DELAY_SEC", 120),
    tickMs: num(env, "TICK_MS", 12_000),
    breakerThreshold: num(env, "BREAKER_THRESHOLD", 3),
    breakerPauseSec: num(env, "BREAKER_PAUSE_SEC", 3600),
    receiptTimeoutSec: num(env, "RECEIPT_TIMEOUT_SEC", 300),
    stateDir: env.STATE_DIR ?? "keeper/.state",
    alertWebhook: env.ALERT_WEBHOOK_URL || undefined,
    lowBalance: ether(env, "LOW_BALANCE_ETH", "0.05"),
    strategy,
    strategyRefreshSec: num(env, "STRATEGY_REFRESH_SEC", 600),
    opensea: {
      key: env.OPENSEA_API_KEY || undefined,
      refreshSec: num(env, "OPENSEA_REFRESH_SEC", 300),
      pages: num(env, "OPENSEA_PAGES", 3),
      sign: num(env, "OPENSEA_SIGN", 40),
      file: env.SEAPORT_ORDERS || undefined,
    },
    doorsOn,
  };
}

// the config as logged at start: secrets and secret paths reduced to whether they are set
export function describe(c: Config) {
  return {
    chainId: c.record.chainId,
    core: c.record.core,
    rpcs: c.rpcUrls.length,
    relays: c.relayUrls.map((u) => new URL(u).host),
    signer: c.signer.kind,
    dryRun: c.dryRun,
    doors: Object.fromEntries(
      Object.entries(c.doors).map(([d, p]) => [d, { maxBaseFeeGwei: Number(p.maxBaseFee) / 1e9, tipGwei: Number(p.tip) / 1e9 }]),
    ),
    doorsOn: [...c.doorsOn],
    marginEth: Number(c.margin) / 1e18,
    dailyBudgetEth: Number(c.dailyBudget) / 1e18,
    listingDelaySec: c.listingDelaySec,
    strategy: c.strategy.mode,
    opensea: c.opensea.file ? "file" : c.opensea.key ? "api" : "off",
    alerts: Boolean(c.alertWebhook),
  };
}
