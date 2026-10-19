// A chain-id-1 fork uses only the explicitly selected loopback RPC from its deployment record.
// Live chain 1 continues to use the configured public endpoint fallback.
export function localRpc(chainId: number, recordUrl: string | undefined, explicitUrl: string | undefined): string | undefined {
  if (chainId !== 1) return chainId === 31337 ? explicitUrl || recordUrl : undefined;
  const loopback = (value: string | undefined): boolean => {
    if (!value) return false;
    try {
      const host = new URL(value).hostname;
      return host === "localhost" || host === "127.0.0.1" || host === "[::1]";
    } catch {
      return false;
    }
  };
  if (!loopback(recordUrl) && !loopback(explicitUrl)) return undefined;
  if (!loopback(recordUrl) || !loopback(explicitUrl) || recordUrl !== explicitUrl) {
    throw new Error("chain-id-1 fork requires RPC_URL to match the record's loopback rpcUrl. Refusing public fallback.");
  }
  return explicitUrl;
}
