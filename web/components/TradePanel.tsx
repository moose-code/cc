"use client";

import { useMemo, useState } from "react";
import { useAccount, useBalance, usePublicClient, useReadContract } from "wagmi";
import { formatUnits, maxUint256, parseEther, type Address } from "viem";
import { Act } from "./Act";
import { engineDeployed } from "@/lib/config";
import { useSnapshot } from "@/lib/live";
import { useCcPerEth, useEthUsd, useQuote } from "@/lib/market";
import { erc20Abi, permit2Abi, universalRouterAbi } from "@/lib/abis";
import { V4, buildBuy, buildSell, minOut } from "@/lib/v4";
import { commas, ethShort, tokens, usd } from "@/lib/format";
import type { Write } from "@/lib/tx";

const FEE_BPS = 690; // 6.9% hook skim
const SLIPPAGE_BPS = 100; // 1.0%
const PERMIT2_MAX = (1n << 160n) - 1n;
const PERMIT2_EXP = Number((1n << 48n) - 1n); // uint48 max, viem types as number

// Swap panel of the home page: eth for the coin and back through the v4
// Universal Router. A sell first grants the coin allowance to Permit2 and the
// Permit2 allowance to the router when they are short.
export function TradePanel() {
  const { data: snap } = useSnapshot();
  const coin = snap?.coin;
  const { data: ccPerEth } = useCcPerEth(coin);
  const { data: ethUsd } = useEthUsd();
  const { address } = useAccount();
  const client = usePublicClient();

  // 1 coin in USD = eth per coin * usd per eth. No figure while either read fails.
  const ccUsd = ethUsd != null && ccPerEth ? ethUsd / ccPerEth : undefined;

  const [side, setSide] = useState<"buy" | "sell">("buy");
  const [pay, setPay] = useState("0.50");

  const amount = Number(pay) || 0;
  const amountIn = useMemo(() => {
    try {
      return parseEther(pay || "0"); // eth and the coin both have 18 decimals
    } catch {
      return 0n;
    }
  }, [pay]);

  const { data: quoteOut } = useQuote(coin, side, amountIn);

  // quoted when the pool answers, else spot math
  const spot = ccPerEth ? (side === "buy" ? amount * ccPerEth : amount / ccPerEth) : 0;
  const receive = quoteOut != null ? Number(formatUnits(quoteOut, 18)) : spot;
  const feeEth = side === "buy" ? (amount * FEE_BPS) / 10000 : (receive * FEE_BPS) / 10000;

  const { data: ccBal } = useReadContract({
    address: coin,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(coin && address) },
  });
  const { data: ethBal } = useBalance({ address });

  const { data: erc20Allow } = useReadContract({
    address: coin,
    abi: erc20Abi,
    functionName: "allowance",
    args: address ? [address, V4.permit2] : undefined,
    query: { enabled: Boolean(coin && address && side === "sell") },
  });
  const { data: p2Allow } = useReadContract({
    address: V4.permit2,
    abi: permit2Abi,
    functionName: "allowance",
    args: address && coin ? [address, coin, V4.universalRouter] : undefined,
    query: { enabled: Boolean(coin && address && side === "sell") },
  });
  const needsErc20 = side === "sell" && erc20Allow != null && erc20Allow < amountIn;
  const needsP2 = side === "sell" && p2Allow != null && p2Allow[0] < amountIn;

  async function swap(write: Write) {
    const c = coin as Address;
    if (needsErc20) await write({ address: c, abi: erc20Abi, functionName: "approve", args: [V4.permit2, maxUint256] });
    if (needsP2)
      await write({ address: V4.permit2, abi: permit2Abi, functionName: "approve", args: [c, V4.universalRouter, PERMIT2_MAX, PERMIT2_EXP] });
    const out = minOut(quoteOut as bigint, SLIPPAGE_BPS);
    const call = side === "buy" ? buildBuy(c, amountIn, out) : buildSell(c, amountIn, out);
    // the router checks the deadline against the timestamp of the block that includes the swap
    const next = await client!.getBlock({ blockTag: "pending" }).catch(() => undefined);
    const deadline = (next?.timestamp ?? BigInt(Math.floor(Date.now() / 1000))) + 1200n;
    await write({
      address: V4.universalRouter,
      abi: universalRouterAbi,
      functionName: "execute",
      args: [call.commands, call.inputs, deadline],
      value: call.value,
    });
  }

  const ready = Boolean(coin) && amountIn > 0n && quoteOut != null && quoteOut > 0n;

  return (
    <aside className="trade">
      <div className="price-row">
        <span className="pair">$cc</span>
        <span>{ccUsd != null ? usd(ccUsd) : "—"}</span>
      </div>
      <div className="price-small">
        <div className="r">
          <span>cc / eth</span>
          <span>{ccPerEth ? (1 / ccPerEth).toFixed(9) : "—"}</span>
        </div>
      </div>

      <div className="tabs">
        <button className={side === "buy" ? "active" : ""} onClick={() => setSide("buy")}>
          buy
        </button>
        <button className={side === "sell" ? "active" : ""} onClick={() => setSide("sell")}>
          sell
        </button>
      </div>

      <div className="field">
        <label>
          <span>pay</span>
          <span>
            bal{" "}
            {side === "buy"
              ? `${ethBal ? Number(ethBal.formatted).toFixed(3) : "0"} eth`
              : `${ccBal != null ? tokens(ccBal) : "0"} cc`}
          </span>
        </label>
        <div className="box">
          <input inputMode="decimal" value={pay} onChange={(e) => setPay(e.target.value.replace(/[^0-9.]/g, ""))} />
          <span className="unit">{side === "buy" ? "eth" : "cc"}</span>
        </div>
      </div>

      <div className="field">
        <label>
          <span>receive</span>
          <span>{quoteOut != null ? "quoted" : "estimate"}</span>
        </label>
        <div className="box">
          <span className="out">{side === "buy" ? commas(Math.floor(receive)) : receive.toFixed(5)}</span>
          <span className="unit">{side === "buy" ? "cc" : "eth"}</span>
        </div>
      </div>

      <div className="quote">
        <div className="r">
          <span>rate</span>
          <span>
            <b>1 eth = {ccPerEth ? commas(Math.round(ccPerEth)) : "—"}</b> cc
          </span>
        </div>
        <div className="r">
          <span>fee 6.9%</span>
          <span>{feeEth.toFixed(5)} eth</span>
        </div>
        <div className="r">
          <span>slippage</span>
          <span>1.0%</span>
        </div>
      </div>

      <Act label={`${side} cc`} disabled={!ready} steps={swap} />
      {!engineDeployed && <p className="panel-note">engine not deployed.</p>}

      <div className="balances">
        <div className="r">
          <span>cc</span>
          <span>{ccBal != null ? tokens(ccBal) : "—"}</span>
        </div>
        {ccBal != null && ccUsd != null && (
          <div className="r">
            <span>balance</span>
            <span>{usd(Number(formatUnits(ccBal, 18)) * ccUsd)}</span>
          </div>
        )}
        <div className="r">
          <span>engine</span>
          <span>{snap ? `${ethShort(snap.ethPot)} eth` : "—"}</span>
        </div>
      </div>
    </aside>
  );
}
