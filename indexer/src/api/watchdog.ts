// Lives in src/api: Ponder hashes every other file under src into the build id, and a changed build id refuses the deployed schema.
// Stall watchdog. Ponder's /health answers 200 while the process is up, even when indexing is stuck on a request that
// never settles (2026-10-22: frozen for hours at 80.9 percent with CPU, database and RPC idle; a restart finished it in
// two minutes). Every minute the process reads its own /metrics; when none of the progress counters below moved for
// STALL_SECONDS it exits 1 and the Fly restart policy starts it again, resuming from Ponder's checkpoint.
// Live indexing moves ponder_sync_block every block and a backfill moves the others, so a healthy indexer never trips it.

const PROGRESS = [
  "ponder_sync_block",
  "ponder_historical_completed_blocks",
  "ponder_indexing_timestamp",
  "ponder_indexing_completed_events",
  "ponder_indexing_rpc_requests_total",
];

/** The progress counters of a Prometheus text body, summed per name over their labels, as one comparable string. */
export function progressFingerprint(metrics: string): string {
  const sums = new Map<string, number>();
  for (const line of metrics.split("\n")) {
    const m = /^([a-z_]+)(?:\{[^}]*\})? (\S+)$/.exec(line);
    if (m && PROGRESS.includes(m[1]!)) sums.set(m[1]!, (sums.get(m[1]!) ?? 0) + Number(m[2]));
  }
  return PROGRESS.map((k) => `${k}=${sums.get(k) ?? ""}`).join(" ");
}

/** True when the fingerprint has not changed for longer than stallMs. A failed read counts as no change. */
export function stalled(seen: { print: string; since: number }, print: string | undefined, now: number, stallMs: number) {
  if (print !== undefined && print !== seen.print) {
    seen.print = print;
    seen.since = now;
  }
  return now - seen.since > stallMs;
}

export function startWatchdog(port = process.env.PORT ?? "42069", stallSeconds = Number(process.env.STALL_SECONDS ?? 600)) {
  if (!(stallSeconds > 0)) return;
  const seen = { print: "", since: Date.now() };
  const timer = setInterval(async () => {
    const print = await fetch(`http://127.0.0.1:${port}/metrics`, { signal: AbortSignal.timeout(10_000) })
      .then((r) => (r.ok ? r.text() : undefined))
      .then((t) => (t === undefined ? undefined : progressFingerprint(t)))
      .catch(() => undefined);
    if (stalled(seen, print, Date.now(), stallSeconds * 1000)) {
      console.error(`watchdog: no indexing progress for ${stallSeconds}s (${seen.print}); exiting for a restart`);
      process.exit(1);
    }
  }, 60_000);
  timer.unref();
}
