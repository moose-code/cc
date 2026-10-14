"use client";

import { useEffect, useMemo, useState } from "react";
import { useAccount, useBalance, usePublicClient, useReadContract, useReadContracts, useSwitchChain } from "wagmi";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { formatUnits, maxUint256, parseEther, parseEventLogs, parseUnits, zeroAddress, type Address } from "viem";
import { engineDeployed, chain } from "@/lib/config";
import { useCcMarket, useEthUsd, useHookFeeBps, useMarketStats, useQuote, useTokensPerEth, type Market } from "@/lib/market";
import { erc20Abi, permit2Abi, transferEventAbi, universalRouterAbi } from "@/lib/abis";
import { V4, buildBuy, buildSell, minOut } from "@/lib/v4";
import { changePct, commas, evmNowTx, shortHash, tokens, usd, usdCompact, usdPrice } from "@/lib/format";
import { lsGet, lsSet } from "@/lib/cache";
import { CANCELLED, useTx, type Plan, type StepStatus, type Write } from "@/lib/tx";

const HOOK_FEE_BPS = 690; // fallback when the hook reads fail
const SLIPPAGE_PRESETS = [50, 100, 200, 500]; // bps
const SLIPPAGE_KEY = "cc:slippage-bps";
const IMPACT_WARN = 0.02;
const GAS_RESERVE = parseEther("0.01"); // left by "max" for gas
const PERMIT2_MAX = (1n << 160n) - 1n;
const PERMIT2_EXP = Number((1n << 48n) - 1n); // uint48 max, viem types as number

const STEP_TEXT: Record<StepStatus, string> = { todo: "todo", wallet: "confirm in wallet…", pending: "pending", done: "done", failed: "failed" };

// Swap panel: eth for a market's token and back through the v4 Universal
// Router; `market` defaults to the coin. A sell first grants the token
// allowance to Permit2 and the Permit2 allowance to the router when they are short.
export function TradePanel({ market }: { market?: Market }) {
  const cc = useCcMarket();
  const m = market ?? cc;
  const { data: perEth } = useTokensPerEth(m);
  const { data: ethUsd } = useEthUsd();
  const { address, chainId } = useAccount();
  const { openConnectModal } = useConnectModal();
  const { switchChain } = useSwitchChain();
  const client = usePublicClient();
  const { run, pending, err, steps, reset } = useTx();

  const sym = m?.symbol.toLowerCase() ?? "";
  const dec = m?.decimals ?? 18;
  const hooked = m != null && m.key.hooks !== zeroAddress;
  const hookFee = useHookFeeBps(m).data;
  const feeBps = hooked ? hookFee ?? HOOK_FEE_BPS : (m?.key.fee ?? 0) / 100; // LP fee is in hundredths of a bip

  const { priceUsd: tokenUsd, marketCap, change } = useMarketStats(m);

  // slippage tolerance in bps, kept in localStorage; a custom percent is applied once it is within 0.1 to 50
  const [slipBps, setSlipBps] = useState(100);
  const [slipCustom, setSlipCustom] = useState("");
  useEffect(() => {
    const v = Number(lsGet<number>(SLIPPAGE_KEY));
    if (v >= 10 && v <= 5000) {
      setSlipBps(v);
      if (!SLIPPAGE_PRESETS.includes(v)) setSlipCustom(String(v / 100));
    }
  }, []);
  const slipValid = slipCustom !== "" && Number(slipCustom) >= 0.1 && Number(slipCustom) <= 50;
  const pickSlip = (bps: number, custom: string) => {
    setSlipBps(bps);
    setSlipCustom(custom);
    lsSet(SLIPPAGE_KEY, bps);
  };

  const [side, setSide] = useState<"buy" | "sell">("buy");
  const [pay, setPay] = useState("0.50");
  const [result, setResult] = useState<{ text: string; hash: `0x${string}` } | null>(null);
  const [ranMulti, setRanMulti] = useState(false);

  const inDec = side === "buy" ? 18 : dec;
  const outDec = side === "buy" ? dec : 18;
  const amount = Number(pay) || 0;
  const amountIn = useMemo(() => {
    try {
      return parseUnits(pay || "0", inDec);
    } catch {
      return 0n;
    }
  }, [pay, inDec]);

  const quote = useQuote(m, side, amountIn);
  const quoteOut = quote.data;

  // quoted when the pool answers, else spot math
  const spot = perEth ? (side === "buy" ? amount * perEth : amount / perEth) : 0;
  const receive = quoteOut != null ? Number(formatUnits(quoteOut, outDec)) : spot;
  const f = feeBps / 10000;
  const feeEth = side === "buy" ? amount * f : (amount / (perEth || Infinity)) * f;
  // quote against the spot proceeds after the fee
  const impact = quoteOut != null && spot > 0 ? Math.max(0, 1 - receive / (spot * (1 - f))) : undefined;
  const fmtOut = (n: number) => (side === "buy" ? `${commas(Math.floor(n))} ${sym}` : `${n.toFixed(5)} eth`);

  const { data: tokBal } = useReadContract({
    address: m?.token,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(m && address) },
  });
  const { data: ethBal } = useBalance({ address });
  const payBal = side === "buy" ? ethBal?.value : tokBal;

  const { data: allow } = useReadContracts({
    contracts: [
      { address: m?.token, abi: erc20Abi, functionName: "allowance", args: address ? [address, V4.permit2] : undefined },
      { address: V4.permit2, abi: permit2Abi, functionName: "allowance", args: address && m ? [address, m.token, V4.universalRouter] : undefined },
    ],
    query: { enabled: Boolean(m && address && side === "sell") },
  });
  const erc20Allow = allow?.[0].result as bigint | undefined;
  const p2Allow = allow?.[1].result as readonly [bigint, number, number] | undefined;
  const plan: Plan[] =
    side === "buy"
      ? [{ label: "buy" }]
      : [{ label: `approve ${sym}`, done: erc20Allow != null && erc20Allow >= amountIn }, { label: "permit", done: p2Allow != null && p2Allow[0] >= amountIn }, { label: "sell" }];
  const multi = plan.filter((p) => !p.done).length > 1;

  async function swap(write: Write) {
    const t = m!.token as Address;
    if (!plan[0].done && side === "sell") await write({ address: t, abi: erc20Abi, functionName: "approve", args: [V4.permit2, maxUint256] });
    if (!plan[1]?.done && side === "sell")
      await write({ address: V4.permit2, abi: permit2Abi, functionName: "approve", args: [t, V4.universalRouter, PERMIT2_MAX, PERMIT2_EXP] });
    const out = minOut(quoteOut as bigint, slipBps);
    const call = side === "buy" ? buildBuy(m!.key, amountIn, out) : buildSell(m!.key, amountIn, out);
    // the router checks the deadline against the timestamp of the block that includes the swap
    const next = await client!.getBlock({ blockTag: "pending" }).catch(() => undefined);
    const deadline = (next?.timestamp ?? BigInt(Math.floor(Date.now() / 1000))) + 1200n;
    const hash = await write({
      address: V4.universalRouter,
      abi: universalRouterAbi,
      functionName: "execute",
      args: [call.commands, call.inputs, deadline],
      value: call.value,
    });
    // a buy reports the token transferred to the account, a sell the amount sold
    let got = amountIn;
    if (side === "buy") {
      const rc = await client!.getTransactionReceipt({ hash });
      const logs = parseEventLogs({ abi: transferEventAbi, logs: rc.logs, eventName: "Transfer" });
      got = logs.filter((l) => l.address.toLowerCase() === t.toLowerCase() && l.args.to === address).reduce((a, l) => a + l.args.value, 0n) || (quoteOut as bigint);
    }
    setResult({ text: `${side === "buy" ? "bought" : "sold"} ${tokens(got, dec)} ${sym}`, hash });
    setPay("");
  }

  const over = payBal != null && amountIn > payBal;
  const wrongChain = address != null && chainId !== chain.id;
  const gate = !address
    ? { label: "connect wallet", go: openConnectModal }
    : wrongChain
      ? { label: "switch network", go: () => switchChain({ chainId: chain.id }) }
      : amountIn === 0n
        ? { label: "enter an amount", off: true }
        : over
          ? { label: `not enough ${side === "buy" ? "eth" : sym}`, off: true }
          : quote.isLoading
            ? { label: "quoting…", off: true }
            : {
                label: `${side} ${sym}`,
                off: !(quoteOut != null && quoteOut > 0n),
                go: () => {
                  setResult(null);
                  setRanMulti(multi);
                  run(swap, plan);
                },
              };
  const active = steps.find((s) => s.status === "wallet" || s.status === "pending");
  const busy = pending && !result;
  // settled shows "failed" for 1.5 s, then "try again"
  const [settled, setSettled] = useState(false);
  useEffect(() => {
    setSettled(false);
    const t = err && err !== CANCELLED ? setTimeout(() => setSettled(true), 1500) : undefined;
    return () => clearTimeout(t);
  }, [err]);
  const failing = Boolean(err) && err !== CANCELLED && !busy && !("off" in gate && gate.off);
  const label = busy
    ? active?.status === "pending"
      ? active.label === side ? "pending…" : active.label === "permit" ? "permitting…" : "approving…"
      : "confirm in wallet…"
    : result
      ? `✓ ${result.text}`
      : failing
        ? settled ? "try again" : "failed"
        : gate.label;
  // the transaction under the button: the one in flight, the one that failed on chain, or the result
  const txHash = result?.hash ?? steps.find((s) => (s.status === "pending" || s.status === "failed") && s.hash)?.hash;

  // a result belongs to the account that traded
  useEffect(() => {
    setResult(null);
    reset();
  }, [address]); // eslint-disable-line react-hooks/exhaustive-deps

  const edit = (fn: () => void) => {
    fn();
    setResult(null);
    reset();
  };
  const max = () => {
    if (payBal == null) return;
    const v = side === "buy" ? (payBal > GAS_RESERVE ? payBal - GAS_RESERVE : 0n) : payBal;
    edit(() => setPay(formatUnits(v, inDec)));
  };

  const balLine = (bal: bigint | undefined, unit: string, isEth: boolean) => {
    if (bal == null) return null;
    const n = Number(formatUnits(bal, isEth ? 18 : dec));
    const price = isEth ? ethUsd : tokenUsd;
    return (
      <div className="bal">
        bal {isEth ? n.toFixed(3) : tokens(bal, dec)} {unit}
        {price != null && ` · ${usd(n * price)}`}
      </div>
    );
  };

  const shown = steps.length ? steps : plan.map((p) => ({ label: p.label, status: (p.done ? "done" : "todo") as StepStatus, hash: undefined }));

  return (
    <aside className="trade">
      {(marketCap != null || tokenUsd != null) && (
        <dl className="stats">
          {marketCap != null && (
            <div>
              <dt>market cap</dt>
              <dd>{usdCompact(marketCap)}</dd>
            </div>
          )}
          {tokenUsd != null && (
            <div>
              <dt>price</dt>
              <dd>
                {usdPrice(tokenUsd)}
                {change != null && <span className={Math.abs(change) < 0.005 ? "" : change > 0 ? "up" : "down"}>{changePct(change)}</span>}
              </dd>
            </div>
          )}
        </dl>
      )}
      <div className="price-small">
        <div className="r">
          <span>{sym} / eth</span>
          <span>{perEth ? (1 / perEth).toFixed(9) : "—"}</span>
        </div>
      </div>

      <div className="tabs">
        {(["buy", "sell"] as const).map((s) => (
          <button key={s} className={side === s ? "active" : ""} disabled={pending} onClick={() => edit(() => setSide(s))}>
            {s}
          </button>
        ))}
      </div>

      <div className="field">
        <label>
          <span>pay</span>
        </label>
        <div className="box">
          <input
            className={over ? "err" : ""}
            inputMode="decimal"
            disabled={pending}
            value={pay}
            onChange={(e) => edit(() => setPay(e.target.value.replace(/[^0-9.]/g, "")))}
          />
          <button className="max" disabled={pending} onClick={max}>
            max
          </button>
          <span className="unit">{side === "buy" ? "eth" : sym}</span>
        </div>
        {balLine(payBal, side === "buy" ? "eth" : sym, side === "buy")}
      </div>

      <div className="field">
        <label>
          <span>receive</span>
          <span>{quoteOut != null ? "quoted" : "estimate"}</span>
        </label>
        <div className="box">
          <span className="out">{side === "buy" ? commas(Math.floor(receive)) : receive.toFixed(5)}</span>
          <span className="unit">{side === "buy" ? sym : "eth"}</span>
        </div>
        {balLine(side === "buy" ? tokBal : ethBal?.value, side === "buy" ? sym : "eth", side === "sell")}
      </div>

      <div className="quote">
        <div className="r">
          <span>minimum after slippage</span>
          <span>{quoteOut != null ? fmtOut(Number(formatUnits(minOut(quoteOut, slipBps), outDec))) : "—"}</span>
        </div>
        <div className="r slip">
          <span>slippage</span>
          <span>
            {SLIPPAGE_PRESETS.map((p) => (
              <button key={p} className={slipBps === p && slipCustom === "" ? "on" : ""} disabled={pending} onClick={() => pickSlip(p, "")}>
                {p / 100}%
              </button>
            ))}
            <input
              className={slipCustom !== "" ? (slipValid ? "on" : "err") : ""}
              inputMode="decimal"
              placeholder="custom"
              aria-label="custom slippage percent"
              disabled={pending}
              value={slipCustom}
              onChange={(e) => {
                const v = e.target.value.replace(/[^0-9.]/g, "");
                const n = Number(v);
                if (v !== "" && n >= 0.1 && n <= 50) pickSlip(Math.round(n * 100), v);
                else setSlipCustom(v);
              }}
            />
          </span>
        </div>
        <div className="r">
          <span>fee {feeBps / 100}%</span>
          <span>{feeEth.toFixed(5)} eth</span>
        </div>
        <div className="r">
          <span>rate</span>
          <span>
            <b>1 eth = {perEth ? commas(Math.round(perEth)) : "—"}</b> {sym}
          </span>
        </div>
        <div className={`r${impact != null && impact > IMPACT_WARN ? " warn" : ""}`}>
          <span>price impact</span>
          <span>{impact != null ? `${impact > 0 ? "−" : ""}${(impact * 100).toFixed(2)}%` : "—"}</span>
        </div>
      </div>

      {(steps.length ? ranMulti : multi) && (
        <ol className="steps">
          {shown.map((s) => (
            <li key={s.label} className={s.status}>
              <span>{s.label}</span>
              <span>
                {STEP_TEXT[s.status]}
                {s.status === "pending" && s.hash && (
                  <>
                    {" "}
                    <a href={evmNowTx(s.hash)} target="_blank" rel="noreferrer">
                      {shortHash(s.hash)}
                    </a>
                  </>
                )}
              </span>
            </li>
          ))}
        </ol>
      )}

      <button
        className={`action${busy ? " busy" : result ? " ok" : failing && !settled ? " fail" : ""}`}
        disabled={busy || Boolean(result) || ("off" in gate && gate.off)}
        onClick={"go" in gate ? gate.go : undefined}
      >
        {busy && <span className="spin" aria-hidden />}
        {label}
      </button>
      <div className="status">
        <div>
          {txHash && (
            <a href={evmNowTx(txHash)} target="_blank" rel="noreferrer">
              tx {shortHash(txHash)}
            </a>
          )}
        </div>
        <p key={err} className={err ? `err${err === CANCELLED ? " fade" : ""}` : ""}>
          {err}
        </p>
      </div>
      {!engineDeployed && <p className="panel-note">engine not deployed.</p>}
    </aside>
  );
}
