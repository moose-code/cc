import { controllerAbi } from "./abis";
import type { Snapshot } from "./live";
import type { Write } from "./tx";

const BUFFER_BPS = 200n; // value above the summed prices; the controller refunds the excess

// buyCredit for one id, buyCredits for several, paying `price` (sum of the credit prices) plus the buffer.
export async function buyCredits(write: Write, snap: Snapshot, ids: number[], price: bigint) {
  const value = price + (price * BUFFER_BPS) / 10000n;
  const args = ids.map(BigInt);
  await write(
    args.length === 1
      ? { address: snap.controller, abi: controllerAbi, functionName: "buyCredit", args: [args[0]], value }
      : { address: snap.controller, abi: controllerAbi, functionName: "buyCredits", args: [args], value }
  );
}
