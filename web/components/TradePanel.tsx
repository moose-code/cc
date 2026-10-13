"use client";

import { useMemo, useState } from "react";
import {
  useAccount,
  useBalance,
  useReadContract,
  useWriteContract,
} from "wagmi";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import {
  parseEther,
  parseUnits,
  formatUnits,
  maxUint256,
  type Address,
} from "viem";
import { useMarket, useQuote, useEthUsd } from "@/lib/engine";
import { addresses, chain, poolReady } from "@/lib/config";
import { erc20Abi, permit2Abi, universalRouterAbi } from "@/lib/abis";
import { V4, buildBuy, buildSell, minOut } from "@/lib/v4";
import { commas, tokens, ethShort, usd } from "@/lib/format";

const FEE_BPS = 690; // 6.9% v2 skim
const SLIPPAGE_BPS = 100; // 1.0%
const PERMIT2_MAX = (1n << 160n) - 1n;
const PERMIT2_EXP = Number((1n << 48n) - 1n); // uint48 max, viem types as number

export function TradePanel() {
  const { data: market } = useMarket();
  const { data: ethUsd } = useEthUsd();
  const { address, isConnected } = useAccount();
  const { openConnectModal } = useConnectModal();
  const { writeContractAsync, isPending } = useWriteContract();

  // 1 CC in USD = (eth per cc) * (usd per eth) = ethUsd / ccPerEth.
  const ccUsd =
    ethUsd != null && market.ccPerEth > 0 ? ethUsd / market.ccPerEth : undefined;

  const [side, setSide] = useState<"buy" | "sell">("buy");
  const [pay, setPay] = useState("0.50");
  const [err, setErr] = useState<string | null>(null);

  const amount = Number(pay) || 0;
  const amountInWei = useMemo(() => {
    try {
      return side === "buy" ? parseEther(pay || "0") : parseUnits(pay || "0", 18);
    } catch {
      return 0n;
    }
  }, [side, pay]);

  const { data: quoteOut } = useQuote(side, amountInWei);

  // receive: quoted when the pool is live, else spot math.
  const spotReceive =
    side === "buy" ? amount * market.ccPerEth : market.ccPerEth > 0 ? amount / market.ccPerEth : 0;
  const receiveNum =
    quoteOut != null
      ? Number(formatUnits(quoteOut, 18))
      : spotReceive;
  const feeEth = side === "buy" ? (amount * FEE_BPS) / 10000 : (receiveNum * FEE_BPS) / 10000;

  // balances strip + sell approvals
  const { data: ccBal } = useReadContract({
    address: addresses.cc,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(addresses.cc && address) },
  });
  const { data: ethBal } = useBalance({ address });

  const { data: erc20Allow } = useReadContract({
    address: addresses.cc,
    abi: erc20Abi,
    functionName: "allowance",
    args: address ? [address, V4.permit2] : undefined,
    query: { enabled: Boolean(poolReady && address && side === "sell") },
  });
  const { data: p2Allow } = useReadContract({
    address: V4.permit2,
    abi: permit2Abi,
    functionName: "allowance",
    args: address && addresses.cc ? [address, addresses.cc, V4.universalRouter] : undefined,
    query: { enabled: Boolean(poolReady && address && side === "sell") },
  });

  const needsErc20Approve =
    side === "sell" && erc20Allow != null && (erc20Allow as bigint) < amountInWei;
  const needsP2Approve =
    side === "sell" &&
    !needsErc20Approve &&
    p2Allow != null &&
    (p2Allow as readonly [bigint, number, number])[0] < amountInWei;

  const canExecute =
    poolReady && isConnected && amountInWei > 0n && quoteOut != null && quoteOut > 0n;

  async function onAction() {
    setErr(null);
    try {
      if (!addresses.cc) return;
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 1200);

      if (side === "sell" && needsErc20Approve) {
        await writeContractAsync({
          address: addresses.cc,
          abi: erc20Abi,
          functionName: "approve",
          chainId: chain.id,
          args: [V4.permit2, maxUint256],
        });
        return;
      }
      if (side === "sell" && needsP2Approve) {
        await writeContractAsync({
          address: V4.permit2,
          abi: permit2Abi,
          functionName: "approve",
          chainId: chain.id,
          args: [addresses.cc, V4.universalRouter, PERMIT2_MAX, PERMIT2_EXP],
        });
        return;
      }

      const out = minOut(quoteOut as bigint, SLIPPAGE_BPS);
      const call =
        side === "buy"
          ? buildBuy(addresses.cc as Address, amountInWei, out)
          : buildSell(addresses.cc as Address, amountInWei, out);
      await writeContractAsync({
        address: V4.universalRouter,
        abi: universalRouterAbi,
        functionName: "execute",
        chainId: chain.id,
        args: [call.commands, call.inputs, deadline],
        value: call.value,
      });
    } catch (e: any) {
      setErr(e?.shortMessage || e?.message || "transaction failed");
    }
  }

  const actionLabel = isPending
    ? "confirm in wallet…"
    : needsErc20Approve
      ? "approve cc"
      : needsP2Approve
        ? "enable permit2"
        : `${side} cc`;

  return (
    <aside className="trade">
      <div className="price-row">
        <span className="pair">$cc</span>
        <span>{ccUsd != null ? usd(ccUsd) : "—"}</span>
      </div>
      <div className="price-small">
        <div className="r">
          <span>cc / eth</span>
          <span>
            {market.ccPerEth > 0 ? (1 / market.ccPerEth).toFixed(9) : "—"}
          </span>
        </div>
        <div className="r">
          <span>24h</span>
          <span>{"—"}</span>
        </div>
        <div className="r">
          <span>mcap</span>
          <span>{"—"}</span>
        </div>
        <div className="r">
          <span>vol 24h</span>
          <span>{"—"}</span>
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
              ? ethBal
                ? `${Number(ethBal.formatted).toFixed(3)} eth`
                : "0 eth"
              : ccBal != null
                ? `${tokens(ccBal as bigint)} cc`
                : "0 cc"}
          </span>
        </label>
        <div className="box">
          <input
            inputMode="decimal"
            value={pay}
            onChange={(e) => setPay(e.target.value.replace(/[^0-9.]/g, ""))}
          />
          <span className="unit">{side === "buy" ? "eth" : "cc"}</span>
        </div>
      </div>

      <div className="field">
        <label>
          <span>receive</span>
          <span>{quoteOut != null ? "quoted" : poolReady ? "" : "estimate"}</span>
        </label>
        <div className="box">
          <span className="out">
            {side === "buy" ? commas(Math.floor(receiveNum)) : receiveNum.toFixed(5)}
          </span>
          <span className="unit">{side === "buy" ? "cc" : "eth"}</span>
        </div>
      </div>

      <div className="quote">
        <div className="r">
          <span>rate</span>
          <span>
            <b>1 eth = {commas(Math.round(market.ccPerEth))}</b> cc
          </span>
        </div>
        <div className="r">
          <span>fee 6.9%</span>
          <span>{feeEth.toFixed(5)} eth</span>
        </div>
        <div className="r">
          <span>to engine</span>
          <span>{`≈ ${(feeEth * 0.964).toFixed(5)} eth`}</span>
        </div>
        <div className="r">
          <span>slippage</span>
          <span>1.0%</span>
        </div>
      </div>

      {!isConnected ? (
        <button className="action" onClick={openConnectModal}>
          connect wallet
        </button>
      ) : (
        <button
          className="action"
          onClick={onAction}
          disabled={!canExecute && !needsErc20Approve && !needsP2Approve}
          title={!poolReady ? "engine not deployed yet" : undefined}
        >
          {actionLabel}
        </button>
      )}

      {err && <p className="panel-note" style={{ color: "var(--credit)" }}>{err}</p>}

      {!poolReady && (
        <p className="panel-note">
          engine not deployed yet. quotes are illustrative; swaps go live when the
          coin and pool launch on mainnet.
        </p>
      )}

      <div className="balances">
        <div className="r">
          <span>cc</span>
          <span>{ccBal != null ? tokens(ccBal as bigint) : "—"}</span>
        </div>
        {poolReady && ccBal != null && ccUsd != null && (
          <div className="r">
            <span>balance</span>
            <span>{usd(Number(formatUnits(ccBal as bigint, 18)) * ccUsd)}</span>
          </div>
        )}
        <div className="r">
          <span>engine</span>
          <span>{market.balances ? `${ethShort(market.balances.engine)} eth` : "—"}</span>
        </div>
        <div className="r">
          <span>pool</span>
          <span>{"—"}</span>
        </div>
      </div>
    </aside>
  );
}
