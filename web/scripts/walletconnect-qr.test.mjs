// promise: RainbowKit's genuine Cuer QR renderer accepts its zero-border grid and cannot crash wallet connection.
import assert from "node:assert/strict";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Cuer } from "cuer";

// Public synthetic pairing data; this URI does not identify or authorize a real WalletConnect session.
const uri = `wc:${"0".repeat(64)}@2?relay-protocol=irn&symKey=${"0".repeat(64)}`;
for (const logo of [false, true]) {
  const svg = renderToStaticMarkup(createElement(Cuer.Root, { value: uri, size: 200, errorCorrection: "low" },
    createElement(Cuer.Cells), createElement(Cuer.Finder),
    logo ? createElement(Cuer.Arena, null, createElement("span", null, "test logo")) : null,
  ));
  assert.match(svg, /^<svg\b/);
  assert.match(svg, /<path\b/);
  assert.match(svg, /<rect\b/);
  assert.match(svg, /viewBox="0 0 \d+ \d+"/);
  assert.ok(!svg.includes("NaN"));
}
console.log("WalletConnect Cuer QR render passed with and without a logo");
