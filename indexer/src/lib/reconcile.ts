export type ParityChecks = {
  pileSize: boolean;
  heldStatements: boolean;
  pileFirstPage: boolean;
  ethPot: boolean;
};

/** True when the on-chain pile page equals the indexed held credits ordered by pile order, element by element. */
export function pageMatches(onchain: readonly bigint[], indexed: readonly bigint[]): boolean {
  return onchain.length === indexed.length && onchain.every((id, i) => id === indexed[i]);
}

export const allPassed = (c: ParityChecks): boolean => c.pileSize && c.heldStatements && c.pileFirstPage && c.ethPot;
