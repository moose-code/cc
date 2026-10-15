// Compose estimate for a held credit. Credits compose first in, first out in
// pages of `size`. Pure functions over values the app already reads.

// TODO(design README open item "Buy-rate window"): 24h is the suggested value, to confirm.
export const BUY_RATE_WINDOW_S = 24 * 3600;

export interface EtaInput {
  index: number; // queue position of the credit, 0 = oldest held
  held: number; // credits the engine holds (Core.pileSize)
  size: number; // credits per statement
  windowS: number; // credit sale window in seconds; 0 while the credit sale is off (ControllerV1.pastWindow)
  now: number; // chain time, unix seconds
  perHour: number | undefined; // buys per hour over BUY_RATE_WINDOW_S
  acquiredAt: (index: number) => number | undefined; // acquisition time of the credit at a queue position
}

export interface Eta {
  seconds: number;
  estimated: boolean; // true when derived from the buy rate, false when the page is full
}

// Page full: time until the newest credit of the page is past the sale window.
// Page still filling: time to buy the missing credits at the recent rate, plus the sale window.
export function composeEta(i: EtaInput): Eta | undefined {
  const k = Math.floor(i.index / i.size);
  const end = (k + 1) * i.size;
  if (end <= i.held) {
    const at = i.acquiredAt(end - 1);
    return at == null ? undefined : { seconds: Math.max(0, at + i.windowS - i.now), estimated: false };
  }
  if (!i.perHour || i.perHour <= 0) return undefined;
  return { seconds: ((end - i.held) / i.perHour) * 3600 + i.windowS, estimated: true };
}

// "~25h", "~1h 20m" (minutes under 2h), "now" at zero. "—" without an estimate.
export function etaLabel(e: Eta | undefined): string {
  if (!e) return "—";
  const m = Math.round(e.seconds / 60);
  if (m <= 0) return "now";
  const text = m < 120 ? (m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`) : `${Math.round(m / 60)}h`;
  return `~${text}`;
}

// Buys per hour, "~3" from 10 and up, one decimal below.
export function rateLabel(perHour: number): string {
  return `~${perHour >= 10 ? Math.round(perHour) : Number(perHour.toFixed(1))}`;
}

// "4 hours" for whole hours, else "3h 20m".
export function windowLabel(s: number): string {
  if (s % 3600 === 0) return `${s / 3600} hour${s === 3600 ? "" : "s"}`;
  const m = Math.round(s / 60);
  return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`;
}
