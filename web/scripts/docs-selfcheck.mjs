// promise: every published contract page has unique anchors and names callable methods or events that exist in the generated interfaces.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { docPages, entryId } from "../lib/docs-content.ts";

const slugs = new Set();
for (const page of docPages) {
  assert(!slugs.has(page.slug), `duplicate docs route: ${page.slug}`);
  slugs.add(page.slug);

  const anchors = new Set();
  const contractPage = page.group === "Contract API";
  const source = page.source && readFileSync(new URL(`../../${page.source}`, import.meta.url), "utf8");
  if (contractPage) assert(source, `${page.title} needs a source interface`);

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
console.log(`docs: ${docPages.length} routes and contract reference names verified`);
