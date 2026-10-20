// The shape of /api/listings (app/api/listings/route.ts): the keeper's market view as the website serves it, and the
// field by field check of the keeper's answer. Shared by the route, its test and the browser types; no React here.

export const VIEW_LIMIT = 1000; // asks served per view; the keeper caps at 2000 and states the catalog total

export interface ViewRow { id: string; price: string; hash: string; endTime: number; score: string | null; signed: boolean }
export interface ViewStatus {
  source: "api" | "file" | "off";
  complete: boolean;
  lastFullAt: number;
  publishedAt: number;
  streamJoined: boolean;
  gap: boolean;
  queuedUpdates: number;
  queuedRemovals: number;
  retryAt: number | null;
  lastFailure: { at: number; error: string } | null;
}
export interface View {
  builtAt: number;
  status: ViewStatus;
  catalog: { total: number; scored: number; signed: number; limit: number };
  rows: ViewRow[];
}

/** The route's answer: the keeper view when one was ever read, with the website's own freshness fields. */
export interface Out {
  /** false while the view is unconfigured, has never answered, or belongs to another chain, Core or adapter */
  available: boolean;
  reason?: "unconfigured" | "unreachable" | "identity";
  /** when the served view was fetched from the keeper */
  fetchedAt?: number;
  /** the served view is older than the cache window because the last reads failed */
  stale: boolean;
  /** the last upstream failure, if any, after the served view was fetched */
  error?: string;
  view?: View;
}
export interface Fulfill {
  id?: string;
  price?: string;
  params?: `0x${string}`;
  /** why the order cannot be served */
  skipped?: string;
}

export const HASH = /^0x[0-9a-fA-F]{64}$/;
export const DIGITS = /^(0|[1-9]\d{0,77})$/;
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const lc = (a: string) => a.toLowerCase();

export const object = (x: unknown): x is Record<string, unknown> => x !== null && typeof x === "object" && !Array.isArray(x);
const int = (x: unknown): x is number => typeof x === "number" && Number.isSafeInteger(x) && x >= 0;

// The keeper's answer, checked field by field: a malformed or foreign view is refused, not served.
export function parseView(body: unknown): { view: View; identity: { chainId: number; core: string; seaportAdapter: string } } {
  if (!object(body) || !object(body.status) || !object(body.catalog) || !Array.isArray(body.rows)) throw new Error("malformed view");
  if (!int(body.chainId) || typeof body.core !== "string" || !ADDRESS.test(body.core) || typeof body.seaportAdapter !== "string" || !ADDRESS.test(body.seaportAdapter)) throw new Error("malformed view identity");
  const s = body.status;
  const c = body.catalog;
  if (!["api", "file", "off"].includes(String(s.source)) || typeof s.complete !== "boolean" || !int(s.lastFullAt) || !int(s.publishedAt) || typeof s.streamJoined !== "boolean" || typeof s.gap !== "boolean" || !int(s.queuedUpdates) || !int(s.queuedRemovals) || !(s.retryAt === null || int(s.retryAt)) || !(s.lastFailure === null || (object(s.lastFailure) && int(s.lastFailure.at) && typeof s.lastFailure.error === "string"))) throw new Error("malformed view status");
  if (!int(c.total) || !int(c.scored) || !int(c.signed) || !int(c.limit) || body.rows.length > (c.limit as number) || body.rows.length > 2000 || !int(body.builtAt)) throw new Error("malformed view catalog");
  const rows: ViewRow[] = body.rows.map((r: unknown) => {
    if (!object(r) || typeof r.id !== "string" || !DIGITS.test(r.id) || typeof r.price !== "string" || !DIGITS.test(r.price) || typeof r.hash !== "string" || !HASH.test(r.hash) || !int(r.endTime) || !(r.score === null || (typeof r.score === "string" && DIGITS.test(r.score))) || typeof r.signed !== "boolean") throw new Error("malformed view row");
    return { id: r.id, price: r.price, hash: lc(r.hash), endTime: r.endTime as number, score: r.score as string | null, signed: r.signed };
  });
  const failure = s.lastFailure as { at: number; error: string } | null;
  return {
    view: {
      builtAt: body.builtAt as number,
      status: { source: s.source as ViewStatus["source"], complete: s.complete, lastFullAt: s.lastFullAt as number, publishedAt: s.publishedAt as number, streamJoined: s.streamJoined, gap: s.gap, queuedUpdates: s.queuedUpdates as number, queuedRemovals: s.queuedRemovals as number, retryAt: s.retryAt as number | null, lastFailure: failure && { at: failure.at, error: failure.error.slice(0, 200) } },
      catalog: { total: c.total as number, scored: c.scored as number, signed: c.signed as number, limit: c.limit as number },
      rows,
    },
    identity: { chainId: body.chainId as number, core: body.core, seaportAdapter: body.seaportAdapter },
  };
}

