// Alerts: a JSON POST to ALERT_WEBHOOK_URL, also logged at error level. a failed post is logged and
// never stops the keeper. one alert per key per ALERT_REPEAT_SEC.

import { log, safeError, type Fields } from "./log.ts";

const ALERT_REPEAT_SEC = 1800;
const last = new Map<string, number>();

export async function alert(webhook: string | undefined, key: string, msg: string, f: Fields = {}) {
  log("error", `alert: ${msg}`, { alert: key, ...f });
  const now = Date.now() / 1000;
  if ((last.get(key) ?? -Infinity) + ALERT_REPEAT_SEC > now) return;
  last.set(key, now);
  if (!webhook) return;
  try {
    const body = JSON.stringify({ source: "cc-keeper", key, text: `cc keeper: ${msg}`, ...f }, (_, v) => (typeof v === "bigint" ? v.toString() : v));
    const r = await fetch(webhook, { method: "POST", headers: { "content-type": "application/json" }, body, signal: AbortSignal.timeout(10_000) });
    if (!r.ok) log("warn", "alert webhook refused", { status: r.status });
  } catch (e) {
    log("warn", "alert webhook failed", { error: safeError(e) });
  }
}
