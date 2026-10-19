// Server-side reads for page metadata and OG images. The indexer is read first (same tables as lib/indexer.ts), the
// chain second (tokenURI only), each under a timeout so a slow source cannot hold a render. Results are cached 60 s.
import { unstable_cache } from "next/cache";
import { createClient, count, eq } from "@ponder/client";
import { createPublicClient, type Address } from "viem";
import { chain, credits, indexerUrl, statements } from "./config";
import { serverRpcTransport } from "./server-rpc";
import { tokenUriAbi } from "./abis";
import { rating } from "./format";
import * as schema from "./indexer-schema";

const TIMEOUT_MS = 2500;
const { credit, statement } = schema;
const ix = indexerUrl ? createClient(`${indexerUrl}/sql`, { schema }) : undefined;
const chainClient = createPublicClient({ chain, transport: serverRpcTransport() });

const timed = <T,>(p: Promise<T>): Promise<T> =>
  Promise.race([p, new Promise<never>((_, rej) => setTimeout(() => rej(new Error("timeout")), TIMEOUT_MS))]);

export interface TokenMetaInfo {
  kind: "credit" | "statement";
  id: number;
  rating?: string;
  state?: string;
  format?: string;
  art?: string; // image data URI or URL; only with withArt
}

// image of a tokenURI json (data: URI, base64 or percent-encoded)
function artOf(uri?: string | null): string | undefined {
  const m = uri && /^data:application\/json([^,]*),([\s\S]*)$/.exec(uri);
  if (!m) return undefined;
  try {
    const body = /;base64/.test(m[1]) ? Buffer.from(m[2], "base64").toString() : decodeURIComponent(m[2]);
    const img = JSON.parse(body).image;
    return typeof img === "string" && img.startsWith("data:") ? img : undefined;
  } catch {
    return undefined;
  }
}

async function readToken(kind: "credit" | "statement", id: number, withArt: boolean): Promise<TokenMetaInfo | null> {
  const base: TokenMetaInfo = { kind, id };
  try {
    if (ix) {
      const t = kind === "credit" ? credit : statement;
      const rows = await timed(ix.db.select().from(t).where(eq(t.id, BigInt(id))).limit(1));
      const r = rows[0] as any;
      if (r) {
        return {
          ...base,
          rating: kind === "credit" ? rating(r.score) : r.rating != null ? rating(r.rating) : undefined,
          state: r.state,
          format: r.formatName?.toLowerCase() ?? undefined,
          art: withArt ? artOf(r.tokenUri) : undefined,
        };
      }
    }
  } catch (e) {
    console.warn(`meta: indexer read of ${kind} ${id} failed:`, e instanceof Error ? e.message : e);
  }
  if (!withArt) return null;
  try {
    const uri = await timed(chainClient.readContract({ address: (kind === "credit" ? credits : statements) as Address, abi: tokenUriAbi, functionName: "tokenURI", args: [BigInt(id)] }));
    return { ...base, art: artOf(uri) };
  } catch (e) {
    console.warn(`meta: chain read of ${kind} ${id} failed:`, e instanceof Error ? e.message : e);
    return null;
  }
}

export const getToken = unstable_cache(readToken, ["meta-token-v2"], { revalidate: 60 });

/** Held credits and total statements, for the index-page OG images. */
export const getCounts = unstable_cache(
  async () => {
    if (!ix) return null;
    try {
      const [held, stmts] = await timed(
        Promise.all([ix.db.select({ n: count() }).from(credit).where(eq(credit.state, "held")), ix.db.select({ n: count() }).from(statement)]),
      );
      return { held: Number(held[0]?.n ?? 0), statements: Number(stmts[0]?.n ?? 0) };
    } catch (e) {
      console.warn("meta: indexer counts failed:", e instanceof Error ? e.message : e);
      return null;
    }
  },
  ["meta-counts-v2"],
  { revalidate: 60 },
);

export const tokenDescription = (t: TokenMetaInfo | null) =>
  [t?.format, t?.rating ? `rating ${t.rating}` : undefined, t?.state].filter(Boolean).join(" · ");
