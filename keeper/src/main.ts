// The keeper process: start checks, then one tick per new block (or per TICK_MS while blocks do not move). A tick reads
// the state at one block, decides, and runs the decided calls in priority order until one is sent; its receipt is
// awaited inside the tick, so the keeper never has two transactions in flight. `--once` runs one tick and exits.

import { privateKeyToAccount } from "viem/accounts";
import { isAddressEqual, type PublicClient } from "viem";
import { coreAbi } from "@cc/engine/abis";
import { txError } from "@cc/engine/errors";
import { describe, loadConfig, OWNER, type Config } from "./config.ts";
import { readClient, readFixed, readState, type Fixed } from "./chain.ts";
import { decide, type Intended, type Listing, type Policy, type Skip } from "./decide.ts";
import { Executor, type Outcome, type Signer } from "./exec.ts";
import { Breaker, Ledger } from "./ledger.ts";
import { Sources } from "./listings.ts";
import { readKeystore } from "./keystore.ts";
import { alert } from "./alert.ts";
import { log, safeError } from "./log.ts";

// a listing whose simulation reverted waits this long before it is tried again
const LISTING_COOLDOWN_SEC = 300;
// the head is polled this often; a tick runs per new block, or per TICK_MS while the head holds
const HEAD_POLL_MS = 4_000;
// the same skip reason of a door is logged again after this long
const SKIP_LOG_SEC = 600;

export async function startChecks(client: PublicClient, cfg: Config, fixed: Fixed, signer: Signer) {
  const chainId = await client.getChainId();
  if (chainId !== cfg.record.chainId) throw new Error(`start: the rpc is chain ${chainId}, the record is chain ${cfg.record.chainId}`);
  // the keeper runs on its own hot wallet, never the owner key (decision 57)
  if (isAddressEqual(signer.address, OWNER) || isAddressEqual(signer.address, fixed.owner)) {
    throw new Error(`start: refusing to run as the owner ${signer.address}; the keeper uses its own hot wallet`);
  }
  const code = await client.getCode({ address: signer.address });
  if (code && code.toLowerCase().startsWith("0xef0100")) {
    log("warn", "the keeper address is EIP-7702 delegated; its delegate can move its eth", { address: signer.address, delegate: "0x" + code.slice(8, 48) });
  }
  for (const a of [cfg.record.seaportAdapter, cfg.record.strategyAdapter]) {
    const ok = await client.readContract({ address: cfg.record.core, abi: coreAbi, functionName: "allowedAdapter", args: [a] });
    if (!ok) log("warn", "adapter not allowed by the Core", { adapter: a });
  }
  const balance = await client.getBalance({ address: signer.address });
  log("info", "keeper start", { address: signer.address, balance, ...describe(cfg) });
  if (!cfg.dryRun && balance < cfg.lowBalance) await alert(cfg.alertWebhook, "balance", "keeper balance low, top up", { balance, address: signer.address });
}

function makeSigner(cfg: Config): Signer {
  const s = cfg.signer;
  if (s.kind === "keystore") {
    const account = privateKeyToAccount(readKeystore(s.path, s.passwordFile));
    return { address: account.address, account };
  }
  if (s.kind === "impersonate") return { address: s.address, impersonate: true };
  return { address: s.address };
}

export interface TickResult {
  block: bigint;
  calls: Intended[];
  skips: Skip[];
  outcomes: { door: string; key: string; outcome: Outcome }[];
}

export class Keeper {
  private seen = new Map<string, bigint>();
  private skipLogged = new Map<string, number>();
  private client: PublicClient;
  private cfg: Config;
  private fixed: Fixed;
  private sources: Sources;
  private exec: Executor;
  readonly policy: Policy;
  constructor(
    client: PublicClient,
    cfg: Config,
    fixed: Fixed,
    sources: Sources,
    exec: Executor,
    policy: Policy,
  ) {
    this.client = client;
    this.cfg = cfg;
    this.fixed = fixed;
    this.sources = sources;
    this.exec = exec;
    this.policy = policy;
  }

  async tick(): Promise<TickResult> {
    const { state, snap } = await readState(this.client, this.cfg.record.core, this.fixed);
    const listings: Listing[] = this.cfg.doorsOn.has("buyListing") && !state.retired ? await this.sources.candidates(snap, state.blockNumber) : [];
    const d = decide(state, listings, { baseFee: state.baseFee }, this.policy, this.seen);
    this.seen = d.seen;
    const now = Date.now();
    for (const sk of d.skips) {
      const k = `${sk.door}|${sk.key ?? ""}|${sk.reason.replace(/\d+/g, "#")}`;
      if ((this.skipLogged.get(k) ?? 0) + SKIP_LOG_SEC * 1000 > now) continue;
      this.skipLogged.set(k, now);
      log("info", "skip", { block: state.blockNumber, ...sk });
    }
    // the reserve alert: a pot at or under the reserve halts every acquisition until fee income refills it; processing
    // (compose, redeem, buyback) keeps paying from the whole pot
    if (state.potRoom === 0n && !state.retired) {
      await alert(this.cfg.alertWebhook, "reserve", "the pot is at or under the reserve, the bids read zero", { pot: state.potWithPending, reserve: state.reserve });
    }
    const outcomes: TickResult["outcomes"] = [];
    for (const c of d.calls) {
      const listing = c.door === "buyListing" ? listings.find((l) => l.id === c.args[1] && l.adapter === c.args[0]) : undefined;
      const outcome = await this.exec.run(c, state, listing);
      outcomes.push({ door: c.door, key: c.key, outcome });
      if (outcome.kind === "failed" || outcome.kind === "skipped") log("info", "not sent", { block: state.blockNumber, door: c.door, key: c.key, reason: outcome.reason });
      if (outcome.kind === "failed" && listing) this.sources.coolDown(`${listing.venue}:${listing.id}`, LISTING_COOLDOWN_SEC);
      // one transaction per tick: the next decision reads the state after it
      if (outcome.kind === "sent") break;
    }
    log("info", "tick", {
      block: state.blockNumber,
      baseFee: state.baseFee,
      pot: state.potWithPending,
      reserve: state.reserve,
      toBuyback: state.ethToBuyback,
      candidates: listings.length,
      decided: d.calls.map((c) => c.key),
      sent: outcomes.filter((o) => o.outcome.kind === "sent").map((o) => o.key),
    });
    return { block: state.blockNumber, calls: d.calls, skips: d.skips, outcomes };
  }
}

export async function build(env: NodeJS.ProcessEnv = process.env) {
  const cfg = loadConfig(env);
  const client = readClient(cfg);
  const fixed = await readFixed(client, cfg.record.core);
  const signer = makeSigner(cfg);
  await startChecks(client, cfg, fixed, signer);
  const ledger = new Ledger(cfg.stateDir, cfg.dailyBudget);
  const breaker = new Breaker(cfg.breakerThreshold, cfg.breakerPauseSec);
  const policy: Policy = { doors: cfg.doors, doorsOn: cfg.doorsOn, margin: cfg.margin, listingDelaySec: cfg.listingDelaySec };
  const keeper = new Keeper(client, cfg, fixed, new Sources(client, cfg), new Executor(client, cfg, policy, signer, ledger, breaker), policy);
  return { cfg, client, keeper };
}

async function main() {
  const { cfg, client, keeper } = await build();
  if (process.argv.includes("--once")) {
    await keeper.tick();
    return;
  }
  let last = -1n;
  let lastAt = 0;
  let failures = 0;
  for (;;) {
    try {
      const n = await client.getBlockNumber();
      if (n !== last || Date.now() - lastAt >= cfg.tickMs) {
        last = n;
        lastAt = Date.now();
        await keeper.tick();
        failures = 0;
      }
    } catch (e) {
      failures++;
      log("error", "tick failed", { error: txError(e), failures });
      if (failures === 5) await alert(cfg.alertWebhook, "tick", "five ticks in a row failed", { error: txError(e) });
    }
    await new Promise((r) => setTimeout(r, HEAD_POLL_MS));
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => {
    log("error", "keeper stopped", { error: safeError(e) });
    process.exit(1);
  });
}
