// Estimate of what Core.sellForEth pays for n credits in one call. Each credit
// pays min(rate, pot left), then the rate falls dropPerCreditBps, held at or
// above dropFloorBps of the rate at the first fill. The first fill of the batch
// is taken as the minute's first fill, so a fill earlier in the same minute
// makes the contract pay less than this; callers keep a margin under it.
export function estimateSell(
  n: number,
  s: { ethRate: bigint; ethPrice: bigint; ethPot: bigint; dropPerCreditBps: number; dropFloorBps: number }
): bigint {
  let r = s.ethPrice;
  let left = s.ethPot > s.ethRate ? s.ethPot : s.ethRate; // ethRate above ethPot: the unbooked fees lift the pot
  const floor = (s.ethPrice * BigInt(s.dropFloorBps)) / 10000n;
  let total = 0n;
  for (let i = 0; i < n; i++) {
    const x = r < left ? r : left;
    total += x;
    left -= x;
    const dropped = (r * BigInt(10000 - s.dropPerCreditBps)) / 10000n;
    r = dropped > floor ? dropped : floor;
  }
  return total;
}
