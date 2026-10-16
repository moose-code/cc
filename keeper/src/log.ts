// Structured logs: one JSON object per line on stdout. bigints print as decimal strings. a transaction is logged
// with its evm.now link.

export type Fields = { [k: string]: unknown };

let sink: (line: string) => void = (l) => process.stdout.write(l + "\n");

// tests capture the lines
export function setSink(fn: (line: string) => void) {
  sink = fn;
}

export function log(level: "info" | "warn" | "error", msg: string, f: Fields = {}) {
  sink(JSON.stringify({ t: new Date().toISOString(), level, msg, ...f }, (_, v) => (typeof v === "bigint" ? v.toString() : v)));
}

export const txUrl = (hash: string, chainId: number) => `https://evm.now/tx/${hash}?chainId=${chainId}`;
