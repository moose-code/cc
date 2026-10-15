// OpenSea listings of the Credits collection that the Core can fill through SeaportBasicAdapter (owner decision 128).
// Server only: OPENSEA_API_KEY never reaches the browser. The response is the cheapest listings that pass the
// adapter's checks, each with the encoded `params` for Core.buyListing, and is cached for CACHE_MS so every browser
// shares one OpenSea round of requests.

import { createPublicClient, encodeAbiParameters, getAddress, http, zeroAddress, type Address, type Hex } from "viem";
import { core, credits, rpcUrl, seaportAdapter } from "@/lib/config";
import { basicOrderParameters, seaportAdapterAbi } from "@/lib/abis";

export const dynamic = "force-dynamic";

const OS = "https://api.opensea.io/api/v2";
const SLUG = "credits";
const SEAPORT_1_6 = "0x0000000000000068f116a894984e2db1123eb395";
const BEST = 30; // listings read from the collection
const FULFILL = 8; // cheapest of them that get fulfillment data (ponytail: by price only, a higher priced credit with a larger bid is not considered)
const CACHE_MS = 20_000;

interface Out {
  listings: { id: string; price: string; params: Hex; orderHash: string }[];
  /** fee recipients that stop an order, with the number of orders each stopped */
  blocked: Record<string, number>;
  skipped: Record<string, number>;
}

let cache: { at: number; out: Out } | undefined;
let inflight: Promise<Out> | undefined;

const lc = (a: string) => a.toLowerCase();

async function os(path: string, init?: RequestInit) {
  const r = await fetch(`${OS}${path}`, {
    ...init,
    headers: { "x-api-key": process.env.OPENSEA_API_KEY!, accept: "application/json", "content-type": "application/json" },
    cache: "no-store",
  });
  if (!r.ok) throw new Error(`opensea ${r.status}`);
  return r.json();
}

async function build(): Promise<Out> {
  const out: Out = { listings: [], blocked: {}, skipped: {} };
  const skip = (why: string) => (out.skipped[why] = (out.skipped[why] ?? 0) + 1);
  const best = (await os(`/listings/collection/${SLUG}/best?limit=${BEST}`)).listings as any[];
  const cheap = best
    .filter((l) => {
      const ok = l.status === "ACTIVE" && l.type === "basic" && l.price?.current?.currency === "ETH" && lc(l.protocol_address) === SEAPORT_1_6;
      if (!ok) skip("not an active basic eth order");
      return ok;
    })
    .sort((a, b) => (BigInt(a.price.current.value) < BigInt(b.price.current.value) ? -1 : 1))
    .slice(0, FULFILL);

  const client = createPublicClient({ transport: http(rpcUrl) });
  const allowed = new Map<string, Promise<boolean>>();
  const isAllowed = (r: string) => {
    if (!allowed.has(r)) allowed.set(r, client.readContract({ address: seaportAdapter!, abi: seaportAdapterAbi, functionName: "allowedRecipient", args: [getAddress(r)] }));
    return allowed.get(r)!;
  };

  await Promise.all(
    cheap.map(async (l) => {
      try {
        const body = { listing: { hash: l.order_hash, chain: "ethereum", protocol_address: l.protocol_address }, fulfiller: { address: core } };
        const f = (await os("/listings/fulfillment_data", { method: "POST", body: JSON.stringify(body) })).fulfillment_data?.transaction;
        const p = f?.input_data?.parameters;
        if (!p || !String(f.function).startsWith("fulfillBasicOrder_efficient_6GL6yc") || lc(f.to) !== SEAPORT_1_6) return skip("not a fulfillBasicOrder call");
        if (lc(p.offerToken) !== lc(credits) || p.offerAmount !== "1") return skip("not one credit");
        if (lc(p.considerationToken) !== zeroAddress) return skip("not native currency");
        if (Number(p.basicOrderType) > 1) return skip("restricted order type");
        let price = BigInt(p.considerationAmount);
        for (const r of p.additionalRecipients as { amount: string; recipient: string }[]) {
          price += BigInt(r.amount);
          if (lc(r.recipient) !== lc(p.offerer) && !(await isAllowed(r.recipient))) {
            out.blocked[lc(r.recipient)] = (out.blocked[lc(r.recipient)] ?? 0) + 1;
            return skip("fee recipient not allowed by the adapter");
          }
        }
        if (price !== BigInt(f.value)) return skip("value mismatch");
        const params = encodeAbiParameters(basicOrderParameters, [
          {
            considerationToken: p.considerationToken,
            considerationIdentifier: BigInt(p.considerationIdentifier),
            considerationAmount: BigInt(p.considerationAmount),
            offerer: p.offerer,
            zone: p.zone,
            offerToken: p.offerToken,
            offerIdentifier: BigInt(p.offerIdentifier),
            offerAmount: BigInt(p.offerAmount),
            basicOrderType: Number(p.basicOrderType),
            startTime: BigInt(p.startTime),
            endTime: BigInt(p.endTime),
            zoneHash: p.zoneHash,
            salt: BigInt(p.salt),
            offererConduitKey: p.offererConduitKey,
            fulfillerConduitKey: p.fulfillerConduitKey,
            totalOriginalAdditionalRecipients: BigInt(p.totalOriginalAdditionalRecipients),
            additionalRecipients: p.additionalRecipients.map((r: { amount: string; recipient: Address }) => ({ amount: BigInt(r.amount), recipient: r.recipient })),
            signature: p.signature,
          },
        ]);
        out.listings.push({ id: p.offerIdentifier, price: price.toString(), params, orderHash: l.order_hash });
      } catch {
        skip("fulfillment data failed");
      }
    }),
  );
  out.listings.sort((a, b) => (BigInt(a.price) < BigInt(b.price) ? -1 : 1));
  return out;
}

export async function GET() {
  const empty: Out = { listings: [], blocked: {}, skipped: {} };
  if (!process.env.OPENSEA_API_KEY || !seaportAdapter || !core) return Response.json(empty);
  if (cache && Date.now() - cache.at < CACHE_MS) return Response.json(cache.out);
  try {
    inflight ??= build().finally(() => (inflight = undefined));
    const out = await inflight;
    cache = { at: Date.now(), out };
    return Response.json(out);
  } catch {
    // OpenSea or the node failed: keep the last good answer for one more window, else nothing
    cache = { at: Date.now(), out: cache?.out ?? empty };
    return Response.json(cache.out);
  }
}
