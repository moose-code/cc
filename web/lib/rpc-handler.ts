import { dispatchRpcPayload, RpcProxyError } from "./rpc-proxy.ts";

const MAX_BODY = 128 * 1024;

export async function handleRpcRequest(request: Request): Promise<Response> {
  const headers = { "content-type": "application/json", "cache-control": "no-store" };
  try {
    if (Number(request.headers.get("content-length")) > MAX_BODY) throw new RpcProxyError("RPC body exceeds 128 KiB");
    const reader = request.body?.getReader();
    if (!reader) throw new RpcProxyError("Missing JSON-RPC body");
    const chunks: Uint8Array[] = [];
    let size = 0;
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) break;
      size += chunk.value.byteLength;
      if (size > MAX_BODY) { await reader.cancel(); throw new RpcProxyError("RPC body exceeds 128 KiB"); }
      chunks.push(chunk.value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    let payload: unknown;
    try { payload = JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new RpcProxyError("Invalid JSON", -32700); }
    const result = await dispatchRpcPayload(payload);
    return new Response(JSON.stringify(result.body), { status: result.status, headers: { ...headers, ...(result.status === 429 ? { "retry-after": "1" } : {}) } });
  } catch (error) {
    const e = error instanceof RpcProxyError ? error : new RpcProxyError("RPC request failed", -32002, 502);
    return new Response(JSON.stringify({ jsonrpc: "2.0", id: e.id ?? null, error: { code: e.code, message: e.message } }), { status: e.status, headers: { ...headers, ...(e.status === 429 ? { "retry-after": "1" } : {}) } });
  }
}
