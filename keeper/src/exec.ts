// The executor: one call at a time. Each decided call is simulated (eth_estimateGas from the keeper, which runs the
// call) at the latest block, rechecked against the profit rule at the measured gas, checked against the day's budget,
// then signed and sent through the private relays in order, and its receipt is awaited before anything else is sent.
// A dry run stops after the recheck and logs the call it would send.

import {
  createPublicClient,
  encodeFunctionData,
  http,
  type Address,
  type Hex,
  type PrivateKeyAccount,
  type PublicClient,
} from "viem";
import { coreAbi } from "@cc/engine/abis";
import { revertName, txError } from "@cc/engine/errors";
import type { Config } from "./config.ts";
import { recheck, type Intended, type Listing, type Policy, type State } from "./decide.ts";
import type { Breaker, Ledger } from "./ledger.ts";
import { alert } from "./alert.ts";
import { log, txUrl } from "./log.ts";

export type Signer = { address: Address; account?: PrivateKeyAccount; impersonate?: boolean };

export type Outcome =
  | { kind: "sent"; hash: Hex; status: "success" | "reverted"; spent: bigint; received: bigint }
  | { kind: "dry"; gas: bigint }
  | { kind: "skipped"; reason: string }
  | { kind: "failed"; reason: string };

// gas limit = measured gas * 1.25, as web/lib/tx.ts sends
const GAS_BUFFER_BPS = 12_500n;

export class Executor {
  private client: PublicClient;
  private cfg: Config;
  private policy: Policy;
  private signer: Signer;
  private ledger: Ledger;
  private breaker: Breaker;
  constructor(
    client: PublicClient,
    cfg: Config,
    policy: Policy,
    signer: Signer,
    ledger: Ledger,
    breaker: Breaker,
  ) {
    this.client = client;
    this.cfg = cfg;
    this.policy = policy;
    this.signer = signer;
    this.ledger = ledger;
    this.breaker = breaker;
  }

  private data(c: Intended): Hex {
    return encodeFunctionData({ abi: coreAbi, functionName: c.functionName as any, args: c.args as any });
  }

  // runs one decided call: returns what happened. never sends while another transaction of the keeper is pending
  async run(c: Intended, s: State, listing?: Listing): Promise<Outcome> {
    const chainId = this.cfg.record.chainId;
    if (this.breaker.paused(c.door)) return { kind: "skipped", reason: `door paused by the breaker until ${new Date(this.breaker.pausedUntil(c.door)!).toISOString()}` };
    const to = this.cfg.record.core;
    const data = this.data(c);

    // simulation: the node runs the call from the keeper at the latest block
    let gasUsed: bigint;
    try {
      gasUsed = await this.client.estimateGas({ account: this.signer.address, to, data });
    } catch (e) {
      // the purchase budget refills with the next bucket: a wait, not a listing fault
      if (revertName(e) === "SpendCapReached") return { kind: "skipped", reason: "SpendCapReached: waiting for the next bucket" };
      return { kind: "failed", reason: `simulation reverted: ${revertName(e) ?? txError(e)}` };
    }

    const gasNow = { baseFee: (await this.client.getBlock()).baseFeePerGas ?? s.baseFee };
    const r = recheck(c, s, listing, gasUsed, gasNow, this.policy);
    if (!r.ok) return { kind: "skipped", reason: `after simulation: payment ${r.payment} under cost ${r.cost} plus margin at ${gasUsed} gas` };

    if (c.dryOnly || this.cfg.dryRun) {
      log("info", c.dryOnly ? "intended (logged only)" : "dry run: would send", {
        door: c.door,
        fn: c.functionName,
        args: c.args,
        gas: gasUsed,
        payment: r.payment,
        cost: r.cost,
        ...c.note,
      });
      return { kind: "dry", gas: gasUsed };
    }

    if (!this.ledger.allows(r.cost)) {
      await alert(this.cfg.alertWebhook, "budget", "daily budget exhausted, paid doors wait for the next UTC day", { remaining: this.ledger.remaining(), cost: r.cost });
      return { kind: "skipped", reason: "daily budget exhausted" };
    }

    const pol = this.policy.doors[c.door];
    const tx = {
      to,
      data,
      gas: (gasUsed * GAS_BUFFER_BPS + 9_999n) / 10_000n,
      maxFeePerGas: pol.maxBaseFee + pol.tip,
      maxPriorityFeePerGas: pol.tip,
    };
    const before = await this.client.getBalance({ address: this.signer.address });
    let hash: Hex;
    try {
      hash = await this.send(tx, chainId);
    } catch (e) {
      const tripped = this.breaker.fail(c.door);
      if (tripped) await alert(this.cfg.alertWebhook, `breaker:${c.door}`, `${c.door} paused after repeated send failures`, { error: txError(e) });
      return { kind: "failed", reason: `send failed: ${txError(e)}` };
    }
    log("info", "sent", { door: c.door, fn: c.functionName, args: c.args, hash, url: txUrl(hash, chainId), gasLimit: tx.gas, ...c.note });

    const receipt = await this.waitReceipt(hash);
    if (!receipt) {
      // a private relay drops a transaction it will not include; the nonce stays free, so the next send replaces it
      const tripped = this.breaker.fail(c.door);
      if (tripped) await alert(this.cfg.alertWebhook, `breaker:${c.door}`, `${c.door} paused: receipts never came`, { hash, url: txUrl(hash, chainId) });
      return { kind: "failed", reason: `no receipt within ${this.cfg.receiptTimeoutSec} s` };
    }
    const spent = receipt.gasUsed * receipt.effectiveGasPrice;
    const after = await this.client.getBalance({ address: this.signer.address, blockNumber: receipt.blockNumber });
    // the keeper's balance moves only by this transaction: received = after - before + spent
    const received = after + spent > before ? after + spent - before : 0n;
    this.ledger.record(spent, received, hash);
    const fields = { door: c.door, hash, url: txUrl(hash, chainId), block: receipt.blockNumber, gasUsed: receipt.gasUsed, spent, received, net: received - spent };
    if (receipt.status === "success") {
      this.breaker.ok(c.door);
      log("info", "confirmed", fields);
    } else {
      log("error", "reverted on chain", fields);
      if (this.breaker.fail(c.door)) await alert(this.cfg.alertWebhook, `breaker:${c.door}`, `${c.door} paused after repeated on chain reverts`, fields);
    }
    if (after < this.cfg.lowBalance) await alert(this.cfg.alertWebhook, "balance", "keeper balance low, top up", { balance: after, address: this.signer.address });
    return { kind: "sent", hash, status: receipt.status, spent, received };
  }

  // a signed transaction goes to each relay in order until one accepts it; without relays (a local node) to the read
  // node. an impersonated account sends unsigned through eth_sendTransaction on a local node
  private async send(tx: { to: Address; data: Hex; gas: bigint; maxFeePerGas: bigint; maxPriorityFeePerGas: bigint }, chainId: number): Promise<Hex> {
    const hex = (v: bigint) => `0x${v.toString(16)}`;
    if (this.signer.impersonate) {
      return (await this.client.request({
        method: "eth_sendTransaction" as any,
        params: [{ from: this.signer.address, to: tx.to, data: tx.data, gas: hex(tx.gas), maxFeePerGas: hex(tx.maxFeePerGas), maxPriorityFeePerGas: hex(tx.maxPriorityFeePerGas) }] as any,
      })) as Hex;
    }
    const account = this.signer.account!;
    const nonce = await this.client.getTransactionCount({ address: account.address, blockTag: "pending" });
    const raw = await account.signTransaction({ type: "eip1559", chainId, nonce, ...tx });
    const relays = this.cfg.relayUrls;
    if (relays.length === 0) return (await this.client.request({ method: "eth_sendRawTransaction", params: [raw] })) as Hex;
    let last: unknown;
    for (const url of relays) {
      try {
        const relay = createPublicClient({ transport: http(url, { timeout: 15_000, retryCount: 0 }) });
        const hash = (await relay.request({ method: "eth_sendRawTransaction", params: [raw] })) as Hex;
        if (url !== relays[0]) log("warn", "relay fallback took the transaction", { relay: new URL(url).host });
        return hash;
      } catch (e) {
        last = e;
        log("warn", "relay refused", { relay: new URL(url).host, error: txError(e) });
      }
    }
    throw last;
  }

  private async waitReceipt(hash: Hex) {
    const end = Date.now() + this.cfg.receiptTimeoutSec * 1000;
    while (Date.now() < end) {
      try {
        const r = await this.client.getTransactionReceipt({ hash });
        if (r) return r;
      } catch {}
      await new Promise((res) => setTimeout(res, 2_000));
    }
    return undefined;
  }
}
