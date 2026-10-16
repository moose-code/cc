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

// An error as one log-safe line: viem's `shortMessage` (no URL, no request body), else the message of an error this
// package throws itself (`config:`, `start:`, `keystore:` prefixes), else the error name. Any URL is cut to its host.
export function safeError(e: unknown): string {
  const x = e as { shortMessage?: unknown; message?: unknown; name?: unknown } | null;
  const own = typeof x?.message === "string" && /^(config|start|keystore):/.test(x.message) ? x.message : undefined;
  const line = String(x?.shortMessage ?? own ?? x?.name ?? "error").split("\n")[0];
  return line.replace(/https?:\/\/([^\s/?#]+)\S*/g, "$1").slice(0, 200);
}

export const txUrl = (hash: string, chainId: number) => `https://evm.now/tx/${hash}?chainId=${chainId}`;
