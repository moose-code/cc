// The read-only market view: a small HTTP server inside the keeper process that publishes the discovery catalog
// (Sources.marketView) and the prepared fulfillment of one signed order (Sources.signedOrder). GET and HEAD only;
// nothing here signs, sends, reads the keystore or exposes configuration. An optional bearer token limits readers to
// the website API. The website caches and serves the view to every visitor, so visitors never reach OpenSea or RPC.

import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { createHash, timingSafeEqual } from "node:crypto";
import type { MarketView, SignedView } from "./listings.ts";
import { log, safeError } from "./log.ts";

export const DEFAULT_LIMIT = 500;
export const MAX_LIMIT = 2000;
// one request may wait this long for its headers and its body
const REQUEST_TIMEOUT_MS = 10_000;

export interface MarketSource {
  marketView(limit: number): MarketView;
  signedOrder(hash: string): SignedView | undefined;
}

export interface Reply {
  status: number;
  body: unknown;
  headers?: Record<string, string>;
}

const HASH = /^0x[0-9a-fA-F]{64}$/;
const digest = (s: string) => createHash("sha256").update(s).digest();

// The pure request handler, for the server and its tests. `token` set requires `authorization: Bearer <token>` on
// every path but /health, which stays open and content free for the host's health check.
export function handleMarketRequest(source: MarketSource, req: { method?: string; url?: string; authorization?: string }, token?: string): Reply {
  const method = req.method ?? "GET";
  if (method !== "GET" && method !== "HEAD") return { status: 405, body: { error: "method not allowed" }, headers: { allow: "GET, HEAD" } };
  let url: URL;
  try {
    url = new URL(req.url ?? "/", "http://keeper");
  } catch {
    return { status: 400, body: { error: "bad request" } };
  }
  if (url.pathname === "/health") return { status: 200, body: { ok: true } };
  if (token) {
    const given = req.authorization?.match(/^Bearer (.+)$/)?.[1];
    if (!given || !timingSafeEqual(digest(given), digest(token))) return { status: 401, body: { error: "unauthorized" }, headers: { "www-authenticate": "Bearer" } };
  }
  if (url.pathname === "/market") {
    const raw = url.searchParams.get("limit");
    const limit = raw === null ? DEFAULT_LIMIT : /^\d{1,4}$/.test(raw) ? Number(raw) : NaN;
    if (!Number.isInteger(limit) || limit < 1 || limit > MAX_LIMIT) return { status: 400, body: { error: `limit must be 1 to ${MAX_LIMIT}` } };
    return { status: 200, body: source.marketView(limit) };
  }
  const order = url.pathname.match(/^\/market\/orders\/([^/]+)$/)?.[1];
  if (order !== undefined) {
    if (!HASH.test(order)) return { status: 400, body: { error: "bad order hash" } };
    const signed = source.signedOrder(order);
    return signed ? { status: 200, body: signed } : { status: 404, body: { error: "order not prepared" } };
  }
  return { status: 404, body: { error: "not found" } };
}

function write(res: ServerResponse, method: string | undefined, reply: Reply) {
  const body = JSON.stringify(reply.body, (_, v) => (typeof v === "bigint" ? v.toString() : v));
  res.writeHead(reply.status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    ...reply.headers,
  });
  res.end(method === "HEAD" ? undefined : body);
}

export function startMarketServer(o: { port: number; host: string; token?: string; source: MarketSource; onError?: (error: unknown) => void }): Server {
  const server = createServer({ requestTimeout: REQUEST_TIMEOUT_MS, headersTimeout: REQUEST_TIMEOUT_MS }, (req: IncomingMessage, res: ServerResponse) => {
    req.resume();
    try {
      write(res, req.method, handleMarketRequest(o.source, { method: req.method, url: req.url, authorization: req.headers.authorization }, o.token));
    } catch (error) {
      log("error", "market view request failed", { error: safeError(error) });
      if (!res.headersSent) write(res, req.method, { status: 500, body: { error: "internal" } });
      else res.destroy();
    }
  });
  server.on("error", (error) => {
    log("error", "market view server failed", { error: safeError(error) });
    o.onError?.(error);
  });
  server.listen(o.port, o.host, () => {
    const bound = server.address();
    log("info", "market view listening", { host: o.host, port: typeof bound === "object" && bound ? bound.port : o.port, token: Boolean(o.token) });
  });
  return server;
}
