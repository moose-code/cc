// Frontend arithmetic and transaction-orchestration checks only; no deployed-contract acceptance or broadcasts.
import assert from "node:assert/strict";
import { zeroAddress } from "viem";
import { waitForSuccessfulReceipt } from "../lib/tx-receipt.ts";
import { submitWithGasBuffer } from "../lib/tx-submit.ts";
import { exchangeEnabled } from "../lib/exchange-access.ts";
import { exchangeAmount, exchangeQuote, sellExchange, type ExchangeMarket } from "../lib/exchange.ts";

const token = "0x3620540c994433D7B4a628C46d2ED5F92572eA07" as const;
const market: ExchangeMarket = {
  balanceOn: true, balanceToken: token, balanceUnit: 10n ** 14n,
  balanceAvailable: 10_000n * 10n ** 18n, balanceRate: 9_000n,
  paused: false, retired: false, ethPrice: 0n,
  settings: { balanceBidOn: true, buyToArtistBps: 250 },
  value: { on: false, perPointSell: undefined },
};
const scores = [400n, 525n, 310n].map((points) => points * 10_000n);
let cases = 0;
async function check(name: string, run: () => unknown) { await run(); cases++; console.log(`ok ${name}`); }

// promise: the mockup's protocol fee reconciles to the batch payout without deducting the artist royalty.
await check("fee and artist royalty", () => {
  const quote = exchangeQuote(market, scores, 50)!;
  assert.equal(quote.total, 1_111_500_000_000_000_000_000n);
  assert.equal(quote.fee, 123_500_000_000_000_000_000n);
  assert.equal(quote.royalty, 27_787_500_000_000_000_000n);
  assert.equal(quote.gross, quote.fee + quote.adjustment + quote.total);
  assert.equal(exchangeAmount(quote.total, 18), "1,111.5");
  assert.equal(exchangeAmount(quote.minOut, 18), "1,105.9425");
});

// promise: the displayed minimum is exact and tolerance changes only the floor, never the quoted fee/payout.
await check("minimum and precision", () => {
  const exact = exchangeQuote(market, scores, 0)!;
  const tolerant = exchangeQuote(market, scores, 100)!;
  assert.equal(exact.minOut, exact.total);
  assert.equal(tolerant.total, exact.total);
  assert.equal(exchangeAmount(tolerant.minOut, 18), "1,100.385");
  assert.equal(exchangeAmount(1_000_000_000_000_000_001n, 18), "1.000000000000000001");
  assert.throws(() => exchangeQuote(market, scores, 10_000), /Unsupported/);
});

// promise: price protection appears separately from protocol fee and lowers the executable total.
await check("protection adjustment", () => {
  const quote = exchangeQuote({ ...market, ethPrice: 86n * 10n ** 16n, value: { on: true, perPointSell: 10n ** 16n } }, [1_000_000n], 50)!;
  assert.equal(exchangeAmount(quote.total, 18), "86");
  assert.equal(exchangeAmount(quote.fee, 18), "10");
  assert.equal(exchangeAmount(quote.adjustment, 18), "4");
  assert.equal(quote.gross, quote.fee + quote.adjustment + quote.total);
});

// promise: reserve readiness covers all per-credit royalties and rejects even a one-base-unit shortfall.
await check("full batch reserve", () => {
  const quote = exchangeQuote(market, scores, 50)!;
  assert.equal(exchangeQuote({ ...market, balanceAvailable: quote.total + quote.royalty }, scores, 50)!.reason, undefined);
  assert.match(exchangeQuote({ ...market, balanceAvailable: quote.total + quote.royalty - 1n }, scores, 50)!.reason!, /reserve cannot cover/);
});

// promise: unavailable references, missing wiring, pauses, retirement and an unopened bid cannot enable a sale.
await check("unavailable states", () => {
  assert.equal(exchangeQuote(undefined, scores, 50), undefined);
  assert.equal(exchangeQuote({ ...market, balanceOn: false }, scores, 50), undefined);
  assert.equal(exchangeQuote({ ...market, balanceToken: zeroAddress }, scores, 50), undefined);
  assert.match(exchangeQuote({ ...market, paused: true }, scores, 50)!.reason!, /paused/);
  assert.match(exchangeQuote({ ...market, retired: true }, scores, 50)!.reason!, /retired/);
  assert.match(exchangeQuote({ ...market, settings: { ...market.settings, balanceBidOn: false } }, scores, 50)!.reason!, /not open/);
  assert.match(exchangeQuote({ ...market, value: { on: true } }, scores, 50)!.reason!, /fresh quote/);
  assert.match(exchangeQuote({ ...market, balanceAvailable: undefined }, scores, 50)!.reason!, /unavailable/);
});

const accepted = () => ({
  ids: [4021n, 1187n, 9354n], minOut: 1_105_942_500_000_000_000_000n, token,
  account: "0x0000000000000000000000000000000000000001" as const,
  core: "0xcdb1889ae12074d750CD9B8531B692015465e0dD" as const,
  credits: "0x97630aA70AB14ed9883B41dAfccBc11349723043" as const, chainId: 1,
});

// promise: approval delays cannot silently change the seller's selection, token or accepted minimum.
await check("consent survives approval", async () => {
  const request = accepted();
  const calls: any[] = [];
  const client: any = {
    getChainId: async () => 1,
    readContract: async () => false,
    simulateContract: async (sale: any) => { calls.push({ ...sale, simulated: true }); },
  };
  await sellExchange(client, async (sale) => {
    calls.push(sale);
    if (sale.functionName === "setApprovalForAll") { request.ids.push(999n); request.minOut = 1n; request.token = zeroAddress as any; }
    return "0x123";
  }, request, () => true);
  assert.deepEqual(calls.map((call) => call.functionName), ["setApprovalForAll", "sellForBalance", "sellForBalance"]);
  assert.equal(calls[1].simulated, true);
  assert.deepEqual(calls[2].args, [accepted().ids, accepted().minOut, token]);
  assert.equal(calls[2].account, request.account);
  assert.equal(calls[2].chainId, 1);
});

// promise: approved wallets skip approval; a failed fresh simulation never submits a sale.
await check("fresh simulation failure", async () => {
  let writes = 0;
  const client: any = {
    getChainId: async () => 1, readContract: async () => true,
    simulateContract: async () => { throw new Error("Slippage or ReturnLocked"); },
  };
  await assert.rejects(sellExchange(client, async () => { writes++; return "0x123"; }, accepted(), () => true), /Slippage or ReturnLocked/);
  assert.equal(writes, 0);
});

// promise: an RPC on another chain cannot trigger even a collection approval.
await check("wrong chain", async () => {
  const client: any = { getChainId: async () => 31337 };
  await assert.rejects(sellExchange(client, async () => { throw new Error("must not write"); }, accepted(), () => true), /wrong network/);
});
// promise: changing wallet/network during approval or simulation stops the next sale request.
await check("wallet changes during awaits", async () => {
  for (const when of ["approval", "simulation"]) {
    let current = true;
    const writes: string[] = [];
    const client: any = {
      getChainId: async () => 1, readContract: async () => false,
      simulateContract: async () => { if (when === "simulation") current = false; },
    };
    await assert.rejects(sellExchange(client, async (sale) => {
      writes.push(sale.functionName);
      if (when === "approval") current = false;
      return "0x123";
    }, accepted(), () => current), /Wallet or network changed/);
    assert.deepEqual(writes, ["setApprovalForAll"]);
  }
});

// promise: cancelled/replaced transactions are not successful sales; gas-only speedups remain valid.
await check("replacement receipts", async () => {
  for (const reason of ["cancelled", "replaced", "repriced", undefined]) {
    const client: any = { waitForTransactionReceipt: async (options: any) => {
      if (reason) options.onReplaced({ reason });
      return { status: "success" };
    } };
    const receipt = waitForSuccessfulReceipt(client, "0x123");
    if (reason === "cancelled" || reason === "replaced") await assert.rejects(receipt, /cancelled or replaced/);
    else assert.equal((await receipt).status, "success");
  }
  await assert.rejects(waitForSuccessfulReceipt({ waitForTransactionReceipt: async () => ({ status: "reverted" }) } as any, "0x123"), /reverted/);
});
// promise: a wallet change during gas estimation cannot open another wallet submission request.
await check("wallet change during gas estimate", async () => {
  let current = true;
  let sent = false;
  await assert.rejects(submitWithGasBuffer(async () => { current = false; return 100n; }, async () => { sent = true; return "0x123"; }, () => current), /Wallet or network changed/);
  assert.equal(sent, false);
  let gas = 0n;
  await submitWithGasBuffer(async () => 101n, async (limit) => { gas = limit; return "0x123"; }, () => true);
  assert.equal(gas, 127n);
});
// promise: production and deploy previews cannot expose the route without explicit server configuration.
await check("public route closed by default", () => {
  for (const flag of [undefined, "", "false", "1", "TRUE"]) assert.equal(exchangeEnabled("production", flag), false);
  assert.equal(exchangeEnabled(undefined, undefined), false);
  assert.equal(exchangeEnabled("test", undefined), false);
});

// promise: local development stays usable; a future explicit server opt-in is required for public publication.
await check("development route and explicit publication", () => {
  assert.equal(exchangeEnabled("development", undefined), true);
  assert.equal(exchangeEnabled("development", "false"), true);
  assert.equal(exchangeEnabled("production", "true"), true);
});
console.log(`exchange selfcheck: ${cases} cases passed`);
