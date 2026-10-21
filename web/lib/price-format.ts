import { formatUnits } from "viem";

// Price display helpers with no app imports, so node selfchecks can load them directly.

export const SUBSCRIPT_DIGITS = ["₀", "₁", "₂", "₃", "₄", "₅", "₆", "₇", "₈", "₉"];

export function decimalAmount(n: number): string {
  if (n > 0 && n < 0.01) return "<0.01";
  return n.toLocaleString("en-US", { maximumFractionDigits: 2 });
}

// A positive value under 0.001 in subscript-zero notation with three significant digits (0.0₄451 is 0.0000451).
// toExponential avoids the fixed-point artifacts of toFixed on tiny values
export function subscriptZeros(value: number): string {
  const [mantissa, exp] = value.toExponential().split("e");
  const zeros = -parseInt(exp, 10) - 1;
  const sig = mantissa.replace(".", "").slice(0, 3);
  return `0.0${String(zeros).split("").map((d) => SUBSCRIPT_DIGITS[Number(d)]).join("")}${sig}`;
}

// A per-point ETH price. The two-decimal rule would show every per-point bid as "<0.01" (0.0045 ETH per 100 points
// is 0.000045 per point), so small prices keep three significant digits: 0.00451, then subscript zeros below 0.001.
export function ethPerPointPrice(wei: bigint): string {
  const v = Number(formatUnits(wei, 18));
  if (v >= 0.01 || v <= 0) return decimalAmount(v);
  return v < 0.001 ? subscriptZeros(v) : v.toPrecision(3);
}

