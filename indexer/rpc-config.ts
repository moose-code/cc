import { rateLimit } from "ponder";
import { fallback, http, RpcRequestError, type Transport } from "viem";
import { fallbackTransport, guardedHttp, rpcStats, type Endpoint, type EndpointStats } from "./src/lib/rpc.ts";

type FastSelection = { endpoints: Endpoint[]; reserve: Endpoint | undefined; budget?: { maxCalls: number; until: number } };

/** Insert the optional fast endpoint after Tenderly without changing public budgets or reserve priority. */
export function withFastFallback(
  endpoints: Endpoint[],
  reserve: Endpoint | undefined,
  rawUrl?: string,
  rawRps?: string,
  rawMaxCalls?: string,
  rawUntil?: string,
): FastSelection {
  let distinctReserve = reserve;
  if (reserve) {
    let reserveHost: string;
    try { reserveHost = new URL(reserve.url).hostname; } catch { throw new Error("PONDER_RPC_URL_1 must be a valid RPC endpoint"); }
    if (reserveHost === "eth-mainnet.g.alchemy.com") distinctReserve = undefined;
  }
  if (!rawUrl?.trim()) return { endpoints, reserve: distinctReserve };
  let url: URL;
  try { url = new URL(rawUrl.trim()); } catch { throw new Error("RPC_FAST_FALLBACK_URL must be an HTTPS Ethereum mainnet Alchemy endpoint"); }
  if (url.protocol !== "https:" || url.hostname !== "eth-mainnet.g.alchemy.com" || url.username || url.password || (url.port && url.port !== "443")) {
    throw new Error("RPC_FAST_FALLBACK_URL must be an HTTPS Ethereum mainnet Alchemy endpoint");
  }
  const rps = rawRps === undefined ? 4 : Number(rawRps);
  if (!Number.isInteger(rps) || rps < 1 || rps > 8) throw new Error("RPC_RPS_FAST_FALLBACK must be an integer from 1 to 8");
  if (!endpoints.length) throw new Error("At least one public RPC endpoint is required");
  const fast = { url: url.href, rps };
  const maxCalls = /^\d+$/.test(rawMaxCalls ?? "") ? Number(rawMaxCalls) : NaN;
  const until = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{3})?Z$/.test(rawUntil ?? "") ? Date.parse(rawUntil!) : NaN;
  // A fixed expiry bounds restarts too; an absent or invalid spending envelope must never enable paid RPC.
  if (!Number.isInteger(maxCalls) || maxCalls < 1 || maxCalls > 10_000 || !Number.isFinite(until) || until <= Date.now() || until > Date.now() + 25 * 60_000) {
    return { endpoints, reserve: distinctReserve };
  }
  return {
    endpoints: [endpoints[0], fast, ...endpoints.slice(1)],
    reserve: distinctReserve,
    budget: { maxCalls, until },
  };
}

/** Keep rate-limit metadata until it has set the primary backoff; the general guard intentionally removes that metadata. */
function primaryRpc(endpoint: Endpoint, stats: EndpointStats, backoff: () => void): Transport {
  const inner = http(endpoint.url, { timeout: 20_000, retryCount: 0, onFetchResponse(response) { if (response.status === 429) backoff(); } });
  return (params) => {
    const transport = inner(params);
    return { ...transport, request: (async (args: Parameters<typeof transport.request>[0]) => {
      stats.queued = Math.max(0, stats.queued - 1);
      stats.requests++; stats.active++; stats.lastStarted = Date.now();
      const controller = new AbortController();
      let timer: ReturnType<typeof setTimeout> | undefined;
      try {
        const result = await Promise.race([
          transport.request(args, { signal: controller.signal }),
          new Promise<never>((_, reject) => { timer = setTimeout(() => { reject(new Error("request deadline exceeded (20000 ms)")); controller.abort(); }, 20_000); }),
        ]);
        if (args.method === "eth_getLogs" && (!Array.isArray(result) || result.some(log => !log || log.blockNumber == null || log.blockHash == null))) throw new Error("malformed eth_getLogs");
        return result;
      } catch (error) {
        const message = String((error as Error).message ?? error);
        if (/execution reverted|revert/i.test(message)) throw error;
        let cause = error as { code?: number; status?: number; cause?: unknown } | undefined;
        let limited = false;
        for (let i = 0; cause && i < 8; i++, cause = cause.cause as typeof cause) limited ||= cause.code === 429 || cause.status === 429;
        if (limited) backoff();
        const safe = message.replace(/https?:\/\/\S+/g, "[upstream]").split("\n")[0];
        stats.errors++; stats.lastError = `${args.method}: ${safe}`;
        console.warn(`[rpc] ${new URL(endpoint.url).host} failed ${args.method}: ${safe}`);
        throw new Error(`${new URL(endpoint.url).host}: ${safe}`);
      } finally { clearTimeout(timer); stats.active--; stats.lastSettled = Date.now(); }
    }) as typeof transport.request };
  };
}

/** Spending gates run inside the physical limiter, including requests queued before expiry or a limit response. */
export function temporaryFallbackTransport(selected: FastSelection): Transport {
  if (!selected.budget) return fallbackTransport(selected.endpoints, selected.reserve);
  const [primary, fast, ...publics] = selected.endpoints;
  let shared: ReturnType<Transport> | undefined;
  let used = 0;
  let primaryUntil = 0;
  return (params) => {
    if (shared) return shared;
    const limited = (endpoint: Endpoint, paid: boolean): Transport => {
      const host = new URL(endpoint.url).host;
      const stats = rpcStats().get(host) ?? { requests: 0, errors: 0, lastError: null, rps: endpoint.rps, queued: 0, active: 0, lastStarted: null, lastSettled: null };
      stats.rps = endpoint.rps;
      rpcStats().set(host, stats);
      const blocked = () => paid ? Date.now() >= selected.budget!.until || used >= selected.budget!.maxCalls : Date.now() < primaryUntil;
      const unavailable = () => new Error(paid ? "Temporary RPC spending envelope exhausted" : "Primary RPC rate-limit backoff");
      const http = (paid ? guardedHttp(endpoint.url, endpoint.rps) : primaryRpc(endpoint, stats, () => { primaryUntil = Date.now() + 30_000; }))(params);
      const gated: Transport = () => ({
        ...http,
        request: (async (...args: Parameters<typeof http.request>) => {
          if (blocked()) {
            stats.queued = Math.max(0, stats.queued - 1);
            throw unavailable();
          }
          if (paid) used++;
          return http.request(...args);
        }) as typeof http.request,
      });
      const transport = rateLimit(gated, { requestsPerSecond: endpoint.rps, browser: false })({ ...params, retryCount: 0 });
      return () => ({
        ...transport,
        request: (async (...args: Parameters<typeof transport.request>) => { if (blocked()) throw unavailable(); stats.queued++; return transport.request(...args); }) as typeof transport.request,
      });
    };
    const tiers = [limited(primary, false), limited(fast, true)];
    if (publics.length) tiers.push(fallbackTransport(publics, selected.reserve));
    else if (selected.reserve) tiers.push(fallbackTransport([selected.reserve]));
    return (shared = fallback(tiers, { rank: false, retryCount: 0, shouldThrow: (error) => /execution reverted|revert/i.test(error.message) })({ ...params, retryCount: 0 }));
  };
}

/** Provider errors can carry a full credential URL in metadata/cause. Never let that object reach Ponder's logger. */
export function sanitizedRpc(transport: Transport): Transport {
  return (params) => {
    const t = transport(params);
    return {
      ...t,
      request: (async (...args: Parameters<typeof t.request>) => {
        try { return await t.request(...args); }
        catch (caught) {
          const error = caught as Error & { code?: number; data?: unknown; details?: string; shortMessage?: string };
          const message = (error.details || error.shortMessage || error.message || "RPC request failed")
            .replace(/https?:\/\/\S+/g, "[upstream]").slice(0, 1000);
          throw new RpcRequestError({
            body: args[0],
            url: "[upstream]",
            error: {
              code: typeof error.code === "number" ? error.code : -1,
              message,
              ...(typeof error.data === "string" && /^0x[\da-f]*$/i.test(error.data) ? { data: error.data } : {}),
            },
          });
        }
      }) as typeof t.request,
    };
  };
}
