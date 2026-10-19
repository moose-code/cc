import { toEventSelector } from "viem";

export const CREDIT_TRANSFER_TOPIC = toEventSelector("Transfer(address,address,uint256)");
const GROUP_SIZE = 64;

type TransferLog = {
  address?: string;
  blockHash?: string | null;
  topics?: readonly (string | null)[];
} | null;

/** Only the current token's group is hydrated; ordered Transfer handlers still set every owner and state. */
export async function hydrateCreditPeers(
  logs: readonly TransferLog[],
  currentId: bigint,
  expected: { address: string; blockHash: string },
  hydrate: (ids: readonly bigint[]) => Promise<unknown>,
): Promise<void> {
  let found = false;
  for (const log of logs) {
    if (!log || log.address?.toLowerCase() !== expected.address.toLowerCase() ||
        log.blockHash?.toLowerCase() !== expected.blockHash.toLowerCase() ||
        log.topics?.length !== 4 || log.topics[0]?.toLowerCase() !== CREDIT_TRANSFER_TOPIC ||
        !/^0x[0-9a-fA-F]{64}$/.test(log.topics[3] ?? "")) {
      throw new Error("Credit peer logs do not match the event block and collection");
    }
    if (BigInt(log.topics[3]!) === currentId) found = true;
  }
  if (!found) throw new Error("Current Credit is missing from its event-block Transfer logs");

  const peers = new Set<bigint>();
  for (const log of logs) {
    peers.add(BigInt(log!.topics![3]!));
    if (peers.size === GROUP_SIZE) {
      if (peers.has(currentId)) {
        await hydrate([...peers]);
        return;
      }
      peers.clear();
    }
  }
  await hydrate([...peers]);
}
