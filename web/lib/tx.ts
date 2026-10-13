import { usePublicClient, useAccount, useWriteContract } from "wagmi";

// Gas limit = node estimate * 1.25. Prices move with block time, so a call can
// take a longer path at execution than at estimation; the margin covers it.
export const GAS_BUFFER_BPS = 12500n;

// useWriteContract whose writeContractAsync sets `gas` from estimateContractGas
// (same args, value, account) times GAS_BUFFER_BPS, rounded up.
export function useWriteWithBuffer() {
  const { writeContractAsync, isPending } = useWriteContract();
  const client = usePublicClient();
  const { address } = useAccount();

  const writeWithBuffer = async (req: any) => {
    if (!client || !address) throw new Error("wallet not connected");
    const est = await client.estimateContractGas({ ...req, account: address });
    const gas = (est * GAS_BUFFER_BPS + 9999n) / 10000n;
    return writeContractAsync({ ...req, gas });
  };

  return { writeWithBuffer, isPending };
}
