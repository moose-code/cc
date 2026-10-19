// Server renders and API routes share the same read-only dispatcher as browser reads.
import { custom, http } from "viem";
import { isLocal, rpcUrl } from "./config";
import { rpcRequest } from "./rpc-proxy";

export const serverRpcTransport = () => isLocal
  ? http(rpcUrl, { retryCount: 0, timeout: 10_000 })
  : custom({ request: ({ method, params }) => rpcRequest(method, (params ?? []) as readonly unknown[]) }, { retryCount: 0 });
