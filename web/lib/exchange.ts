import { formatUnits, zeroAddress, type Address, type PublicClient } from "viem";
import { coreAbi, creditsAbi } from "@cc/engine/abis";
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
