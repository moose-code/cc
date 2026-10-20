import { formatUnits } from "viem";
import { chain } from "./config";

export const BALANCE_SYMBOL = "$BALANCE";

export interface BalanceTokenInfo {
  address: `0x${string}`;
  decimals: number;
}

// A balance token amount without its symbol, to `dp` decimals at most; undefined until the token is read.
export function balanceAmount(v: bigint, info?: BalanceTokenInfo, dp = 6): string | undefined {
  return info ? Number(formatUnits(v, info.decimals)).toLocaleString("en-US", { maximumFractionDigits: dp }) : undefined;
}

// A balance token amount with its symbol; raw units until the token is read.
export function formatBalance(v: bigint, info?: BalanceTokenInfo): string {
  const n = balanceAmount(v, info);
  return n != null ? `${n} ${BALANCE_SYMBOL}` : `${v} ${BALANCE_SYMBOL} units`;
}

// Historical amounts retain their currency even after the owner selects another token.
export function formatHistoricalBalance(v: bigint, token?: string, info?: BalanceTokenInfo): string {
  if (!token) return `${v} raw units (token unknown)`;
  const known = info?.address.toLowerCase() === token.toLowerCase() ? info : undefined;
  return known ? `${formatBalance(v, known)} (${token})` : `${v} raw units (${token})`;
}

// "+58%" / "-12%" for a percentage number.
export function signedPct(n: number): string {
  const r = Math.round(n);
  return `${r >= 0 ? "+" : ""}${r}%`;
}

export function commas(n: number | bigint, max = 0): string {
  return typeof n === "bigint" ? n.toLocaleString("en-US") : n.toLocaleString("en-US", { maximumFractionDigits: max });
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

// Token price in USD: subscript-zero notation under $0.001 ($0.0₃151), copied
// from the artcoins site's PriceStats. "—" for a non-positive or non-finite value.
const SUBSCRIPT_DIGITS = ["₀", "₁", "₂", "₃", "₄", "₅", "₆", "₇", "₈", "₉"];
// A sub-cent price split for display: "$0.0", the count of further zeros, then three significant digits ($0.0₄983 is
// 0.0000983). zeros is undefined at a cent and above, where `text` is the whole price.
export function usdPriceParts(value: number): { text: string; zeros?: number; sig?: string } {
  if (!isFinite(value) || value <= 0 || value >= 0.001) return { text: usdPrice(value) };
  const [mantissa, exp] = value.toExponential().split("e");
  return { text: "$0.0", zeros: -parseInt(exp, 10) - 1, sig: mantissa.replace(".", "").slice(0, 3) };
}

export function usdPrice(value: number): string {
  if (!isFinite(value) || value <= 0) return "—";
  if (value < 0.001) {
    // toExponential avoids the fixed-point artifacts of toFixed on tiny values
    const [mantissa, exp] = value.toExponential().split("e");
    const zeros = -parseInt(exp, 10) - 1;
    const sig = mantissa.replace(".", "").slice(0, 3);
    return `$0.0${String(zeros).split("").map((d) => SUBSCRIPT_DIGITS[Number(d)]).join("")}${sig}`;
  }
  if (value < 1) return `$${value.toFixed(4)}`;
  if (value < 1000) return `$${value.toFixed(2)}`;
  if (value < 1_000_000) return `$${(value / 1000).toFixed(2)}K`;
  return `$${(value / 1_000_000).toFixed(2)}M`;
}

// Market cap in USD, compact ($111.9K), from the artcoins site's formatUsdMarketCap.
export function usdCompact(mc: number): string {
  if (mc < 1000) return `$${mc.toFixed(0)}`;
  if (mc < 1_000_000) return `$${(mc / 1000).toFixed(1)}K`;
  return `$${(mc / 1_000_000).toFixed(2)}M`;
}

// "+1.25%" / "-4.19%" / "0.00%"; no decimals from 100%.
export function changePct(pct: number): string {
  return `${pct > 0 ? "+" : ""}${pct.toFixed(Math.abs(pct) >= 100 ? 0 : 2)}%`;
}

export function shortAddr(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

// evm.now explorer (chain-aware). Standing rule: never chain-specific explorers.
export function evmNowAddress(a: string): string {
  return `https://evm.now/address/${a}?chainId=${chain.id}`;
}

export function evmNowTx(h: string): string {
  return `https://evm.now/tx/${h}?chainId=${chain.id}`;
}

export function shortHash(h: string): string {
  return `${h.slice(0, 6)}…`;
}

// "1h 5m", "3m 20s", "40s" from a remaining-seconds count.
export function leftLabel(s: number): string {
  s = Math.max(0, Math.floor(s));
  if (s >= 3600) return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
  if (s >= 60) return `${Math.floor(s / 60)}m ${s % 60}s`;
  return `${s}s`;
}

// "just now", "5s ago", "3m ago" from an elapsed-seconds count.
export function agoLabel(s: number): string {
  s = Math.max(0, Math.floor(s));
  if (s < 5) return "just now";
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
}

// relative time from a unix seconds timestamp; `now` is chain time (useNow).
export function relTime(ts: number, now: number): string {
  return agoLabel(now - ts);
}

// On-chain credit score (ten-thousandths of a point) as the displayed rating: score / 10,000.
// 4,330,000 -> "433", 1,324,012 -> "132.4", 800,000 -> "80". One decimal under 1,000 points, none above;
// trailing ".0" dropped; thousands separated.
export function rating(score: bigint | number): string {
  const v = Number(score) / 10_000;
  const s = v >= 1000 ? Math.round(v).toString() : v.toFixed(1).replace(/\.0$/, "");
  return s.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}
