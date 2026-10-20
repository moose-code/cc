import type { Hash } from "viem";

export async function submitWithGasBuffer(
  estimate: () => Promise<bigint>,
  send: (gas: bigint) => Promise<Hash>,
  consentIsCurrent: () => boolean,
) {
  const check = () => { if (!consentIsCurrent()) throw new Error("Wallet or network changed. Review your selection again."); };
  check();
  const gas = await estimate();
  check();
  // A later state can need more gas than the estimate; preserve the existing 25-percent margin, rounded up.
  return send((gas * 12_500n + 9_999n) / 10_000n);
}
