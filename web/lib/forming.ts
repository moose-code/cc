// Statements forming in the pile, before they compose. Default compose takes the `size` oldest pile credits and
// statement ids are sequential (Statements supply plus one), so page k of the pile, oldest first, is statement
// nextStatementId + k while it forms. The membership is provisional: a credit bought out of the pile shifts every later
// credit forward, and composeChosen can take credits out of order. Pure functions over values the app already reads.

import { etaLabel, type Eta } from "./compose-eta.ts";

// building: fewer than `size` credits (the last page only). upcoming: full, waiting for its newest credit to clear the
// sale window or for an earlier page to compose. ready: page 0, full and past the window (snapshot.page.ready).
export type FormingKind = "building" | "upcoming" | "ready";

export interface FormingPage {
  k: number; // page index in the pile, 0 composes next
  sid?: number; // statement id it will take, undefined until nextStatementId is read
  kind: FormingKind;
  ids: number[]; // its credits, oldest first
}

export interface PileView {
  ids: number[]; // pile credit ids read so far, oldest first (chain mode reads the first 200 only)
  pileSize: number; // Core.pileSize
  size: number; // credits per statement
  nextSid?: number; // snapshot.nextStatementId
  ready: boolean; // snapshot.page.ready: page 0 is composable now
}

// The forming state of page k. `empty`: no credit has reached it yet. `unavailable`: the pile read stops inside it.
export type FormingAt = { status: "forming"; page: FormingPage } | { status: "empty"; k: number } | { status: "unavailable"; k: number };

export function formingAt(k: number, p: PileView): FormingAt {
  const start = k * p.size;
  if (start >= p.pileSize) return { status: "empty", k };
  if (start + p.size > p.ids.length && p.ids.length < p.pileSize) return { status: "unavailable", k };
  const ids = p.ids.slice(start, start + p.size);
  const kind: FormingKind = ids.length < p.size ? "building" : k === 0 && p.ready ? "ready" : "upcoming";
  return { status: "forming", page: { k, sid: p.nextSid == null ? undefined : p.nextSid + k, kind, ids } };
}

// Every forming page in compose order, and whether the pile read stopped short of the pile (later pages unknown).
export function formingPages(p: PileView): { pages: FormingPage[]; incomplete: boolean } {
  const pages: FormingPage[] = [];
  for (let k = 0; ; k++) {
    const at = formingAt(k, p);
    if (at.status !== "forming") return { pages, incomplete: at.status === "unavailable" };
    pages.push(at.page);
  }
}

// One line on when the page composes. A full page later in the queue whose own window has passed still waits for the
// page before it.
export function formingWhen(page: FormingPage, eta: Eta | undefined, paused: boolean, size: number): string {
  if (paused) return "engine paused";
  if (page.kind === "building") return `${size - page.ids.length} more Credits`;
  if (page.kind === "ready") return "ready to compose";
  if (eta == null) return "composes next";
  if (eta.seconds <= 0) return page.k === 0 ? "ready to compose" : page.sid != null ? `after statement ${page.sid - 1}` : "after the page before";
  return `composes in ${etaLabel(eta)}`;
}
