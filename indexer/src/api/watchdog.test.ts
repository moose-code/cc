import assert from "node:assert/strict";
import { test } from "node:test";
import { progressFingerprint, stalled } from "./watchdog.ts";

const body = (events: number, sync: number) => `# HELP x
ponder_sync_block{chain="chain"} ${sync}
ponder_indexing_completed_events{event="Credits:Transfer"} ${events}
ponder_indexing_completed_events{event="Core:Buyback"} 1
ponder_indexing_completed_events_bucket{le="1"} 99
ponder_database_method_duration_count{method="select_ready"} 7`;

// promise: only progress counters count; unrelated metrics (health polling) never look like progress.
test("fingerprint sums progress counters and ignores the rest", () => {
  assert.equal(progressFingerprint(body(5, 10)), progressFingerprint(body(5, 10).replace("select_ready\"} 7", "select_ready\"} 8")));
  assert.notEqual(progressFingerprint(body(5, 10)), progressFingerprint(body(6, 10)));
  assert.notEqual(progressFingerprint(body(5, 10)), progressFingerprint(body(5, 11)));
  assert.match(progressFingerprint(body(5, 10)), /ponder_indexing_completed_events=6/);
});

// promise: the watchdog trips only after a full stall window with no change, and failed reads never reset it.
test("stalled after the window without change, reset by any change", () => {
  const seen = { print: "", since: 0 };
  assert.equal(stalled(seen, "a", 0, 600), false);
  assert.equal(stalled(seen, "a", 600, 600), false);
  assert.equal(stalled(seen, undefined, 601, 600), true);
  assert.equal(stalled(seen, "b", 700, 600), false);
  assert.equal(stalled(seen, "b", 1301, 600), true);
});
