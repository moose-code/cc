import { formatUnits } from "viem";

export function commas(n: number, max = 0): string {
  return n.toLocaleString("en-US", { maximumFractionDigits: max });
}

// eth amount from wei, trimmed to `dp` and left padded with zeros for the feed
// column look (0.0071, 0.0345).
export function eth(wei: bigint, dp = 4): string {
  const v = Number(formatUnits(wei, 18));
  return v.toLocaleString("en-US", {
    minimumFractionDigits: dp,
    maximumFractionDigits: dp,
  });
}

export function ethShort(wei: bigint, dp = 2): string {
  return Number(formatUnits(wei, 18)).toLocaleString("en-US", {
    maximumFractionDigits: dp,
  });
}

export function tokens(wei: bigint, decimals = 18): string {
  return Math.floor(Number(formatUnits(wei, decimals))).toLocaleString("en-US");
}

// USD. Small per-token prices need more decimals than a dollar total.
export function usd(n: number): string {
  const dp = n >= 1 ? 2 : n >= 0.01 ? 4 : 6;
  return n.toLocaleString("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: dp,
    maximumFractionDigits: dp,
  });
}

export function shortAddr(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

// evm.now explorer (chain-aware). Standing rule: never chain-specific explorers.
export function evmNowAddress(a: string): string {
  return `https://evm.now/address/${a}?chainId=1`;
}

export function evmNowTx(h: string): string {
  return `https://evm.now/tx/${h}?chainId=1`;
}

export function shortHash(h: string): string {
  return `${h.slice(0, 6)}…`;
}

// relative time from a unix seconds timestamp: "just now", "5s ago", "3m ago".
export function relTime(ts: number): string {
  const s = Math.max(0, Math.floor(Date.now() / 1000) - ts);
  if (s < 5) return "just now";
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
}
