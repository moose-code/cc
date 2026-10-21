import type { Hash, PublicClient } from "viem";

export async function waitForSuccessfulReceipt(client: Pick<PublicClient, "waitForTransactionReceipt">, hash: Hash) {
  let replaced = false;
  const receipt = await client.waitForTransactionReceipt({
    hash,
    onReplaced: ({ reason }) => { if (reason !== "repriced") replaced = true; },
  });
  if (replaced) throw new Error("Transaction cancelled or replaced. Review the transaction before retrying.");
  if (receipt.status !== "success") throw new Error("transaction reverted");
  return receipt;
}
