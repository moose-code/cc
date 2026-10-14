"use client";

import { useEffect, useMemo, useState } from "react";
import { useAccount, useBalance, usePublicClient, useReadContract, useReadContracts, useSwitchChain } from "wagmi";
import { formatUnits, maxUint256, parseEther, parseEventLogs, parseUnits, zeroAddress, type Address } from "viem";
import { engineDeployed, chain } from "@/lib/config";
import { readPots, useCcMarket, useHookFeeBps, useMarketStats, useQuote, useTokensPerEth, type Market, type Pots } from "@/lib/market";
import { erc20Abi, permit2Abi, transferEventAbi, universalRouterAbi } from "@/lib/abis";
import { V4, buildBuy, buildSell, minOut } from "@/lib/v4";
import { changePct, commas, evmNowAddress, evmNowTx, shortHash, tokens, usdCompact, usdPrice } from "@/lib/format";
import { lsGet, lsSet } from "@/lib/cache";
import { CANCELLED, useTx, type Plan, type Write } from "@/lib/tx";

const HOOK_FEE_BPS = 690; // fallback when the hook reads fail
const SLIPPAGE_PRESETS = [50, 100, 200, 500]; // bps
const SLIPPAGE_KEY = "cc:slippage-bps";
const IMPACT_WARN = 0.02;
const GAS_RESERVE = parseEther("0.01"); // left by "max" for gas
const PERMIT2_MAX = (1n << 160n) - 1n;
const PERMIT2_EXP = Number((1n << 48n) - 1n); // uint48 max, viem types as number
const GROW_MS = 1200;

const ethNum = (wei: bigint) => Number(formatUnits(wei, 18));

// Pot before and after a swap, animated from the first to the second:
// "pot a -> b eth" counts up, the bar shows (pot mod bid) / bid and wraps when
// the pot crosses a credit. `bid` is 0n for a pot without a bid (the balance pot).
function PotGrowth({ from, to, label }: { from: { pot: bigint; bid: bigint }; to: { pot: bigint; bid: bigint }; label: string }) {
  const [t, setT] = useState(0);
  useEffect(() => {
    const t0 = performance.now();
    let id = requestAnimationFrame(function tick(now) {
      const k = Math.min(1, (now - t0) / GROW_MS);
      setT(1 - (1 - k) ** 3);
      if (k < 1) id = requestAnimationFrame(tick);
    });
    return () => cancelAnimationFrame(id);
  }, []);
  const lerp = (a: bigint, b: bigint) => ethNum(a) + (ethNum(b) - ethNum(a)) * t;
  const pot = lerp(from.pot, to.pot);
  const bid = lerp(from.bid, to.bid);
  const credits = bid > 0 ? pot / bid : 0;
  return (
    <div className="tp-pot">
      <div className="tp-row">
        <span>{label}</span>
        <span>
          {ethNum(from.pot).toFixed(4)} → <b>{pot.toFixed(4)}</b> eth
        </span>
      </div>
      {bid > 0 && (
        <>
          <div className="tp-row">
            <span>next credit</span>
            <span>
              covers {Math.floor(credits)} {Math.floor(credits) === 1 ? "credit" : "credits"}
            </span>
          </div>
          <div className="tp-bar">
            <i style={{ width: `${(credits - Math.floor(credits)) * 100}%` }} />
          </div>
        </>
      )}
    </div>
  );
}

// Swap panel: eth for a market's token and back through the v4 Universal
// Router; `market` defaults to the coin. A sell first grants the token
// allowance to Permit2 and the Permit2 allowance to the router when they are short.
export function TradePanel({ market }: { market?: Market }) {
  const cc = useCcMarket();
  const m = market ?? cc;
  const isBalance = market != null;
  const { data: perEth } = useTokensPerEth(m);
  const { address, chainId } = useAccount();
  const { switchChain } = useSwitchChain();
  const client = usePublicClient();
  const { run, pending, err, steps, reset } = useTx();

  const tag = m ? `$${m.symbol.replace(/^\$/, "").toUpperCase()}` : "";
  const dec = m?.decimals ?? 18;
  const hooked = m != null && m.key.hooks !== zeroAddress;
  const hookFee = useHookFeeBps(m).data;
  const feeBps = hooked ? hookFee ?? HOOK_FEE_BPS : (m?.key.fee ?? 0) / 100; // LP fee is in hundredths of a bip

  const { priceUsd: tokenUsd, marketCap, change } = useMarketStats(m);

  // slippage tolerance in bps, kept in localStorage; a custom percent is applied once it is within 0.1 to 50
  const [slipBps, setSlipBps] = useState(100);
  const [slipCustom, setSlipCustom] = useState("");
  const [slipOpen, setSlipOpen] = useState(false);
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
  const [pay, setPay] = useState(""); // empty reads as 0
  const [result, setResult] = useState<{ text: string; hash: `0x${string}` } | null>(null);
  const [growth, setGrowth] = useState<{ from: Pots; to: Pots } | null>(null);

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
  // quote against the spot proceeds after the fee
  const impact = quoteOut != null && spot > 0 ? Math.max(0, 1 - receive / (spot * (1 - f))) : undefined;

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
      : [{ label: `approve ${tag}`, done: erc20Allow != null && erc20Allow >= amountIn }, { label: "permit", done: p2Allow != null && p2Allow[0] >= amountIn }, { label: "sell" }];

  // the pot shown after a swap: the engine pot with its bid, or the balance pot
  const potOf = (p: Pots) => (isBalance ? { pot: p.balancePot, bid: 0n } : { pot: p.pot, bid: p.bid });

  async function swap(write: Write) {
    const t = m!.token as Address;
    const before = await readPots(client!).catch(() => undefined);
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
    setResult({ text: `${side === "buy" ? "bought" : "sold"} ${tokens(got, dec)} ${tag}`, hash });
    setPay("");
    // the block shows once the pot moved
    const after = before && (await readPots(client!).catch(() => undefined));
    if (before && after && potOf(before).pot !== potOf(after).pot) setGrowth({ from: before, to: after });
  }

  const over = payBal != null && amountIn > payBal;
  const wrongChain = address != null && chainId !== chain.id;
  const gate = !address
    ? { label: "connect wallet", off: true } // the header's connect button is the way in
    : wrongChain
      ? { label: "switch network", go: () => switchChain({ chainId: chain.id }) }
      : amountIn === 0n
        ? { label: "enter an amount", off: true }
        : over
          ? { label: `insufficient ${side === "buy" ? "ETH" : tag}`, off: true }
          : quote.isLoading
            ? { label: "quoting…", off: true }
            : {
                label: `${side} ${tag}`,
                off: !(quoteOut != null && quoteOut > 0n),
                go: () => {
                  setResult(null);
                  setGrowth(null);
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
    setGrowth(null);
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
  const closeSlip = () => setSlipOpen(false);

  const inUnit = side === "buy" ? "ETH" : tag;
  const outUnit = side === "buy" ? tag : "ETH";
  const bal = payBal != null ? (side === "buy" ? Number(formatUnits(payBal, 18)).toFixed(4) : tokens(payBal, dec)) : null;
  const outText = amountIn === 0n ? "0" : side === "buy" ? commas(Math.floor(receive)) : receive.toFixed(5);

  return (
    <aside className="trade">
      <div className="tp-head">
        <h2>{tag}</h2>
        {m && (
          <a href={evmNowAddress(m.token)} target="_blank" rel="noreferrer" aria-label={`${tag} contract on evm.now`}>
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden>
              <path d="M5 11 11 5M6 5h5v5" />
            </svg>
          </a>
        )}
      </div>

      {(marketCap != null || tokenUsd != null) && (
        <dl className="tp-stats">
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

      <div className="tp-tabs">
        {(["buy", "sell"] as const).map((s) => (
          <button key={s} className={side === s ? "active" : ""} disabled={pending} onClick={() => edit(() => setSide(s))}>
            {s}
          </button>
        ))}
      </div>

      <div className={`tp-card${over ? " err" : ""}`}>
        <div className="tp-top">
          <span>in</span>
          {bal != null && (
            <span>
              balance {bal}
              <button className="max" disabled={pending} onClick={max}>
                max
              </button>
            </span>
          )}
        </div>
        <div className="tp-main">
          <input
            inputMode="decimal"
            placeholder="0"
            aria-label="amount in"
            disabled={pending}
            value={pay}
            onChange={(e) => edit(() => setPay(e.target.value.replace(/[^0-9.]/g, "")))}
          />
          <span className="unit">{inUnit}</span>
        </div>
      </div>

      <div className="tp-card">
        <div className="tp-top">
          <span>out</span>
        </div>
        <div className="tp-main">
          <span className={`num${amountIn === 0n ? " zero" : ""}`}>{outText}</span>
          <span className="unit">{outUnit}</span>
        </div>
      </div>

      <div className="tp-rows">
        <div className={`tp-row${impact != null && impact > IMPACT_WARN ? " warn" : ""}`}>
          <span>price impact</span>
          <span>{impact != null ? `${impact > 0 ? "−" : ""}${(impact * 100).toFixed(2)}%` : "—"}</span>
        </div>
        <button className="tp-row" disabled={pending} aria-expanded={slipOpen} onClick={() => setSlipOpen(!slipOpen)}>
          <span>slippage</span>
          <span>
            {slipBps / 100}% {slipOpen ? "▴" : "▾"}
          </span>
        </button>
        {slipOpen && (
          <div className="tp-opts">
            {SLIPPAGE_PRESETS.map((p) => (
              <button
                key={p}
                className={slipBps === p && slipCustom === "" ? "on" : ""}
                onClick={() => {
                  pickSlip(p, "");
                  closeSlip();
                }}
              >
                {p / 100}%
              </button>
            ))}
            <input
              className={slipCustom !== "" ? (slipValid ? "on" : "err") : ""}
              inputMode="decimal"
              placeholder="custom"
              aria-label="custom slippage percent"
              value={slipCustom}
              onChange={(e) => {
                const v = e.target.value.replace(/[^0-9.]/g, "");
                const n = Number(v);
                if (v !== "" && n >= 0.1 && n <= 50) pickSlip(Math.round(n * 100), v);
                else setSlipCustom(v);
              }}
              onKeyDown={(e) => e.key === "Enter" && slipValid && closeSlip()}
              onBlur={() => slipValid && closeSlip()}
            />
          </div>
        )}
      </div>

      <button
        className={`action${busy ? " busy" : result ? " ok" : failing && !settled ? " fail" : ""}`}
        disabled={busy || Boolean(result) || ("off" in gate && gate.off)}
        onClick={"go" in gate ? gate.go : undefined}
      >
        {busy && <span className="spin" aria-hidden />}
        {label}
      </button>
      {(txHash || err) && (
        <div className="tp-status">
          {txHash && (
            <a href={evmNowTx(txHash)} target="_blank" rel="noreferrer">
              tx {shortHash(txHash)}
            </a>
          )}
          {err && (
            <p key={err} className={`err${err === CANCELLED ? " fade" : ""}`}>
              {err}
            </p>
          )}
        </div>
      )}
      <p className="tp-fee">trading fee {parseFloat((feeBps / 100).toFixed(2))}%</p>
      {growth && <PotGrowth key={growth.to.pot.toString()} from={potOf(growth.from)} to={potOf(growth.to)} label="pot" />}
      {!engineDeployed && <p className="panel-note tp-note">engine not deployed.</p>}
    </aside>
  );
}
