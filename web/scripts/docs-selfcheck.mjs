// promise: public docs have valid references and omit deferred balance flows.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { contractCatalog } from "../lib/docs-catalog.ts";
import { docPages, entryId } from "../lib/docs-content.ts";

const slugs = new Set();
for (const page of docPages) {
  assert(!slugs.has(page.slug), `duplicate docs route: ${page.slug}`);
  slugs.add(page.slug);

  const anchors = new Set();
  const contractPage = page.group === "Contracts";
  const source = page.source && readFileSync(new URL(`../../${page.sourceSnapshot ?? page.source}`, import.meta.url), "utf8");
  if (contractPage) assert(source, `${page.title} needs a source interface`);
  if (page.slug === "contracts/credit-score-lens") {
    assert.equal(createHash("sha256").update(source).digest("hex"), "a967eda07be960d3fde5f4e03dea543f28d31bf89d487e19a465fb4f89c480e2", "deployed helper interface snapshot changed");
  }

  for (const section of page.sections) {
    assert(!anchors.has(section.id), `duplicate section: ${page.slug}#${section.id}`);
    anchors.add(section.id);
    section.entries?.forEach((entry, index) => {
      const id = entryId(section, index);
      assert(!anchors.has(id), `duplicate entry: ${page.slug}#${id}`);
      anchors.add(id);
      if (!contractPage) return;

      for (const part of entry.signature.split(" / ")) {
        const name = part.match(/^(?:Core\.)?([A-Za-z][A-Za-z0-9_]*)\(/)?.[1];
        assert(name, `unrecognized signature: ${entry.signature}`);
        const interfaceFile = part.startsWith("Core.")
          ? readFileSync(new URL("../../src/interfaces/ICore.sol", import.meta.url), "utf8")
          : page.slug === "contracts/adapters" && /^(?:setAllowedRecipient|RecipientSet)\(/.test(part)
            ? readFileSync(new URL("../../src/interfaces/ISeaportBasicAdapter.sol", import.meta.url), "utf8")
            : source;
        assert(new RegExp(`\\b(?:function|event)\\s+${name}\\s*\\(`).test(interfaceFile), `${page.title}: ${name} missing from interface`);
      }
    });
  }
}

assert(docPages.some((page) => page.slug === ""), "docs landing page missing");
const deployment = JSON.parse(readFileSync(new URL("../../deployments/1.json", import.meta.url), "utf8"));
assert.equal(docPages.find((page) => page.slug === "contracts/core")?.mainnetAddress, deployment.core, "Core address differs from deployment record");
assert.equal(docPages.find((page) => page.slug === "contracts/controller")?.mainnetAddress, deployment.controller, "Controller address differs from deployment record");
assert(!/\b(?:balance|redeem\w*|redemp\w*)\b/i.test(JSON.stringify(docPages)), "deferred balance flow appears in public docs");
assert(!docPages.some((page) => page.slug === "contracts/balance-module"), "deferred balance module page must stay unpublished");
assert(!Object.hasOwn(contractCatalog, "contracts/balance-module"), "deferred balance module catalog must stay unpublished");
console.log(`docs: ${docPages.length} routes and contract reference names verified`);
