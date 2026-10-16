/** JSON counters retain exact raw units separately for every event-time token. */
export function addTokenPayment(totals: Record<string, string>, token: string, spent: bigint): Record<string, string> {
  const key = token.toLowerCase();
  return { ...totals, [key]: (BigInt(totals[key] ?? "0") + spent).toString() };
}
