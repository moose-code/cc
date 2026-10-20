// Runnable check for the forming page split shared by /statements and /statements/[id]. No chain needed.
//   npm run check
import assert from "node:assert/strict";
import { formingAt, formingPages, formingWhen, type PileView } from "../lib/forming.ts";

const pile = (n: number, from = 1): number[] => Array.from({ length: n }, (_, i) => from + i);
const view = (o: Partial<PileView>): PileView => ({ ids: pile(170), pileSize: 170, size: 80, nextSid: 12, ready: false, ...o });

// promise: page k of the pile, oldest first, is statement nextStatementId + k, so a forming card links the id compose will mint
{
  const { pages, incomplete } = formingPages(view({}));
  assert.equal(incomplete, false);
  assert.deepEqual(
    pages.map((p) => [p.k, p.sid, p.kind, p.ids.length, p.ids[0]]),
    [
      [0, 12, "upcoming", 80, 1],
      [1, 13, "upcoming", 80, 81],
      [2, 14, "building", 10, 161],
    ],
  );
  const at = formingAt(1, view({}));
  assert.ok(at.status === "forming" && at.page.sid === 13 && at.page.ids[79] === 160);
}

// promise: only page 0 reads ready to compose, and only when the Core says its page is ready
{
  const p = formingPages(view({ ready: true })).pages;
  assert.equal(p[0].kind, "ready");
  assert.equal(p[1].kind, "upcoming");
  assert.equal(formingWhen(p[1], { seconds: 0, estimated: false }, false, 80), "after statement 12");
  assert.equal(formingWhen(p[0], undefined, true, 80), "engine paused");
}

// promise: an id past the last page with a credit is not forming, and a page the pile read stops inside is unavailable, never shown short
{
  assert.deepEqual(formingAt(2, view({ ids: pile(160), pileSize: 160 })), { status: "empty", k: 2 });
  assert.deepEqual(formingAt(2, view({ ids: pile(200), pileSize: 250 })), { status: "unavailable", k: 2 });
  const r = formingPages(view({ ids: pile(200), pileSize: 250 }));
  assert.equal(r.incomplete, true);
  assert.equal(r.pages.length, 2);
  // a full pile read ending on a page boundary has no building page
  assert.equal(formingPages(view({ ids: pile(160), pileSize: 160 })).pages.length, 2);
}

console.log("forming selfcheck ok");
