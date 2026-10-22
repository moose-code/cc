// Read-only comparison math. Credits ratings are 1e4-scale points, BALANCE has 18 decimals.
// Never confuse a pool spot estimate with a fillable sell quote.
export const SCORE_SCALE = 10_000n;
export const BALANCE_PER_SCORE_UNIT = 10n ** 14n;
export const BPS = 10_000n;

export type Source = "OpenSea" | "CreditStrategy";
export type CreditAsk = {
  id: string;
  source: Source;
  priceWei: bigint;
  score: bigint;
  orderHash?: string;
};

type RawAsk = { id: string; price: string; score: string | null; hash?: string };

export function parseAsks(opensea: readonly RawAsk[], strategy: readonly RawAsk[]): CreditAsk[] {
  const out = new Map<string, CreditAsk>();
  const add = (raw: RawAsk, source: Source) => {
    if (!/^[0-9]+$/.test(raw.id) || !/^[0-9]+$/.test(raw.price) ||
        !raw.score || !/^[0-9]+$/.test(raw.score)) return;
    const priceWei = BigInt(raw.price);
    const score = BigInt(raw.score);
    if (priceWei === 0n || score === 0n) return;
    const row: CreditAsk = { id: raw.id, source, priceWei, score, orderHash: raw.hash };
    const key = source + ":" + raw.id;
    const old = out.get(key);
    if (!old || priceWei < old.priceWei) out.set(key, row);
  };
  opensea.forEach((a) => add(a, "OpenSea"));
  strategy.forEach((a) => add(a, "CreditStrategy"));
  return [...out.values()].sort((a, b) => {
    // Exact cross multiplication; prices and scores are BigInts, never floating-point sorting.
    const left = a.priceWei * b.score;
    const right = b.priceWei * a.score;
    if (left !== right) return left < right ? -1 : 1;
    return a.id.localeCompare(b.id);
  });
}

export function grossBalance(score: bigint): bigint {
  return score > 0n ? score * BALANCE_PER_SCORE_UNIT : 0n;
}

export function postedBalance(score: bigint, payoutBps: number): bigint {
  if (!Number.isInteger(payoutBps) || payoutBps < 0 || payoutBps > 10_000) throw new Error("invalid payout");
  return grossBalance(score) * BigInt(payoutBps) / BPS;
}

export function workingSurplus(
  score: bigint, actualSellerPayout: bigint, purchaseRoyaltyBps = 300, contributionBps = 1_000
): bigint {
  if (score < 0n || actualSellerPayout < 0n || purchaseRoyaltyBps < 0 || contributionBps < 0 ||
      purchaseRoyaltyBps > 10_000 || contributionBps > 10_000) throw new Error("invalid rate");
  const gross = grossBalance(score);
  const royalty = actualSellerPayout * BigInt(purchaseRoyaltyBps) / BPS;
  const claims = gross * BigInt(contributionBps) / BPS;
  return gross - actualSellerPayout - royalty - claims;
}

export function ethValueAtSpot(tokens: bigint, tokensPerEth?: number): number | undefined {
  if (!tokensPerEth || !Number.isFinite(tokensPerEth) || tokensPerEth <= 0) return undefined;
  return Number(tokens) / 1e18 / tokensPerEth;
}

export function relativeGap(ethReceived: number | undefined, askWei: bigint): number | undefined {
  if (ethReceived == null || !Number.isFinite(ethReceived) || askWei <= 0n) return undefined;
  return (ethReceived / (Number(askWei) / 1e18) - 1) * 100;
}

export function ethPerPoint(askWei: bigint, score: bigint): number | undefined {
  if (score <= 0n) return undefined;
  // one division of exact integers keeps round asks exact (0.03 ETH over 300 points is 0.0001, not 0.0000999…)
  return Number(askWei * 10_000n) / Number(score) / 1e18;
}

export function percentFromBalance(earned: bigint, base: bigint): number | undefined {
  return base > 0n ? Number(earned) / Number(base) * 100 : undefined;
}
