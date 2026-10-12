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

export function shortHash(h: string): string {
  return `${h.slice(0, 6)}…`;
}

// clock time HH:MM:SS from a unix seconds timestamp.
export function clock(ts: number): string {
  const d = new Date(ts * 1000);
  const p = (x: number) => String(x).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}
