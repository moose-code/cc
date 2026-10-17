// promise: one unauthenticated client cannot turn arbitrary order hashes into unlimited OpenSea requests.
// These guards fail on 1db4a9f and belong with the corresponding web fixes.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import ts from "typescript";

test("arbitrary fulfillment hashes cannot call OpenSea", async () => {
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
      await GET(new Request(`https://example.test/api/listings?fulfill=${hash}`));
    }
    const repeated = `0x${(205).toString(16).padStart(64, "0")}`;
    await GET(new Request(`https://example.test/api/listings?fulfill=${repeated}`));
    process.stdout.write(`arbitrary hashes: 205; upstream POSTs: ${upstreamCalls}; listings cap: 200\n`);
    assert.equal(upstreamCalls, 0, "unlisted hashes must never reach the keyed upstream API");
  } finally {
    globalThis.fetch = originalFetch;
    if (originalKey === undefined) delete process.env.OPENSEA_API_KEY;
    else process.env.OPENSEA_API_KEY = originalKey;
  }
});

// promise: the public App Router uses a Next release with the published Server Components DoS fix.
test("web lockfile pins a Next release with the Server Components DoS fix", () => {
  const lock = JSON.parse(readFileSync(new URL("../../package-lock.json", import.meta.url), "utf8"));
  const version = lock.packages["node_modules/next"].version;
  process.stdout.write(`locked Next: ${version}; GHSA-5j59-xgg2-r9c4 patched in 14.2.35\n`);
  const [major, minor, patch] = version.split(".").map(Number);
  assert.ok(major > 14 || (major === 14 && (minor > 2 || (minor === 2 && patch >= 35))), "Next must include the published fix");
});
