import assert from "node:assert/strict";
import { test, mock } from "node:test";
import { mainnet } from "viem/chains";
import { fallbackTransport, type Endpoint } from "../src/lib/rpc.ts";
import { sanitizedRpc, withFastFallback } from "../rpc-config.ts";

const publics: Endpoint[] = [
  { url: "https://gateway.tenderly.co/public/mainnet", rps: 4 },
  { url: "https://eth-mainnet.public.blastapi.io", rps: 8 },
  { url: "https://1rpc.io/eth", rps: 5 },
  { url: "https://ethereum-rpc.publicnode.com", rps: 10 },
  { url: "https://eth.drpc.org", rps: 5 },
  { url: "https://rpc.mevblocker.io", rps: 5 },
];
const fast = "https://eth-mainnet.g.alchemy.com/v2/public-fixture";
const reserve = { url: "https://reserve.invalid/public-fixture", rps: 10 };

// promise: Tenderly stays first, Alchemy is the first fallback, and the existing public caps and distinct reserve stay unchanged.
test("fast fallback priority and physical caps", () => {
  assert.deepEqual(withFastFallback(publics, reserve), { endpoints: publics, reserve });
  const configured = withFastFallback(publics, reserve, fast);
  assert.deepEqual(configured.endpoints, [publics[0], { url: fast, rps: 4 }, ...publics.slice(1)]);
  assert.deepEqual(configured.reserve, reserve);
  assert.equal(withFastFallback(publics, reserve, fast, "2").endpoints[1].rps, 2);
  assert.equal(withFastFallback(publics, { url: fast, rps: 10 }, fast).reserve, undefined);
});

// promise: endpoint/cap errors fail without reflecting a credential-bearing URL into startup logs.
test("invalid fast fallback configuration is sanitized", () => {
  for (const value of ["not-a-url/public-fixture", "http://eth-mainnet.g.alchemy.com/v2/public-fixture", "https://base-mainnet.g.alchemy.com/v2/public-fixture", "https://eth-mainnet.g.alchemy.com.evil.invalid/public-fixture", "https://user:public-fixture@eth-mainnet.g.alchemy.com/v2/a"]) {
    assert.throws(() => withFastFallback(publics, reserve, value), (error) => {
      assert.doesNotMatch(String(error), /public-fixture/);
      return true;
    });
  }
  for (const value of ["0", "-1", "5", "9", "1.5", "NaN", ""]) assert.throws(() => withFastFallback(publics, reserve, fast, value), /RPC_RPS_FAST_FALLBACK/);
});

// promise: actual fallback stops on a deterministic revert and exposes its code/data without any original endpoint URL or cause.
test("actual fallback revert and ordinary errors cannot disclose the endpoint credential", async () => {
  const hosts: string[] = [];
  mock.method(globalThis, "fetch", async (url: string, init: RequestInit) => {
    const body = JSON.parse(String(init.body));
    hosts.push(new URL(url).host);
    return new Response(JSON.stringify({ jsonrpc: "2.0", id: body.id, error: { code: 3, message: "execution reverted", data: "0xdead" } }));
  });
  try {
    const endpoint = { url: fast, rps: 4 };
    const transport = sanitizedRpc(fallbackTransport([endpoint, publics[0]]))({ chain: mainnet, retryCount: 0 });
    await assert.rejects(transport.request({ method: "eth_call", params: [{ to: "0x" + "1".repeat(40), data: "0x" }, "latest"] }), (error: unknown) => {
      const e = error as Error & { code: number; data: string };
      assert.equal(e.code, 3); assert.equal(e.data, "0xdead");
      assert.match(e.message, /execution reverted/);
      assert.doesNotMatch(String(e.stack) + JSON.stringify(e), /public-fixture|https:\/\/eth-mainnet.g.alchemy.com/);
      return true;
    });
    assert.deepEqual(hosts, ["eth-mainnet.g.alchemy.com"]);
    const generic = sanitizedRpc(() => ({ ...transport, request: async () => { throw new Error("failed " + fast); } }))({ chain: mainnet, retryCount: 0 });
    await assert.rejects(generic.request({ method: "eth_chainId" }), (error: unknown) => {
      assert.doesNotMatch(String(error) + JSON.stringify(error), /public-fixture/);
      return true;
    });
  } finally { mock.restoreAll(); }
});
