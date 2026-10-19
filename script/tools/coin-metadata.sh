#!/usr/bin/env bash
# previews the launch renderer or reads a deployed coin on a mainnet fork, then decodes into out/coin-metadata/: contractURI.txt (raw),
# metadata.json (parsed), image.svg, index.html (a viewer with raw, parsed and the image).
#   script/tools/coin-metadata.sh                       preview the launch animated logo
#   COIN=<coin> script/tools/coin-metadata.sh           read the deployed coin's renderer
#   FORK_URL=<rpc> (default the Tenderly public gateway), FORK_BLOCK=<block> (default latest)
set -euo pipefail
cd "$(dirname "$0")/../.."
rpc="${FORK_URL:-https://mainnet.gateway.tenderly.co}"
out="out/coin-metadata"
mkdir -p "$out"
args=(script/dev/CoinMetadata.s.sol --tc CoinMetadata --rpc-url "$rpc")
[ -n "${FORK_BLOCK:-}" ] && args+=(--fork-block-number "$FORK_BLOCK")
forge script "${args[@]}" > "$out/forge.log"
grep -E "^  (renderer|block|uri bytes)" "$out/forge.log" || true
grep -o 'CONTRACT_URI=.*' "$out/forge.log" | head -1 | cut -c14- | tr -d '\n' > "$out/contractURI.txt"
python3 - "$out" <<'PY'
import base64, json, sys, html, os
out = sys.argv[1]
uri = open(f"{out}/contractURI.txt").read()
prefix = "data:application/json;base64,"
assert uri.startswith(prefix), uri[:60]
meta = json.loads(base64.b64decode(uri[len(prefix):]))
img = meta["image"]
iprefix = "data:image/svg+xml;base64,"
assert img.startswith(iprefix), img[:60]
svg = base64.b64decode(img[len(iprefix):]).decode()
open(f"{out}/image.svg", "w").write(svg)
json.dump(meta, open(f"{out}/metadata.json", "w"), indent=2)
rows = "".join(f"<tr><th>{html.escape(k)}</th><td>{html.escape(v if k != 'image' else img[:80] + '… (' + str(len(img)) + ' chars)')}</td></tr>" for k, v in meta.items())
page = f"""<!doctype html><meta charset="utf-8"><title>coin metadata</title>
<style>body{{font:14px/1.4 monospace;margin:24px;max-width:1100px}}textarea{{width:100%;height:120px}}th{{text-align:left;padding-right:16px;vertical-align:top}}td{{word-break:break-all}}img{{width:480px;border:1px solid #ddd}}</style>
<h2>raw contractURI ({len(uri)} chars)</h2><textarea readonly>{html.escape(uri)}</textarea>
<h2>parsed json</h2><table>{rows}</table>
<h2>image ({len(svg)} svg bytes, {svg.count('<animate ')} animations)</h2><img src="{html.escape(img)}">
<p><a href="image.svg">image.svg</a> · <a href="metadata.json">metadata.json</a> · <a href="contractURI.txt">contractURI.txt</a></p>"""
open(f"{out}/index.html", "w").write(page)
print(f"{out}/index.html  animations={svg.count('<animate ')} svg={len(svg)}B uri={len(uri)}B")
PY
