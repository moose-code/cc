// Alerts: a JSON POST to ALERT_WEBHOOK_URL, also logged at error level. A failed post is logged and
// never stops the keeper. A delivered POST starts the repeat interval; failures schedule one retry at a time.

import { log, safeError, type Fields } from "./log.ts";

const ALERT_REPEAT_SEC = 1800;
const ALERT_FAILURE_RETRY_SEC = 60;
const last = new Map<string, number>();
const scheduled = new Map<string, ReturnType<typeof setTimeout>>();
const inFlight = new Set<string>();

function retry(webhook: string, key: string, msg: string, f: Fields) {
  if (scheduled.has(key)) return;
  const timer = setTimeout(() => {
    scheduled.delete(key);
    void alert(webhook, key, msg, f);
  }, ALERT_FAILURE_RETRY_SEC * 1000);
  timer.unref();
  scheduled.set(key, timer);
}

export async function alert(webhook: string | undefined, key: string, msg: string, f: Fields = {}) {
  log("error", `alert: ${msg}`, { alert: key, ...f });
  const now = Date.now() / 1000;
  if ((last.get(key) ?? -Infinity) + ALERT_REPEAT_SEC > now) return;
  if (scheduled.has(key) || inFlight.has(key)) return;
  if (!webhook) return;
  inFlight.add(key);
  try {
    const body = JSON.stringify({ source: "cc-keeper", key, text: `cc keeper: ${msg}`, ...f }, (_, v) => (typeof v === "bigint" ? v.toString() : v));
    const r = await fetch(webhook, { method: "POST", headers: { "content-type": "application/json" }, body, signal: AbortSignal.timeout(10_000) });
    if (r.ok) {
      last.set(key, Date.now() / 1000);
    } else {
      retry(webhook, key, msg, f);
      log("warn", "alert webhook refused", { status: r.status });
    }
  } catch (e) {
    retry(webhook, key, msg, f);
    log("warn", "alert webhook failed", { error: safeError(e) });
  } finally {
    inFlight.delete(key);
  }
}
