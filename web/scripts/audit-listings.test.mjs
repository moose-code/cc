// promise: one unauthenticated client cannot turn arbitrary order hashes into unlimited OpenSea requests.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import ts from "typescript";

test("distinct arbitrary fulfillment hashes each call OpenSea", async () => {
  const source = readFileSync(new URL("../app/api/listings/route.ts", import.meta.url), "utf8");
  let body = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
  }).outputText;
  // Keep the route body exact. Only replace imports with the two configured addresses the GET gate needs.
  body = `const core = "0x1111111111111111111111111111111111111111";
const seaportAdapter = "0x2222222222222222222222222222222222222222";
${body.replace(/^import .*;\s*$/gm, "")}`;
  const { GET } = await import(`data:text/javascript;base64,${Buffer.from(body).toString("base64")}`);
  const originalFetch = globalThis.fetch;
  const originalKey = process.env.OPENSEA_API_KEY;
  let upstreamCalls = 0;
  globalThis.fetch = async () => {
    upstreamCalls++;
    return { ok: true, json: async () => ({}) };
  };
  process.env.OPENSEA_API_KEY = "audit-dummy";
  try {
    for (let i = 1; i <= 205; i++) {
      const hash = `0x${i.toString(16).padStart(64, "0")}`;
      const response = await GET(new Request(`https://example.test/api/listings?fulfill=${hash}`));
      assert.equal(response.status, 200);
    }
    assert.equal(upstreamCalls, 205, "every distinct syntactically valid hash calls the paid API");
    const repeated = `0x${(205).toString(16).padStart(64, "0")}`;
    await GET(new Request(`https://example.test/api/listings?fulfill=${repeated}`));
    assert.equal(upstreamCalls, 205, "only an identical hash hits the 10-second cache");
    process.stdout.write(`arbitrary hashes: 205; upstream POSTs: ${upstreamCalls}; listings cap: 200\n`);
  } finally {
    globalThis.fetch = originalFetch;
    if (originalKey === undefined) delete process.env.OPENSEA_API_KEY;
    else process.env.OPENSEA_API_KEY = originalKey;
  }
});

// promise: the public App Router uses a Next release with the published Server Components DoS fix.
test("web lockfile pins Next below the Server Components DoS fix", () => {
  const lock = JSON.parse(readFileSync(new URL("../../package-lock.json", import.meta.url), "utf8"));
  const version = lock.packages["node_modules/next"].version;
  assert.equal(version, "14.2.33");
  process.stdout.write(`locked Next: ${version}; GHSA-5j59-xgg2-r9c4 patched in 14.2.35\n`);
});
