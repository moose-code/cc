// Administrative recovery after an operator has separately sent a same-nonce self-cancel. This command reads the
// chain, accounts its finalized gas, and clears the pending marker. It never signs or broadcasts a transaction.

import { isAddressEqual, type Address, type Hex, type PublicClient } from "viem";
import { loadConfig } from "./config.ts";
import { readClient } from "./chain.ts";
import { Ledger, PendingStore, utcDay } from "./ledger.ts";
import { log, safeError } from "./log.ts";

const hashPattern = /^0x[0-9a-fA-F]{64}$/;
function fail(reason: string): never { throw new Error(`recover: ${reason}`); }

export function checkRecoveryRpcUrls(chainId: number, urls: readonly string[]) {
  if (chainId === 1 && urls.some((u) => new URL(u).protocol !== "https:" || /^(localhost|127\..*|\[::1\])$/i.test(new URL(u).hostname))) {
    fail("mainnet recovery requires HTTPS read RPCs outside loopback");
  }
}

export async function recoverPending(
  client: PublicClient,
  pending: PendingStore,
  ledger: Ledger,
  expected: { chainId: number; address: Address },
  replacementHash: Hex,
): Promise<{ hash: Hex; status: "success" | "reverted"; spent: bigint }> {
  const original = pending.get();
  if (!original) fail("no pending transaction exists");
  if (!hashPattern.test(replacementHash) || replacementHash.toLowerCase() === original.hash.toLowerCase()) fail("a distinct replacement hash is required");
  if (original.chainId !== expected.chainId || !isAddressEqual(original.address, expected.address)) fail("pending chain or signer differs from the selected deployment");
  if (await client.getChainId() !== expected.chainId) fail("RPC chain differs from the selected deployment");

  const [tx, receipt, finalized, originalReceipt] = await Promise.all([
    client.getTransaction({ hash: replacementHash }),
    client.getTransactionReceipt({ hash: replacementHash }),
    client.getBlock({ blockTag: "finalized" }),
    // Raw RPC returns null for absence. A transport failure must propagate instead of being treated as absence.
    client.request({ method: "eth_getTransactionReceipt", params: [original.hash] }),
  ]);
  if (!tx || !receipt || finalized.number === null) fail("replacement or finalized block is unavailable");
  if (tx.hash.toLowerCase() !== replacementHash.toLowerCase() ||
      tx.nonce !== original.nonce || !isAddressEqual(tx.from, original.address) ||
      !tx.to || !isAddressEqual(tx.to, original.address) || tx.value !== 0n || tx.input !== "0x" ||
      (tx.chainId !== undefined && tx.chainId !== expected.chainId)) fail("replacement is not a same-nonce zero-value self-transfer");
  if (!tx.blockHash || tx.blockHash.toLowerCase() !== receipt.blockHash.toLowerCase() || tx.blockNumber !== receipt.blockNumber) {
    fail("replacement transaction and receipt disagree on the inclusion block");
  }
  // Blob fees are outside gasUsed * effectiveGasPrice, and EIP-7702 authorizations can change signer behavior.
  if (tx.type !== "legacy" && tx.type !== "eip2930" && tx.type !== "eip1559") fail("replacement has a transaction type with unaccounted effects or fees");
  if ("authorizationList" in tx && Array.isArray(tx.authorizationList)) fail("replacement carries an EIP-7702 authorization list");
  if (receipt.transactionHash.toLowerCase() !== replacementHash.toLowerCase() ||
      (receipt.status !== "success" && receipt.status !== "reverted") ||
      !isAddressEqual(receipt.from, original.address) || !receipt.to || !isAddressEqual(receipt.to, original.address)) {
    fail("replacement receipt does not confirm the self-transfer attempt");
  }
  if (receipt.blockNumber > finalized.number) fail("replacement receipt is not finalized");
  const canonical = await client.getBlock({ blockNumber: receipt.blockNumber });
  if (!canonical.hash || canonical.hash.toLowerCase() !== receipt.blockHash.toLowerCase()) fail("replacement receipt is not canonical");
  const finalizedNonce = await client.getTransactionCount({ address: original.address, blockTag: "finalized" });
  if (finalizedNonce <= original.nonce) fail("finalized signer nonce has not advanced past the pending nonce");
  // A successful self-call to a delegated signer could execute code despite empty calldata. A reverted call has no
  // execution-state effects; authorization-list transactions were already excluded above.
  if (receipt.status === "success") {
    const code = await client.getCode({ address: original.address, blockNumber: receipt.blockNumber });
    if (code && code !== "0x") fail("successful self-transfer executed at a signer with code");
  }

  if (originalReceipt !== null) {
    const prior = originalReceipt as { blockNumber?: unknown; blockHash?: unknown };
    if (typeof prior.blockNumber !== "string" || !/^0x[0-9a-fA-F]+$/.test(prior.blockNumber) ||
        typeof prior.blockHash !== "string" || !hashPattern.test(prior.blockHash)) fail("original receipt is malformed");
    const priorBlock = await client.getBlock({ blockNumber: BigInt(prior.blockNumber) });
    if (priorBlock.hash?.toLowerCase() === prior.blockHash.toLowerCase()) fail("original transaction has a canonical receipt");
  }

  const spent = receipt.gasUsed * receipt.effectiveGasPrice;
  if (!original.ledgerDay) {
    original.ledgerDay = utcDay(Date.now());
    pending.save(original);
  }
  ledger.record(spent, 0n, replacementHash, original.ledgerDay);
  pending.clear();
  return { hash: replacementHash, status: receipt.status, spent };
}

async function main() {
  const replacementHash = process.argv[2] as Hex | undefined;
  if (process.argv.length !== 3 || !replacementHash || !hashPattern.test(replacementHash)) fail("pass the replacement transaction hash as the sole argument");
  if (!process.env.KEEPER_ADDRESS) fail("KEEPER_ADDRESS must identify the keeper signer without loading its key");
  // Force address-only configuration so recovery never opens a keystore or signs, even if keeper variables are set.
  const cfg = loadConfig({ ...process.env, KEYSTORE: undefined, KEYSTORE_PASSWORD_FILE: undefined, IMPERSONATE: undefined, DRY_RUN: "1" });
  if (cfg.signer.kind !== "address") fail("address-only recovery configuration is required");
  checkRecoveryRpcUrls(cfg.record.chainId, cfg.rpcUrls);
  const pending = new PendingStore(cfg.stateDir);
  const ledger = new Ledger(cfg.stateDir, cfg.dailyBudget);
  const result = await recoverPending(readClient(cfg), pending, ledger, { chainId: cfg.record.chainId, address: cfg.signer.address }, replacementHash);
  log("info", "pending self-cancel accounted", { hash: result.hash, status: result.status, spent: result.spent, signer: cfg.signer.address, chainId: cfg.record.chainId });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => { log("error", "pending recovery failed", { error: e instanceof Error && e.message.startsWith("recover:") ? e.message : safeError(e) }); process.exit(1); });
}
