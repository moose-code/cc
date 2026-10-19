// Server-only dispatcher. Limits apply to one warm server instance; replicas have independent budgets.
type Params = readonly unknown[];
type RpcError = { code: number; message: string; data?: string };
type Reply = { jsonrpc: "2.0"; id: string | number | null; result?: unknown; error?: RpcError };

export class RpcProxyError extends Error {
  code: number;
  status: number;
  data?: string;
  id?: Reply["id"];
  constructor(message: string, code = -32600, status = 400, data?: string) {
    super(message); this.code = code; this.status = status; this.data = data;
  }
}

const TENDERLY = "https://gateway.tenderly.co/public/mainnet";
const MAX_RESPONSE = 10 * 1024 * 1024;
const MAX_CACHE_BYTES = 32 * 1024 * 1024;
function upstreams() {
  let primary = TENDERLY;
  try {
    const candidate = new URL(process.env.RPC_URL ?? TENDERLY);
    if (candidate.protocol === "https:" && (candidate.hostname === "tenderly.co" || candidate.hostname.endsWith(".tenderly.co"))) primary = candidate.href;
  } catch { /* An invalid override falls back to the public Tenderly endpoint. */ }
  return [primary, "https://eth-mainnet.public.blastapi.io", "https://rpc.mevblocker.io"];
}

const COUNTS: Record<string, readonly [number, number]> = {
  eth_chainId: [0, 0], eth_blockNumber: [0, 0], eth_call: [1, 2], eth_estimateGas: [1, 2],
  eth_getBalance: [1, 2], eth_getCode: [1, 2], eth_getStorageAt: [2, 3], eth_getLogs: [1, 1],
  eth_getBlockByNumber: [2, 2], eth_getTransactionByHash: [1, 1], eth_getTransactionReceipt: [1, 1],
};
const hex = (x: unknown) => typeof x === "string" && /^0x[0-9a-fA-F]*$/.test(x);
const address = (x: unknown) => typeof x === "string" && /^0x[0-9a-fA-F]{40}$/.test(x);
const hash = (x: unknown) => typeof x === "string" && /^0x[0-9a-fA-F]{64}$/.test(x);
const block = (x: unknown) => typeof x === "string" && (/^0x[0-9a-fA-F]+$/.test(x) || ["latest", "pending", "earliest", "safe", "finalized"].includes(x));
const object = (x: unknown): x is Record<string, unknown> => x !== null && typeof x === "object" && !Array.isArray(x);

function validate(method: unknown, params: unknown): asserts params is Params {
  if (typeof method !== "string" || !Object.hasOwn(COUNTS, method)) throw new RpcProxyError("RPC method is not allowed", -32601);
  const [min, max] = COUNTS[method];
  if (!Array.isArray(params) || params.length < min || params.length > max) throw new RpcProxyError("Invalid RPC parameters", -32602);
  let valid = true;
  if (method === "eth_call" || method === "eth_estimateGas") {
    valid = object(params[0]) && ["to", "from"].every((k) => params[0][k] === undefined || address(params[0][k])) &&
      ["data", "input", "value", "gas", "gasPrice", "maxFeePerGas", "maxPriorityFeePerGas"].every((k) => params[0][k] === undefined || hex(params[0][k])) &&
      (params[1] === undefined || block(params[1]));
  } else if (["eth_getBalance", "eth_getCode", "eth_getStorageAt"].includes(method)) {
    valid = address(params[0]) && (method !== "eth_getStorageAt" || hex(params[1]));
    const tag = params[method === "eth_getStorageAt" ? 2 : 1];
    valid &&= tag === undefined || block(tag);
  } else if (method === "eth_getBlockByNumber") valid = block(params[0]) && typeof params[1] === "boolean";
  else if (method === "eth_getTransactionByHash" || method === "eth_getTransactionReceipt") valid = hash(params[0]);
  else if (method === "eth_getLogs") {
    const filter = params[0];
    valid = object(filter);
    if (valid && object(filter)) {
      if (filter.blockHash !== undefined) valid = hash(filter.blockHash) && filter.fromBlock === undefined && filter.toBlock === undefined;
      else if (typeof filter.fromBlock === "string" && /^0x[\da-f]+$/i.test(filter.fromBlock) && typeof filter.toBlock === "string" && /^0x[\da-f]+$/i.test(filter.toBlock)) {
        const span = BigInt(filter.toBlock) - BigInt(filter.fromBlock);
        valid = span >= 0n && span < 5_000n;
      } else valid = filter.fromBlock === "latest" && filter.toBlock === "latest";
      valid &&= filter.address === undefined || address(filter.address) || (Array.isArray(filter.address) && filter.address.length <= 20 && filter.address.every(address));
      valid &&= filter.topics === undefined || (Array.isArray(filter.topics) && filter.topics.length <= 4 && filter.topics.every((t) => t === null || hash(t) || (Array.isArray(t) && t.length <= 32 && t.every(hash))));
    }
  }
  if (!valid) throw new RpcProxyError("Invalid or unbounded RPC parameters", -32602);
}

function ttl(method: string, params: Params, result: unknown) {
  if (method === "eth_estimateGas" || JSON.stringify(params).includes('"pending"')) return 0;
  if (result === null || (method === "eth_getCode" && result === "0x")) return 1_000;
  if (method === "eth_blockNumber") return 2_000;
  if (method === "eth_chainId") return 60_000;
  const tag = method === "eth_getStorageAt" ? params[2] : method === "eth_getBlockByNumber" ? params[0] : params[1];
  const historicalLogs = method === "eth_getLogs" && object(params[0]) && (params[0].blockHash !== undefined || /^0x[\da-f]+$/i.test(String(params[0].toBlock)));
  return historicalLogs || (typeof tag === "string" && /^0x[\da-f]+$/i.test(tag)) ? 60_000 : 3_000;
}

export function createRpcDispatcher(options: { fetchFn?: typeof fetch; urls?: string[]; intervalMs?: number; timeoutMs?: number; requestTimeoutMs?: number; maxQueue?: number } = {}) {
  const fetchFn = options.fetchFn ?? fetch;
  const urls = options.urls ?? upstreams();
  const interval = options.intervalMs ?? 250;
  const timeout = options.timeoutMs ?? 10_000;
  const queue: { run: () => Promise<unknown>; resolve: (value: unknown) => void; reject: (reason: unknown) => void }[] = [];
  const cache = new Map<string, { expires: number; result: unknown; bytes: number }>();
  const flights = new Map<string, Promise<unknown>>();
  let active = 0;
  let nextAt = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let cacheBytes = 0;
  const deadlineError = () => new RpcProxyError("RPC request deadline exceeded", -32002, 504);
  function evict(key: string) { cacheBytes -= cache.get(key)?.bytes ?? 0; cache.delete(key); }

  function pump() {
    if (active >= 2 || !queue.length) return;
    const delay = nextAt - Date.now();
    if (delay > 0) {
      timer ??= setTimeout(() => { timer = undefined; pump(); }, delay);
      return;
    }
    const job = queue.shift()!;
    active++;
    nextAt = Date.now() + interval;
    job.run().then(job.resolve, job.reject).finally(() => { active--; pump(); });
    pump();
  }
  function schedule(run: () => Promise<unknown>, signal: AbortSignal) {
    if (queue.length >= (options.maxQueue ?? 64)) return Promise.reject(new RpcProxyError("RPC queue is full; retry shortly", -32005, 429));
    return new Promise<unknown>((resolve, reject) => {
      const cleanup = () => signal.removeEventListener("abort", abort);
      const job = { run, resolve: (value: unknown) => { cleanup(); resolve(value); }, reject: (error: unknown) => { cleanup(); reject(error); } };
      const abort = () => {
        const index = queue.indexOf(job);
        if (index >= 0) queue.splice(index, 1);
        job.reject(deadlineError());
      };
      signal.addEventListener("abort", abort, { once: true });
      if (signal.aborted) { abort(); return; }
      queue.push(job); pump();
    });
  }
  async function attempt(url: string, method: string, params: Params, signal: AbortSignal) {
    const controller = new AbortController();
    let deadline: ReturnType<typeof setTimeout> | undefined;
    let abort!: () => void;
    const cancelled = new Promise<never>((_, reject) => {
      abort = () => { reject(deadlineError()); controller.abort(); };
      signal.addEventListener("abort", abort, { once: true });
      if (signal.aborted) abort();
    });
    try {
      return await Promise.race([
        (async () => {
          const response = await fetchFn(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }), signal: controller.signal, cache: "no-store" });
          if (!response.ok) throw new Error("Unavailable");
          if (Number(response.headers.get("content-length")) > MAX_RESPONSE) throw new Error("Oversized response");
          const reader = response.body?.getReader();
          if (!reader) throw new Error("Missing response");
          const decoder = new TextDecoder();
          let text = "", size = 0;
          while (true) {
            const chunk = await reader.read();
            if (chunk.done) break;
            size += chunk.value.byteLength;
            if (size > MAX_RESPONSE) { void reader.cancel().catch(() => {}); throw new Error("Oversized response"); }
            text += decoder.decode(chunk.value, { stream: true });
          }
          const body = JSON.parse(text + decoder.decode());
          if (!object(body) || body.jsonrpc !== "2.0" || body.id !== 1 || (Object.hasOwn(body, "result") === Object.hasOwn(body, "error"))) throw new Error("Malformed response");
          if (body.error !== undefined) {
            const error = body.error;
            if (!object(error) || !Number.isInteger(error.code) || typeof error.message !== "string") throw new Error("Malformed error");
            if (!/revert/i.test(error.message) && /missing trie|header not found|historical.*not available|resource not found|rate.?limit|unavailable|timeout|archive/i.test(error.message)) throw new Error("Unavailable state");
            throw new RpcProxyError(error.message.replace(/https?:\/\/\S+/g, "[upstream]").slice(0, 300), Number(error.code), 200, hex(error.data) ? String(error.data) : undefined);
          }
          if (method === "eth_getLogs" && (!Array.isArray(body.result) || body.result.some((log) => !object(log) || log.blockNumber == null || log.blockHash == null))) throw new Error("Malformed logs");
          return body.result;
        })(),
        new Promise<never>((_, reject) => { deadline = setTimeout(() => { reject(new Error("Deadline")); controller.abort(); }, timeout); }),
        cancelled,
      ]);
    } finally { clearTimeout(deadline); signal.removeEventListener("abort", abort); controller.abort(); }
  }
  async function request(method: string, params: Params = []): Promise<unknown> {
    validate(method, params);
    const key = JSON.stringify([method, params]);
    const cached = cache.get(key);
    if (cached && cached.expires > Date.now()) return cached.result;
    evict(key);
    if (flights.has(key)) return flights.get(key)!;
    if (flights.size >= 512) throw new RpcProxyError("RPC queue is full; retry shortly", -32005, 429);
    const controller = new AbortController();
    const deadline = setTimeout(() => controller.abort(), options.requestTimeoutMs ?? 20_000);
    const work = (async () => {
      for (const url of urls) {
        try {
          const result = await schedule(() => attempt(url, method, params, controller.signal), controller.signal);
          const duration = ttl(method, params, result);
          if (duration) {
            const bytes = new TextEncoder().encode(key).byteLength + new TextEncoder().encode(JSON.stringify(result)).byteLength;
            if (bytes <= MAX_CACHE_BYTES) {
              evict(key);
              cache.set(key, { expires: Date.now() + duration, result, bytes });
              cacheBytes += bytes;
              while (cache.size > 512 || cacheBytes > MAX_CACHE_BYTES) evict(cache.keys().next().value!);
            }
          }
          return result;
        } catch (error) {
          if (error instanceof RpcProxyError) throw error;
        }
      }
      throw new RpcProxyError("RPC providers unavailable", -32002, 502);
    })();
    flights.set(key, work);
    try { return await work; } finally { clearTimeout(deadline); flights.delete(key); }
  }
  async function dispatch(payload: unknown): Promise<{ body: Reply | Reply[]; status: number }> {
    const rows = Array.isArray(payload) ? payload : [payload];
    if (!rows.length || rows.length > 20) throw new RpcProxyError("RPC batch must contain 1 to 20 requests");
    for (const row of rows) {
      if (!object(row) || row.jsonrpc !== "2.0" || !Object.hasOwn(row, "id") || !(row.id === null || (typeof row.id === "string" && row.id.length <= 128) || (typeof row.id === "number" && Number.isSafeInteger(row.id)))) throw new RpcProxyError("Invalid JSON-RPC request");
      try { validate(row.method, row.params ?? []); }
      catch (error) {
        if (error instanceof RpcProxyError) error.id = row.id as Reply["id"];
        throw error;
      }
    }
    let status = 200;
    const replies = await Promise.all(rows.map(async (row): Promise<Reply> => {
      const input = row as { id: Reply["id"]; method: string; params?: Params };
      try { return { jsonrpc: "2.0", id: input.id, result: await request(input.method, input.params ?? []) }; }
      catch (error) {
        const e = error instanceof RpcProxyError ? error : new RpcProxyError("RPC request failed", -32002, 502);
        if (e.status !== 200) status = Math.max(status, e.status);
        return { jsonrpc: "2.0", id: input.id, error: { code: e.code, message: e.message, ...(e.data ? { data: e.data } : {}) } };
      }
    }));
    return { body: Array.isArray(payload) ? replies : replies[0], status };
  }
  return { request, dispatch };
}

const dispatcher = createRpcDispatcher();
export const rpcRequest = dispatcher.request;
export const dispatchRpcPayload = dispatcher.dispatch;
