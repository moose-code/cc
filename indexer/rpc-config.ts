import { RpcRequestError, type Transport } from "viem";
import type { Endpoint } from "./src/lib/rpc";

/** Insert the optional fast endpoint after Tenderly without changing public budgets or reserve priority. */
export function withFastFallback(
  endpoints: Endpoint[],
  reserve: Endpoint | undefined,
  rawUrl?: string,
  rawRps?: string,
): { endpoints: Endpoint[]; reserve: Endpoint | undefined } {
  if (!rawUrl?.trim()) return { endpoints, reserve };
  let url: URL;
  try { url = new URL(rawUrl.trim()); } catch { throw new Error("RPC_FAST_FALLBACK_URL must be an HTTPS Ethereum mainnet Alchemy endpoint"); }
  if (url.protocol !== "https:" || url.hostname !== "eth-mainnet.g.alchemy.com" || url.username || url.password || (url.port && url.port !== "443")) {
    throw new Error("RPC_FAST_FALLBACK_URL must be an HTTPS Ethereum mainnet Alchemy endpoint");
  }
  const rps = rawRps === undefined ? 4 : Number(rawRps);
  if (!Number.isInteger(rps) || rps < 1 || rps > 4) throw new Error("RPC_RPS_FAST_FALLBACK must be an integer from 1 to 4");
  if (!endpoints.length) throw new Error("At least one public RPC endpoint is required");
  const fast = { url: url.href, rps };
  return {
    endpoints: [endpoints[0], fast, ...endpoints.slice(1)],
    reserve: reserve?.url === fast.url ? undefined : reserve,
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
