"use client";

// Token art from the contracts: tokenURI(id) of the Credits and Statements
// collections, decoded to its name, image and attributes. Reads of one render
// pass go out as one multicall per collection. Cached per token id.

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import type { Address } from "viem";
import { engineDeployed, addresses } from "./config";
import { coreLensAbi, tokenUriAbi } from "./abis";
import { MULTICALL3 } from "./live";

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
    const res = await jobs[0].client.multicall({
      allowFailure: true,
      multicallAddress: MULTICALL3,
      contracts: jobs.map((j) => ({ address: j.address, abi: tokenUriAbi, functionName: "tokenURI", args: [BigInt(j.id)] }) as const),
    });
    await Promise.all(
      jobs.map(async (j, i) => {
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

// The Credits and Statements contract addresses, from the lens.
export function useCollections() {
  const client = usePublicClient();
  return useQuery<{ credits: Address; statements: Address } | undefined>({
    queryKey: ["collections", addresses.coreLens],
    enabled: engineDeployed && Boolean(client),
    staleTime: Infinity,
    queryFn: async () => {
      const [credits, statements] = await Promise.all([
        client!.readContract({ address: addresses.coreLens!, abi: coreLensAbi, functionName: "CREDITS" }),
        client!.readContract({ address: addresses.coreLens!, abi: coreLensAbi, functionName: "STATEMENTS" }),
      ]);
      return { credits, statements };
    },
  });
}

// null: tokenURI reverted or could not be decoded. undefined: still loading.
export function useTokenMeta(kind: TokenKind, id: number) {
  const client = usePublicClient();
  const { data: col } = useCollections();
  const address = kind === "credit" ? col?.credits : col?.statements;
  return useQuery<TokenMeta | null>({
    queryKey: ["token-meta", kind, address, id],
    enabled: Boolean(client && address),
    staleTime: Infinity,
    gcTime: 30 * 60 * 1000,
    queryFn: () =>
      new Promise<TokenMeta | null>((resolve, reject) => {
        queue.push({ client: client!, kind, address: address!, id, resolve, reject });
        timer ??= setTimeout(flush, 15);
      }),
  });
}
