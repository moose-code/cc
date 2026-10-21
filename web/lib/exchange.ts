import { formatUnits, parseEventLogs, zeroAddress, type Address, type Log, type PublicClient } from "viem";
import { coreAbi, creditsAbi, erc20Abi, treasuryAbi } from "@cc/engine/abis";
import type { Snapshot } from "@cc/engine/snapshot";
import type { Write } from "./tx";
import { replayBalanceFills } from "./sell.ts";

export const EXCHANGE_SLIPPAGE = [0, 50, 100] as const;
export type ExchangeMarket = Pick<Snapshot,
  "balanceOn" | "balanceToken" | "balanceUnit" | "balanceAvailable" | "balanceRate" | "paused" | "retired" | "ethPrice"
> & {
  settings: Pick<Snapshot["settings"], "balanceBidOn" | "buyToArtistBps">;
  value: Pick<Snapshot["value"], "on" | "perPointSell">;
};

export function exchangeQuote(market: ExchangeMarket | undefined, scores: bigint[], slippageBps: number) {
  if (!EXCHANGE_SLIPPAGE.some((bps) => bps === slippageBps)) throw new Error("Unsupported slippage tolerance");
  if (!market?.balanceOn || market.balanceToken === zeroAddress || !market.balanceUnit) return undefined;
  const grossFills = scores.map((score) => score * market.balanceUnit!);
  const posted = grossFills.map((gross) => gross * market.balanceRate / 10_000n);
  const fills = replayBalanceFills(scores, {
    unit: market.balanceUnit,
    rate: market.balanceRate,
    scorePer100Points: 1_000_000n,
    dropPer100PointsBps: 0n,
    dropFloorBps: 0n,
    floorBps: 0n,
    valueModeOn: market.value.on,
    ethPrice: market.ethPrice,
    valueSell: market.value.perPointSell,
  });
  const sum = (values: bigint[]) => values.reduce((total, value) => total + value, 0n);
  const gross = sum(grossFills);
  const total = sum(fills);
  const royalty = sum(fills.map((paid) => paid * BigInt(market.settings.buyToArtistBps) / 10_000n));
  const reason = market.retired ? "This engine has retired."
    : market.paused ? "The exchange is paused."
    : !market.settings.balanceBidOn ? "BALANCE exchange is not open yet."
    : market.value.on && (!market.value.perPointSell || market.ethPrice === 0n) ? "Price protection is waiting for a fresh quote."
    : market.balanceAvailable === undefined ? "The BALANCE reserve is unavailable."
    : fills.some((paid) => paid === 0n) ? "No executable quote. Try again after the reference refreshes."
    : total + royalty > market.balanceAvailable ? "The BALANCE reserve cannot cover this selection. Select fewer Credits or try again later."
    : undefined;
  return {
    fills, grossFills, gross, total, royalty,
    fee: gross - sum(posted),
    adjustment: sum(posted) - total,
    minOut: total * BigInt(10_000 - slippageBps) / 10_000n,
    reason,
  };
}

// Never round the displayed minimum above or below the exact amount encoded in the transaction.
export function exchangeAmount(amount: bigint, decimals: number, precision = decimals) {
  const [whole, fraction = ""] = formatUnits(amount, decimals).split(".");
  const tail = fraction.slice(0, precision).replace(/0+$/, "");
  return whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",") + (tail ? `.${tail}` : "");
}

export async function sellExchange(
  client: Pick<PublicClient, "readContract" | "simulateContract" | "getChainId">,
  write: Write,
  accepted: { ids: bigint[]; minOut: bigint; token: Address; account: Address; core: Address; credits: Address; chainId: number },
  consentIsCurrent: () => boolean,
) {
  // Capture consent before awaiting approval; live polling cannot lower this minimum or replace the selection/token.
  const { minOut, token, account, core, credits, chainId } = accepted;
  const ids = [...accepted.ids];
  const checkConsent = () => { if (!consentIsCurrent()) throw new Error("Wallet or network changed. Review your selection again."); };
  if (!ids.length || new Set(ids).size !== ids.length || minOut <= 0n || token === zeroAddress) throw new Error("Select Credits with a valid BALANCE quote.");
  checkConsent();
  if (await client.getChainId() !== chainId) throw new Error("The RPC is on the wrong network.");
  checkConsent();
  const approved = await client.readContract({ address: credits, abi: creditsAbi, functionName: "isApprovedForAll", args: [account, core] });
  checkConsent();
  if (!approved) await write({ address: credits, abi: creditsAbi, functionName: "setApprovalForAll", args: [core, true], account, chainId });
  checkConsent();
  const sale = { address: core, abi: coreAbi, functionName: "sellForBalance", args: [ids, minOut, token], account } as const;
  // A fresh full-batch simulation after approval checks price, custody, return locks, reserve and royalty together.
  await client.simulateContract(sale);
  checkConsent();
  await write({ ...sale, chainId });
}

// ---- phase 2 claim: burn CC for a share of the treasury's claim reserve ------------------------------------------
//
// The Core's balance module in phase 2 is the Phase2BalanceTreasury (src/adapters/Phase2BalanceTreasury.sol). A burn
// of `ccIn` is paid the redemption policy's quote, capped at the proportional share floor(ccIn * C / S) of the claim
// reserve C over the CC supply S. The owner manages C: fundClaims and allocateToClaims add backing, returnClaimsToWorking
// moves backing to working funds while redemption is paused, and setRedemptionPolicy replaces the quote; the fee,
// the policy, a claim return and a migration advance `configEpoch`, which redeemCC pins. This is a burn for backing,
// not an automatic market purchase.

export const CLAIM_DEADLINE_SECONDS = 20 * 60;
export const PRO_RATA_VERSION = "pro-rata-v1";

// the live quoteRedemption answer for one amount
export type ClaimQuoteRead = { ccIn: bigint; balanceOut: bigint; reserve: bigint; supply: bigint; epoch: bigint; executable: boolean };

export type ClaimMarket = {
  treasury: Address;
  balanceToken: Address;
  coin: Address;
  policy: Address;
  policyVersion?: string;
  claimReserve: bigint;
  ccSupply: bigint;
  freeWorking: bigint;
  conversionToClaimBps: number;
  redemptionFeeBps: number;
  configEpoch: bigint;
  ccRedemptionEnabled: boolean;
  selected: boolean;
  transfersReady: boolean;
  solvent: boolean;
  migrated: boolean;
  // the treasury's own quoteRedemption for the entered amount; undefined until read
  quote?: ClaimQuoteRead;
};

// ProRataRedemptionPolicy.quote: floor(ccIn * reserve / supply) less the fee, full precision in bigint. 0 for an
// input the policy refuses (zero, above the supply, a fee above 10,000)
export function proRataQuote(ccIn: bigint, reserve: bigint, supply: bigint, feeBps: number): bigint {
  if (ccIn <= 0n || supply <= 0n || ccIn > supply || feeBps < 0 || feeBps > 10_000) return 0n;
  const gross = (ccIn * reserve) / supply;
  return (gross * BigInt(10_000 - feeBps)) / 10_000n;
}

// the balance token per 1e18 CC units (one whole CC) the reserve backs, before the fee; 0 without supply
export function backingPerCc(reserve: bigint, supply: bigint): bigint {
  return supply > 0n ? (reserve * 10n ** 18n) / supply : 0n;
}

export function claimQuote(market: ClaimMarket | undefined, ccIn: bigint, slippageBps: number, walletCc?: bigint) {
  if (!EXCHANGE_SLIPPAGE.some((bps) => bps === slippageBps)) throw new Error("Unsupported slippage tolerance");
  if (!market || market.treasury === zeroAddress || market.balanceToken === zeroAddress) return undefined;
  const local = proRataQuote(ccIn, market.claimReserve, market.ccSupply, market.redemptionFeeBps);
  // the treasury's answer for this amount is the quote; the local arithmetic stands in only until it is read, and a
  // policy other than pro-rata-v1 shows its own answer
  const live = market.quote && market.quote.ccIn === ccIn ? market.quote : undefined;
  const out = live ? live.balanceOut : local;
  const reserve = live ? live.reserve : market.claimReserve;
  const supply = live ? live.supply : market.ccSupply;
  const epoch = live ? live.epoch : market.configEpoch;
  const executable = live ? live.executable : market.ccRedemptionEnabled && market.selected && market.transfersReady && market.solvent && !market.migrated;
  const reason = market.migrated ? "This treasury has migrated. Redeem through its successor."
    : !market.selected ? "This treasury is no longer the engine's balance module."
    : !market.ccRedemptionEnabled ? "CC redemption is not open yet."
    : !market.transfersReady ? "BALANCE transfers are not open yet."
    : !market.solvent ? "The treasury does not cover its claim reserve. Redemption is closed."
    : supply === 0n ? "No CC supply."
    : ccIn === 0n ? "Enter an amount of CC to burn."
    : walletCc !== undefined && ccIn > walletCc ? "More CC than this wallet holds."
    : ccIn > supply ? "More CC than the supply."
    : !executable ? "Redemption is not executable now. Try again later."
    : out === 0n ? "The quote is zero for this amount."
    : undefined;
  return {
    ccIn,
    out,
    local,
    // the live quote is authoritative; a mismatch flags a policy that is not pro-rata-v1 or a reserve change
    liveMatchesLocal: live ? live.balanceOut === local : undefined,
    reserve,
    supply,
    epoch,
    executable,
    fee: (() => { const gross = proRataQuote(ccIn, reserve, supply, 0); return gross > out ? gross - out : 0n; })(),
    backingPerCc: backingPerCc(reserve, supply),
    minOut: (out * BigInt(10_000 - slippageBps)) / 10_000n,
    reason,
  };
}

export type ClaimAccepted = {
  ccIn: bigint;
  minOut: bigint;
  epoch: bigint;
  deadline: bigint;
  account: Address;
  treasury: Address;
  coin: Address;
  chainId: number;
};

// The consent flow of a burn, after the pattern of sellExchange: the amount, the minimum, the pinned epoch, the
// deadline and the treasury are captured before any await and never change afterwards. A wallet or network change
// stops the next request. The approval is for exactly ccIn and only when the allowance is short. A fresh
// quoteRedemption after approval refuses a changed epoch, a closed treasury and a quote under the minimum before the
// simulation, so no transaction that would revert StaleEpoch, RedemptionOff or Slippage is sent
export async function redeemClaim(
  client: Pick<PublicClient, "readContract" | "simulateContract" | "getChainId">,
  write: Write,
  accepted: ClaimAccepted,
  consentIsCurrent: () => boolean,
) {
  const { ccIn, minOut, epoch, deadline, account, treasury, coin, chainId } = accepted;
  const checkConsent = () => { if (!consentIsCurrent()) throw new Error("Wallet or network changed. Review your quote again."); };
  if (ccIn <= 0n || minOut <= 0n || treasury === zeroAddress || coin === zeroAddress) throw new Error("Enter an amount of CC with a valid BALANCE quote.");
  checkConsent();
  if (await client.getChainId() !== chainId) throw new Error("The RPC is on the wrong network.");
  checkConsent();
  const allowance = await client.readContract({ address: coin, abi: erc20Abi, functionName: "allowance", args: [account, treasury] });
  checkConsent();
  if (allowance < ccIn) await write({ address: coin, abi: erc20Abi, functionName: "approve", args: [treasury, ccIn], account, chainId });
  checkConsent();
  const [balanceOut, , , liveEpoch, executable] = await client.readContract({ address: treasury, abi: treasuryAbi, functionName: "quoteRedemption", args: [ccIn] });
  checkConsent();
  if (BigInt(liveEpoch) !== epoch) throw new Error("The redemption terms changed since your quote. Review the quote again.");
  if (!executable) throw new Error("Redemption is not executable now. Review the quote again.");
  if (balanceOut < minOut) throw new Error("The live quote is under your minimum. Review the quote again.");
  const burn = { address: treasury, abi: treasuryAbi, functionName: "redeemCC", args: [ccIn, account, minOut, deadline, epoch], account } as const;
  // the simulation after approval checks the burn allowance, the epoch, the switches, solvency and the minimum together
  await client.simulateContract(burn);
  checkConsent();
  return write({ ...burn, chainId });
}

// the CCRedeemed receipt of a burn: what was burned and what was received, from the treasury's own log
export function decodeRedemption(logs: Log[], treasury: Address) {
  const events = parseEventLogs({ abi: treasuryAbi, eventName: "CCRedeemed", logs });
  const own = events.find((e) => e.address.toLowerCase() === treasury.toLowerCase());
  if (!own) return undefined;
  const { burner, recipient, ccIn, balanceOut, claimReserve, ccSupply, configEpoch } = own.args;
  return { burner, recipient, burned: ccIn, received: balanceOut, claimReserve, ccSupply, configEpoch: BigInt(configEpoch) };
}
