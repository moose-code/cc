// Bundles scripts/history-selfcheck.ts with the workspace esbuild and runs it. The selfcheck imports lib modules that
// use bundler-style extensionless imports, which node's type stripping does not resolve, so it is bundled first.
import { execFileSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const esbuild = join(here, "..", "..", "indexer", "node_modules", ".bin", "esbuild");
const entry = join(here, "history-selfcheck.ts");
const out = join(mkdtempSync(join(tmpdir(), "history-selfcheck-")), "bundle.mjs");

execFileSync(esbuild, [entry, "--bundle", "--platform=node", "--format=esm", `--outfile=${out}`, "--log-level=warning"], {
  stdio: "inherit",
});
await import(pathToFileURL(out).href);
