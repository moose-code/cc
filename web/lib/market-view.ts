// The keeper's market view as the browser reads it: one shared poll of /api/listings (the website API's cached copy
// of the keeper's read-only view, docs/INDEXER.md section 9.1), typed, with the status lines the pages show. Every
// consumer (the listings page, the feed tab, the header summary) shares this query, so an open page adds no upstream
// request. Advisory: a bid, holder, order status and the buyListing simulation are read live before any purchase.

import { keepPreviousData, useQuery, type QueryClient } from "@tanstack/react-query";
import type { Out } from "./listings-api";
import { engineDeployed } from "./config";
import { agoLabel } from "./format";

export type { Out as MarketOut, View as MarketViewData, ViewRow as MarketRow, ViewStatus as MarketStatus } from "./listings-api";

export const MARKET_VIEW_KEY = ["market-view"] as const;
export const VIEW_POLL_MS = 10_000; // the browser poll; the API shares one keeper read per 5 s window per instance
const VIEW_FRESH_MS = 5_000;
// a view fetched longer ago than this is stale on the page whatever the API said (a stalled poll, a hidden tab)
export const VIEW_STALE_MS = 60_000;

export async function fetchMarketView(): Promise<Out> {
  const r = await fetch("/api/listings", { cache: "no-store" });
  if (!r.ok) throw new Error(`listings api ${r.status}`);
  return r.json();
}

const options = { queryKey: MARKET_VIEW_KEY, queryFn: fetchMarketView, staleTime: VIEW_FRESH_MS } as const;

export function useMarketView() {
  return useQuery<Out>({ ...options, enabled: engineDeployed, refetchInterval: VIEW_POLL_MS, retry: 1, placeholderData: keepPreviousData });
}

/** The view for a query function: the hook's fresh copy when it has one, else one shared fetch. */
export const readMarketView = (qc: QueryClient) => qc.fetchQuery<Out>(options);

/** Whether the served view may be called current: fetched recently, from a joined stream without a gap or backoff. */
export function viewLive(out: Out | undefined, now: number): boolean {
  if (!out?.available || !out.view || out.stale || out.fetchedAt == null || now - out.fetchedAt > VIEW_STALE_MS) return false;
  const s = out.view.status;
  return s.complete && s.streamJoined && !s.gap && (s.retryAt == null || s.retryAt <= now);
}

/** The status lines of the listings surfaces, plainly: coverage, update time, stream and failure state. */
export function viewLines(out: Out | undefined, now: number): string[] {
  if (!out) return [];
  if (!out.available || !out.view) {
    if (out.reason === "unconfigured") return ["OpenSea listings are not configured on this site; CreditStrategy listings only."];
    if (out.reason === "identity") return ["OpenSea listings unavailable: the keeper's view belongs to another engine."];
    return [`OpenSea listings unavailable: keeper unreachable${out.error ? ` (${out.error})` : ""}.`];
  }
  const v = out.view;
  const s = v.status;
  const ago = (t: number) => agoLabel(Math.max(0, (now - t) / 1000));
  const lines: string[] = [];
  lines.push(
    `OpenSea: ${v.catalog.total.toLocaleString()} compatible asks ranked by ETH per point` +
      (v.rows.length < v.catalog.total ? `, showing the best ${v.rows.length.toLocaleString()}` : "") +
      (v.catalog.scored < v.catalog.total ? `, ${(v.catalog.total - v.catalog.scored).toLocaleString()} unscored` : "") +
      ".",
  );
  const fetchedAgo = out.fetchedAt != null ? ago(out.fetchedAt) : "unknown";
  if (out.stale || (out.fetchedAt != null && now - out.fetchedAt > VIEW_STALE_MS)) lines.push(`stale: showing the view read ${fetchedAgo}${out.error ? ` (${out.error})` : ""}.`);
  else lines.push(`view read ${fetchedAgo}; keeper last applied a change ${s.publishedAt ? ago(s.publishedAt) : "never"}.`);
  const stream = !s.complete ? "catalog incomplete" : !s.streamJoined ? "stream disconnected, updates delayed" : s.gap ? "stream gap, reconciling" : "stream live";
  lines.push(`${stream}; catalog reconciled ${s.lastFullAt ? ago(s.lastFullAt) : "never"}${s.queuedUpdates + s.queuedRemovals ? `, ${s.queuedUpdates + s.queuedRemovals} changes queued` : ""}.`);
  if (s.retryAt != null && s.retryAt > now) lines.push(`OpenSea backing off for ${Math.ceil((s.retryAt - now) / 1000)}s.`);
  if (s.lastFailure && (!s.publishedAt || s.lastFailure.at > s.publishedAt)) lines.push(`last discovery failure ${ago(s.lastFailure.at)}: ${s.lastFailure.error}.`);
  return lines;
}
