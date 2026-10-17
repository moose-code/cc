// promise: a Seaport order without a hash is skipped with one warning and the tick carries on with the hashed orders
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Sources } from "../src/listings.ts";
import { setSink } from "../src/log.ts";

const offerer = "0x00000000000000000000000000000000000000f1";
const params = {
  considerationToken: "0x0000000000000000000000000000000000000000",
  considerationIdentifier: "0",
  considerationAmount: "900",
  offerer,
  zone: "0x0000000000000000000000000000000000000000",
  offerToken: "0x97630aA70AB14ed9883B41dAfccBc11349723043",
  offerIdentifier: "42",
  offerAmount: "1",
  basicOrderType: "0",
  startTime: "1",
  endTime: "2",
  zoneHash: "0x" + "00".repeat(32),
  salt: "5",
  offererConduitKey: "0x" + "00".repeat(32),
  fulfillerConduitKey: "0x" + "00".repeat(32),
  totalOriginalAdditionalRecipients: "0",
  additionalRecipients: [],
  signature: "0xabcd",
};

test("seaport: a hashless order is skipped with a warning, the hashed order in the same batch is evaluated", async () => {
  const file = join(mkdtempSync(join(tmpdir(), "keeper-orders-")), "orders.json");
  const hash = "0x" + "11".repeat(32);
  writeFileSync(
    file,
    JSON.stringify({
      orders: [
        { id: "41", price: "1000", params },
        { id: "42", price: "1000", params, hash },
      ],
    }),
  );
  const cfg: any = {
    record: { core: "0x00000000000000000000000000000000000000c0", seaportAdapter: "0x00000000000000000000000000000000000000a1" },
    strategy: { mode: "off" },
    opensea: { file, refreshSec: 60, pages: 1, sign: 0 },
  };
  const read: string[] = [];
  const client: any = {
    multicall: async ({ contracts }: { contracts: { functionName: string }[] }) =>
      contracts.map((c) => {
        read.push(c.functionName);
        const result =
          c.functionName === "bidOf" ? 0n : c.functionName === "price" ? ["0x0", 1000n, "0x"] : c.functionName === "ownerOf" ? offerer : [true, false, 0n, 0n];
        return { status: "success", result };
      }),
  };
  const lines: any[] = [];
  setSink((l) => lines.push(JSON.parse(l)));
  try {
    const s = new Sources(client, cfg, () => 1_000_000_000);
    (s as any).scores = new Map([[41n, 2000n], [42n, 2000n]]);
    const out = await s.candidates({ ethRate: 1_000_000n } as any, 1n);
    assert.deepEqual(out.map((l) => [l.id, l.valid]), [[42n, true]]);
    assert.deepEqual(read, ["bidOf", "price", "ownerOf", "getOrderStatus"]);
    const warns = lines.filter((l) => l.level === "warn");
    assert.equal(warns.length, 1);
    assert.match(warns[0].msg, /no hash/);
    assert.equal(warns[0].id, "41");
  } finally {
    setSink((l) => process.stdout.write(l + "\n"));
  }
});
