import { rateLimit } from "ponder";
import { fallback, http, type Transport } from "viem";

export type EndpointStats = {
  requests: number; errors: number; lastError: string | null; rps: number | null;
  queued: number; active: number; lastStarted: number | null; lastSettled: number | null;
};

const KEY = "__ccRpcStats";
type G = typeof globalThis & { [KEY]?: Map<string, EndpointStats> };

/** Per-endpoint counters, shared between the config module and the API module through globalThis. */
export function rpcStats(): Map<string, EndpointStats> {
  const g = globalThis as G;
  return (g[KEY] ??= new Map());
}

function entry(host: string, rps: number | null): EndpointStats {
  const m = rpcStats();
  let e = m.get(host);
  if (!e) m.set(host, (e = { requests: 0, errors: 0, lastError: null, rps, queued: 0, active: 0, lastStarted: null, lastSettled: null }));
  return e;
}

// Messages of a call that reverted. They are deterministic, so the error is rethrown unchanged and viem
// does not try the next endpoint.
const REVERT = /execution reverted|revert/i;

/**
 * http transport with three additions.
 * 1. A malformed eth_getLogs result (not an array, or a log without blockNumber or blockHash) throws, so the
 *    fallback transport moves to the next endpoint.
 * 2. Every error except a revert is rethrown as a plain Error without an rpc code. That covers pruned-state
 *    errors (missing trie node, header not found, invalid params for an old block), so a historical call falls
 *    through to an endpoint that serves archive state.
 * 3. Requests and errors are counted per host and each failure is logged.
 */
export function guardedHttp(url: string, rps: number | null = null, timeoutMs = 20_000): Transport {
  const host = new URL(url).host;
  const inner = http(url, { timeout: timeoutMs, retryCount: 0 });
  return (params) => {
    const t = inner(params);
    return {
      ...t,
      request: (async (args: { method?: string }) => {
        const stats = entry(host, rps);
        stats.queued = Math.max(0, stats.queued - 1);
        stats.requests++;
        stats.active++;
        stats.lastStarted = Date.now();
        const controller = new AbortController();
        let timer: ReturnType<typeof setTimeout> | undefined;
        let res: unknown;
        try {
          // Reject independently of abort handling so an uncooperative request cannot hold a limiter slot.
          res = await Promise.race([
            t.request(args as Parameters<typeof t.request>[0], { signal: controller.signal }),
            new Promise<never>((_, reject) => {
              timer = setTimeout(() => {
                reject(new Error(`request deadline exceeded (${timeoutMs} ms)`));
                controller.abort();
              }, timeoutMs);
            }),
          ]);
        } catch (e) {
          const full = `${(e as Error).message ?? e} ${(e as { details?: string }).details ?? ""}`;
          if (REVERT.test(full)) throw e;
          const msg = full.split("\n")[0];
          stats.errors++;
          stats.lastError = `${args?.method}: ${msg}`;
          console.warn(`[rpc] ${host} failed ${args?.method}: ${msg}`);
          throw new Error(`${host}: ${msg}`);
        } finally {
          clearTimeout(timer);
          stats.active--;
          stats.lastSettled = Date.now();
        }
        if (args?.method === "eth_getLogs") {
          const bad = !Array.isArray(res)
            ? "result not an array"
            : (res as Array<{ blockNumber?: unknown; blockHash?: unknown } | null>).some(
                  (l) => !l || l.blockNumber == null || l.blockHash == null,
                )
              ? "log missing blockNumber or blockHash"
              : null;
          if (bad) {
            stats.errors++;
            stats.lastError = `eth_getLogs: ${bad}`;
            console.warn(`[rpc] ${host} malformed eth_getLogs: ${bad}`);
            throw new Error(`malformed eth_getLogs from ${host}: ${bad}`);
          }
        }
        return res;
      }) as typeof t.request,
    };
  };
}

export type Endpoint = { url: string; rps: number };

/** Ordered public fallback; every request starts at the first endpoint and the optional reserve is last. */
export function fallbackTransport(endpoints: Endpoint[], reserve?: Endpoint, timeoutMs = 20_000): Transport {
  if (endpoints.length === 0) throw new Error("At least one public RPC endpoint is required");
  let shared: ReturnType<Transport> | undefined;
  return (params) => {
    if (shared) return shared;
    // Constructors and fallback requests share one concrete limiter per endpoint.
    const limited = [...endpoints, ...(reserve ? [reserve] : [])].map((e): Transport => {
      const stats = entry(new URL(e.url).host, e.rps);
      const transport = rateLimit(guardedHttp(e.url, e.rps, timeoutMs), { requestsPerSecond: e.rps, browser: false })({ ...params, retryCount: 0 });
      const observed = {
        ...transport,
        request: ((...args: Parameters<typeof transport.request>) => {
          stats.queued++;
          return transport.request(...args);
        }) as typeof transport.request,
      };
      return () => observed;
    });
    return (shared = fallback(limited, {
      rank: false,
      retryCount: 0,
      shouldThrow: (error) => REVERT.test(`${error.message} ${(error as { details?: string }).details ?? ""}`),
    })({ ...params, retryCount: 0 }));
  };
}
