// A current indexer for another Core must never become the source of this site's history.
export function indexedBlockForChain(
  status: Record<string, { id: number; block: { number: number } }>,
  chainId: number,
): number | undefined {
  return Object.values(status).find((entry) => entry.id === chainId)?.block.number;
}

export function matchesIndexerIdentity(
  expectedCore: string | undefined,
  expectedCoin: string | undefined,
  expectedDeployBlock: bigint | undefined,
  indexed: { core: string; coin: string | null; deployBlock: bigint } | undefined,
): boolean {
  return Boolean(expectedCore && expectedCoin && expectedDeployBlock !== undefined && indexed &&
    indexed.core.toLowerCase() === expectedCore.toLowerCase() &&
    indexed.coin?.toLowerCase() === expectedCoin.toLowerCase() &&
    indexed.deployBlock === expectedDeployBlock);
}
