// Frontend arithmetic and transaction-orchestration checks only; no deployed-contract acceptance or broadcasts.
import assert from "node:assert/strict";
import { zeroAddress } from "viem";
import { waitForSuccessfulReceipt } from "../lib/tx-receipt.ts";
import { submitWithGasBuffer } from "../lib/tx-submit.ts";
import { exchangeEnabled } from "../lib/exchange-access.ts";
import { encodeAbiParameters, encodeEventTopics, type Log } from "viem";
import { treasuryAbi } from "@cc/engine/abis";
import {
  CLAIM_DEADLINE_SECONDS, claimQuote, decodeRedemption, exchangeAmount, exchangeQuote, proRataQuote, redeemClaim, sellExchange,
  type ClaimMarket, type ExchangeMarket,
} from "../lib/exchange.ts";

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

// ---- phase 2 claim panel: burn CC for a share of the claim reserve ------------------------------------------------

const treasury = "0x00000000000000000000000000000000000000d1" as const;
const coin = "0x00000000000000000000000000000000000000c2" as const;
const policy = "0x00000000000000000000000000000000000000e3" as const;
const C = 123_456_789_012_345_678_901n; // claim reserve
const S = 1_000_000n * 10n ** 18n; // CC supply
const x = 12_345n * 10n ** 18n + 7n; // CC burned
const claimMarket = (over: Partial<ClaimMarket> = {}): ClaimMarket => ({
  treasury, balanceToken: token, coin, policy, policyVersion: "pro-rata-v1",
  claimReserve: C, ccSupply: S, freeWorking: 10n ** 18n, conversionToClaimBps: 300, redemptionFeeBps: 25, configEpoch: 4n,
  ccRedemptionEnabled: true, selected: true, transfersReady: true, solvent: true, migrated: false,
  quote: { ccIn: x, balanceOut: proRataQuote(x, C, S, 25), reserve: C, supply: S, epoch: 4n, executable: true },
  ...over,
});

// promise: the quote is floor(x * C / S) less the fee, in full precision, and never above the proportional share.
await check("claim quote matches floor(x*C/S) with fee", () => {
  const gross = (x * C) / S;
  assert.equal(proRataQuote(x, C, S, 0), gross);
  assert.equal(proRataQuote(x, C, S, 25), (gross * 9_975n) / 10_000n);
  assert.equal(proRataQuote(x, C, S, 10_000), 0n);
  assert.equal(proRataQuote(0n, C, S, 0), 0n);
  assert.equal(proRataQuote(S + 1n, C, S, 0), 0n);
  const q = claimQuote(claimMarket(), x, 50)!;
  assert.equal(q.out, (gross * 9_975n) / 10_000n);
  assert.equal(q.fee, gross - q.out);
  assert.equal(q.liveMatchesLocal, true);
  assert.equal(q.backingPerCc, (C * 10n ** 18n) / S);
  assert.equal(q.reason, undefined);
  // the treasury's answer is the quote shown and used; the local arithmetic stands in only until it is read
  const live = claimQuote(claimMarket({ quote: { ccIn: x, balanceOut: 5n, reserve: C, supply: S, epoch: 4n, executable: true } }), x, 0)!;
  assert.equal(live.out, 5n);
  assert.equal(live.liveMatchesLocal, false);
  const unread = claimQuote(claimMarket({ quote: undefined }), x, 0)!;
  assert.equal(unread.out, q.out);
  assert.equal(unread.liveMatchesLocal, undefined);
  assert.equal(claimQuote(undefined, x, 0), undefined);
});

// promise: the minimum is the quote at each tolerance choice, exact, and no other tolerance is accepted.
await check("claim minimum at each slippage choice", () => {
  const out = claimQuote(claimMarket(), x, 0)!.out;
  assert.equal(claimQuote(claimMarket(), x, 0)!.minOut, out);
  assert.equal(claimQuote(claimMarket(), x, 50)!.minOut, (out * 9_950n) / 10_000n);
  assert.equal(claimQuote(claimMarket(), x, 100)!.minOut, (out * 9_900n) / 10_000n);
  for (const bps of [0, 50, 100]) assert.equal(claimQuote(claimMarket(), x, bps)!.out, out);
  assert.throws(() => claimQuote(claimMarket(), x, 25), /Unsupported/);
});

// promise: a closed, unselected, migrated, insolvent or inexecutable treasury, a zero quote and an amount over the
// wallet or the supply disable the burn with a reason.
await check("claim not executable disables", () => {
  const reason = (over: Partial<ClaimMarket>, amount = x, wallet?: bigint) => claimQuote(claimMarket(over), amount, 50, wallet)!.reason!;
  assert.match(reason({ ccRedemptionEnabled: false }), /not open/);
  assert.match(reason({ selected: false }), /no longer/);
  assert.match(reason({ transfersReady: false }), /transfers are not open/);
  assert.match(reason({ solvent: false }), /closed/);
  assert.match(reason({ migrated: true }), /migrated/);
  assert.match(reason({ quote: { ccIn: x, balanceOut: 1n, reserve: C, supply: S, epoch: 4n, executable: false } }), /not executable/);
  assert.match(reason({ quote: { ccIn: x, balanceOut: 0n, reserve: C, supply: S, epoch: 4n, executable: true } }), /zero/);
  assert.match(reason({}, 0n), /Enter an amount/);
  assert.match(reason({}, x, x - 1n), /More CC than this wallet/);
  assert.match(reason({ quote: undefined }, S + 1n), /More CC than the supply/);
  assert.equal(claimQuote(claimMarket({ quote: undefined }), x, 50)!.executable, true);
  assert.equal(claimQuote(claimMarket({ quote: undefined, ccRedemptionEnabled: false }), x, 50)!.executable, false);
});

const acceptedClaim = () => ({
  ccIn: x, minOut: (proRataQuote(x, C, S, 25) * 9_950n) / 10_000n, epoch: 4n, deadline: 1_800_000_000n + BigInt(CLAIM_DEADLINE_SECONDS),
  account: "0x0000000000000000000000000000000000000001" as const, treasury, coin, chainId: 1,
});
const claimClient = (allowance: bigint, quote: readonly [bigint, bigint, bigint, bigint, boolean], calls: any[]) => ({
  getChainId: async () => 1,
  readContract: async (req: any) => req.functionName === "allowance" ? allowance : quote,
  simulateContract: async (req: any) => { calls.push({ ...req, simulated: true }); },
});

// promise: the approval is for exactly the amount entered, and only when the allowance is short.
await check("claim approval only when allowance short", async () => {
  for (const [allowance, approves] of [[x - 1n, true], [x, false], [x + 1n, false]] as const) {
    const calls: any[] = [];
    const write = async (req: any) => { calls.push(req); return "0x123" as const; };
    await redeemClaim(claimClient(allowance, [proRataQuote(x, C, S, 25), C, S, 4n, true], calls) as any, write, acceptedClaim(), () => true);
    const names = calls.map((call) => call.functionName);
    assert.deepEqual(names, approves ? ["approve", "redeemCC", "redeemCC"] : ["redeemCC", "redeemCC"]);
    if (approves) assert.deepEqual(calls[0].args, [treasury, x]);
    const sent = calls[calls.length - 1];
    assert.equal(calls[calls.length - 2].simulated, true);
    assert.deepEqual(sent.args, [x, acceptedClaim().account, acceptedClaim().minOut, acceptedClaim().deadline, 4n]);
    assert.equal(sent.address, treasury);
    assert.equal(sent.chainId, 1);
  }
});

// promise: the pinned epoch, minimum, deadline and amount never change after consent, even when the caller's
// object is mutated during the approval; a changed treasury epoch or a closed treasury stops the burn before any send.
await check("claim epoch pinning rejects a changed epoch", async () => {
  const request = acceptedClaim();
  const calls: any[] = [];
  await redeemClaim(claimClient(0n, [proRataQuote(x, C, S, 25), C, S, 4n, true], calls) as any, async (req: any) => {
    calls.push(req);
    if (req.functionName === "approve") { request.ccIn = 1n; request.minOut = 1n; request.epoch = 9n; request.deadline = 0n; }
    return "0x123";
  }, request, () => true);
  assert.deepEqual(calls[2].args, [x, acceptedClaim().account, acceptedClaim().minOut, acceptedClaim().deadline, 4n]);
  for (const [quote, message] of [
    [[proRataQuote(x, C, S, 25), C, S, 5n, true], /terms changed/],
    [[proRataQuote(x, C, S, 25), C, S, 4n, false], /not executable/],
    [[acceptedClaim().minOut - 1n, C, S, 4n, true], /under your minimum/],
  ] as const) {
    const sent: any[] = [];
    await assert.rejects(redeemClaim(claimClient(x, quote, sent) as any, async (req: any) => { sent.push(req); return "0x123"; }, acceptedClaim(), () => true), message);
    assert.equal(sent.length, 0);
  }
  await assert.rejects(redeemClaim({ getChainId: async () => 31337 } as any, async () => { throw new Error("must not write"); }, acceptedClaim(), () => true), /wrong network/);
  let current = true;
  const writes: string[] = [];
  await assert.rejects(redeemClaim(claimClient(0n, [proRataQuote(x, C, S, 25), C, S, 4n, true], []) as any, async (req: any) => {
    writes.push(req.functionName);
    current = false;
    return "0x123";
  }, acceptedClaim(), () => current), /Wallet or network changed/);
  assert.deepEqual(writes, ["approve"]);
});

// promise: the receipt shows the treasury's own CCRedeemed values, not the quote.
await check("claim receipt decodes CCRedeemed", () => {
  const burner = "0x0000000000000000000000000000000000000001" as const;
  const topics = encodeEventTopics({ abi: treasuryAbi, eventName: "CCRedeemed", args: { burner, recipient: burner } });
  const data = encodeAbiParameters(
    [{ type: "uint256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint64" }],
    [x, 777n, C - 777n, S - x, 4n],
  );
  const log = { address: treasury, topics, data } as unknown as Log;
  const other = { ...log, address: coin } as unknown as Log;
  const decoded = decodeRedemption([other, log], treasury)!;
  assert.equal(decoded.burned, x);
  assert.equal(decoded.received, 777n);
  assert.equal(decoded.claimReserve, C - 777n);
  assert.equal(decoded.ccSupply, S - x);
  assert.equal(decoded.configEpoch, 4n);
  assert.equal(decodeRedemption([other], treasury), undefined);
});
console.log(`exchange selfcheck: ${cases} cases passed`);
