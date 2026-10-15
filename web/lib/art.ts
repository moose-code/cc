"use client";

// Token art: tokenURI(id) of the Credits and Statements collections, decoded to
// its name, image and attributes. In indexer mode (lib/indexer.ts) the indexer's
// stored tokenURI is used; a token it lacks, and chain mode, read the contract.
// Reads of one render pass go out as one query or multicall per collection. Cached per token id in memory and,
// for entries under 32 KB (credits; a statement is ~160 KB), in localStorage.

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import type { Address } from "viem";
import { credits, engineDeployed, statements } from "./config";
import { tokenUriAbi } from "./abis";
import { MULTICALL3 } from "./live";
import { fetchTokenUris, getIxMode, useIxMode } from "./indexer";
import { SCOPE, lsGet, lsSet, verifyScope } from "./cache";

export type TokenKind = "credit" | "statement";

export interface TokenMeta {
  name?: string;
  image?: string; // data: URI or URL, ready for <img src>
  attrs: Record<string, string | number>; // trait_type -> value
}

type Client = NonNullable<ReturnType<typeof usePublicClient>>;
interface Job {
  client: Client;
  kind: TokenKind;
  address: Address;
  id: number;
  resolve: (m: TokenMeta | null) => void;
  reject: (e: unknown) => void;
}

// A statement's metadata is ~160 KB, so fewer per call.
const CHUNK: Record<TokenKind, number> = { credit: 50, statement: 6 };

const gateway = (u: string) => (u.startsWith("ipfs://") ? `https://ipfs.io/ipfs/${u.slice(7)}` : u);

function toMeta(j: any): TokenMeta {
  const attrs: TokenMeta["attrs"] = {};
  for (const a of j.attributes ?? []) if (a?.trait_type != null) attrs[a.trait_type] = a.value;
  return { name: j.name, image: typeof j.image === "string" ? gateway(j.image) : undefined, attrs };
}

// data:application/json (base64, utf8 or percent-encoded) decoded inline; http(s) and ipfs fetched.
async function resolveUri(uri: string): Promise<TokenMeta | null> {
  try {
    const m = /^data:application\/json([^,]*),([\s\S]*)$/.exec(uri);
    if (m) {
      const body = m[2];
      if (/;base64/.test(m[1])) {
        const bytes = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
        return toMeta(JSON.parse(new TextDecoder().decode(bytes)));
      }
      try {
        return toMeta(JSON.parse(body));
      } catch {
        return toMeta(JSON.parse(decodeURIComponent(body)));
      }
    }
    if (/^(https?|ipfs):\/\//.test(uri)) return toMeta(await (await fetch(gateway(uri))).json());
  } catch {
    /* unreadable metadata */
  }
  return null;
}

let queue: Job[] = [];
let timer: ReturnType<typeof setTimeout> | undefined;

async function run(jobs: Job[]) {
  try {
    const uris = getIxMode() === "ix" ? await fetchTokenUris(jobs[0].kind, jobs.map((j) => j.id)).catch(() => new Map<number, string>()) : new Map<number, string>();
    const rest: Job[] = [];
    await Promise.all(
      jobs.map(async (j) => {
        const uri = uris.get(j.id);
        if (uri) j.resolve(await resolveUri(uri));
        else rest.push(j);
      })
    );
    if (rest.length === 0) return;
    const res = await rest[0].client.multicall({
      allowFailure: true,
      multicallAddress: MULTICALL3,
      contracts: rest.map((j) => ({ address: j.address, abi: tokenUriAbi, functionName: "tokenURI", args: [BigInt(j.id)] }) as const),
    });
    await Promise.all(
      rest.map(async (j, i) => {
        const r = res[i];
        j.resolve(r.status === "success" ? await resolveUri(r.result as string) : null); // a reverting tokenURI is null
      })
    );
  } catch (e) {
    for (const j of jobs) j.reject(e);
  }
}

function flush() {
  const jobs = queue;
  queue = [];
  timer = undefined;
  const groups = new Map<string, Job[]>();
  for (const j of jobs) {
    const k = `${j.kind}:${j.address}`;
    groups.set(k, [...(groups.get(k) ?? []), j]);
  }
  for (const g of groups.values())
    for (let i = 0; i < g.length; i += CHUNK[g[0].kind]) run(g.slice(i, i + CHUNK[g[0].kind]));
}

const metaMem = new Map<string, TokenMeta | null>();
const META_MAX_CHARS = 32_000;

// A token's metadata does not change: read from memory, then storage, then the chain.
async function loadMeta(kind: TokenKind, address: Address, id: number, client: Client): Promise<TokenMeta | null> {
  const key = `${SCOPE}:art:${address.toLowerCase()}:${id}`;
  await verifyScope(client);
  if (metaMem.has(key)) return metaMem.get(key)!;
  const stored = lsGet<TokenMeta>(key);
  if (stored) {
    metaMem.set(key, stored);
    return stored;
  }
  const m = await new Promise<TokenMeta | null>((resolve, reject) => {
    queue.push({ client, kind, address, id, resolve, reject });
    timer ??= setTimeout(flush, 15);
  });
  if (m) {
    metaMem.set(key, m);
    lsSet(key, m, META_MAX_CHARS);
  }
  return m; // a null (reverted or unreadable tokenURI) is retried on the next mount
}

// null: tokenURI reverted or could not be decoded. undefined: still loading.
export function useTokenMeta(kind: TokenKind, id: number, enabled = true) {
  const client = usePublicClient();
  const address = kind === "credit" ? credits : statements;
  const mode = useIxMode(); // the source (indexer or chain) is known after the first health check
  return useQuery<TokenMeta | null>({
    queryKey: ["token-meta", kind, address, id],
    enabled: enabled && engineDeployed && Boolean(client) && mode !== "checking",
    staleTime: Infinity,
    gcTime: 30 * 60 * 1000,
    queryFn: () => loadMeta(kind, address, id, client!),
  });
}
