"use client";

import { useEffect, useMemo, useState } from "react";
import { useAccount, useBalance, usePublicClient, useReadContract, useReadContracts, useSwitchChain } from "wagmi";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { formatUnits, maxUint256, parseEther, parseEventLogs, parseUnits, zeroAddress, type Address } from "viem";
import { engineDeployed, chain } from "@/lib/config";
import { useCcMarket, potShareBps, useHookFeeBps, useMarketStats, useQuote, useTokensPerEth, type Market } from "@/lib/market";
import { erc20Abi, permit2Abi, transferEventAbi, universalRouterAbi } from "@/lib/abis";
import { V4, buildBuy, buildSell, minOut } from "@/lib/v4";
import { commas, eth, evmNowAddress, evmNowTx, leftLabel, tokens, usd, usdCompact, usdPrice } from "@/lib/format";
import { lsGet, lsSet } from "@/lib/cache";
import { useNow, useSnapshot } from "@/lib/live";
import { CANCELLED, useTx, type Plan, type Write } from "@/lib/tx";

const HOOK_FEE_BPS = 1000; // fallback when the hook reads fail
const SLIPPAGE_PRESETS = [50, 100, 200, 500]; // bps
const SLIPPAGE_KEY = "cc:slippage-bps";
const GAS_RESERVE = parseEther("0.01"); // left by "max" for gas
const PERMIT2_MAX = (1n << 160n) - 1n;
const PERMIT2_EXP = Number((1n << 48n) - 1n); // uint48 max, viem types as number

// Swap panel: eth for a market's token and back through the v4 Universal
// Router; `market` defaults to the coin. A sell first grants the token
// allowance to Permit2 and the Permit2 allowance to the router when they are short.
export function TradePanel({ market }: { market?: Market }) {
  const cc = useCcMarket();
  const m = market ?? cc;
  const { data: perEth } = useTokensPerEth(m);
  const { address, chainId } = useAccount();
  const { switchChain } = useSwitchChain();
  const client = usePublicClient();
  const { openConnectModal } = useConnectModal();
  const snap = useSnapshot().data;
  const { run, pending, err, steps, reset } = useTx();

  const tag = m ? `$${m.symbol.replace(/^\$/, "").toUpperCase()}` : "";
  const dec = m?.decimals ?? 18;
  const hooked = m != null && m.key.hooks !== zeroAddress;
  const hookFee = useHookFeeBps(m).data;
  const now = useNow();
  const feeBps = hooked ? hookFee?.bps ?? HOOK_FEE_BPS : (m?.key.fee ?? 0) / 100; // LP fee is in hundredths of a bip

  const { priceUsd: tokenUsd, ethUsd, marketCap } = useMarketStats(m);

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
  type Result = { kind: "bought" | "sold"; amount: string; usd?: string; paid: string; paidLabel: string; potWei?: bigint; hash: `0x${string}` };
  const [result, setResult] = useState<Result | null>(null);
  const [withApprovals, setWithApprovals] = useState(false); // the running trade includes the approval steps

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
  // usd value of each side: eth x the feed, the token x its usd price
  const inUsd = side === "buy" ? (ethUsd != null ? amount * ethUsd : undefined) : tokenUsd != null ? amount * tokenUsd : undefined;
  const outUsd = side === "buy" ? (tokenUsd != null ? receive * tokenUsd : undefined) : ethUsd != null ? receive * ethUsd : undefined;
  const usdText = (v: number | undefined) => (v == null ? null : amountIn === 0n ? "$0" : usd(v));

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

  // Engine pot share of this trade in wei of ETH. The skim is taken on the ETH side: the input of a buy, the
  // output of a sell (the quote is net of the skim, so it is grossed up). Only the coin's hooked pool pays the engine.
  const potBps = hooked && m?.token === cc?.token && hookFee && snap ? potShareBps(hookFee.engineBps, snap) : 0;
  const potWei = useMemo(() => {
    if (potBps <= 0) return undefined;
    const ethSide = side === "buy" ? amountIn : quoteOut != null ? (quoteOut * 10000n) / BigInt(Math.max(1, 10000 - Math.round(feeBps))) : undefined;
    return ethSide == null ? undefined : (ethSide * BigInt(Math.round(potBps * 100))) / 1_000_000n;
  }, [potBps, side, amountIn, quoteOut, feeBps]);

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
    const gotUsd = side === "buy" ? (tokenUsd != null ? Number(formatUnits(got, dec)) * tokenUsd : undefined) : outUsd;
    setResult({
      kind: side === "buy" ? "bought" : "sold",
      amount: side === "buy" ? tokens(got, dec) : tokens(amountIn, dec),
      usd: side === "buy" ? (gotUsd != null ? usd(gotUsd) : undefined) : inUsd != null ? usd(inUsd) : undefined,
      paid: side === "buy" ? `${eth(amountIn)} ETH` : `~${eth(quoteOut as bigint)} ETH`,
      paidLabel: side === "buy" ? "paid" : "received",
      potWei,
      hash,
    });
    setPay("");
  }

  const over = payBal != null && amountIn > payBal;
  const wrongChain = address != null && chainId !== chain.id;
  const needApprove = side === "sell" && (!plan[0].done || !plan[1].done);
  const approveLabel = !plan[0].done ? `approve ${tag}` : "approve Permit2";
  const gate = !address
    ? { label: "connect wallet", off: !openConnectModal, go: openConnectModal }
    : wrongChain
      ? { label: "switch network", go: () => switchChain({ chainId: chain.id }) }
      : amountIn === 0n
        ? { label: "enter an amount", off: true }
        : over
          ? { label: `not enough ${side === "buy" ? "ETH" : tag}`, off: true }
          : quote.isLoading
            ? { label: "getting quote…", off: true }
            : {
                label: needApprove ? approveLabel : `${side} ${tag}`,
                off: !(quoteOut != null && quoteOut > 0n),
                go: () => {
                  setResult(null);
                  setWithApprovals(needApprove);
                  run(swap, plan);
                },
              };
  const active = steps.find((s) => s.status === "wallet" || s.status === "pending");
  const busy = pending && !result;
  const failed = Boolean(err) && err !== CANCELLED && !busy && !result;
  const quoting = amountIn > 0n && quote.isLoading;
  const inWallet = busy && active?.status === "wallet";
  const swapPending = busy && active?.status === "pending" && active.label === side ? active : undefined;
  const swapIng = side === "buy" ? "buying" : "selling";
  const label = busy
    ? inWallet || !active
      ? "waiting for wallet…"
      : swapPending
        ? `${swapIng}…`
        : "approving…"
    : failed
      ? "try again"
      : gate.label;
  // the transaction of a failed step
  const failedHash = failed ? steps.find((s) => s.status === "failed" && s.hash)?.hash : undefined;

  // submit time of the swap transaction, local clock, set when its status turns pending
  const [sentAt, setSentAt] = useState<{ hash?: string; at: number }>({ at: 0 });
  useEffect(() => {
    if (swapPending?.hash) setSentAt({ hash: swapPending.hash, at: Date.now() });
  }, [swapPending?.hash]);
  const sentSecs = swapPending ? Math.max(0, Math.floor((Date.now() - sentAt.at) / 1000)) : 0;
  const stripFill = Math.min(19, Math.floor((sentSecs / 30) * 20));

  // a result belongs to the account that traded
  useEffect(() => {
    setResult(null);
    reset();
  }, [address]); // eslint-disable-line react-hooks/exhaustive-deps

  const edit = (fn: () => void) => {
    fn();
    setResult(null);
    setWithApprovals(false);
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
  const outText = amountIn === 0n ? "0.00" : side === "buy" ? commas(Math.floor(receive)) : receive.toFixed(5);
  const hasAmount = amountIn > 0n;
  const minText =
    quoteOut == null
      ? "—"
      : side === "buy"
        ? `${tokens(minOut(quoteOut, slipBps), dec)} ${tag}`
        : `${eth(minOut(quoteOut, slipBps))} ETH`;
  const potText = potWei == null ? "—" : `~${eth(potWei)} ETH · ${parseFloat((potBps / 100).toFixed(2))}%`;
  const hashLabel = (h: string) => `${h.slice(0, 6)}…${h.slice(-4)}`;
  const TxLink = ({ h, children }: { h: string; children?: string }) => (
    <a href={evmNowTx(h)} target="_blank" rel="noreferrer">
      {children ?? `${hashLabel(h)} ↗`}
    </a>
  );

  // approval step list: from the running steps, else from the allowance plan
  const stepRows = (() => {
    if (side !== "sell") return [];
    const names = [`approve ${tag}`, "approve Permit2", `sell ${tag}`];
    const st = steps.length === 3 ? steps : plan.map((p) => ({ status: p.done ? "done" : "todo", hash: undefined as `0x${string}` | undefined }));
    let cur = st.findIndex((x) => x.status !== "done");
    if (cur < 0) cur = 2;
    return names.map((name, i) => ({ name, hash: st[i].hash, state: st[i].status === "done" ? "done" : i === cur ? "cur" : "todo" }));
  })();
  const showSteps = side === "sell" && !result && hasAmount && !over && (withApprovals ? steps.length === 3 : needApprove);

  const notice =
    result && result.potWei != null && snap && snap.ethRate > 0n
      ? { tone: "m", title: "your trade fed the engine", body: `${eth(result.potWei)} ETH is now in the pot, enough for about ${(Number(result.potWei) / Number(snap.ethRate)).toFixed(1)} credits at the current bid.` }
      : failed
        ? { tone: "m", title: err as string, body: failedHash ? "the transaction reverted on chain, gas was spent." : "the transaction was not sent." }
        : inWallet
          ? { tone: "c", title: "confirm in your wallet", body: "check the amount and approve the transaction. nothing has been sent yet." }
          : null;

  return (
    <aside className="trade">
      <div className="tp-price">
        <div>
          <div className="label">{tag} price</div>
          <div className="tp-big">{tokenUsd != null ? usdPrice(tokenUsd) : "—"}</div>
        </div>
        <div className="tp-cap">
          {m ? (
            <a className="label" href={evmNowAddress(m.token)} target="_blank" rel="noreferrer" aria-label={`${tag} contract on evm.now`}>
              mkt cap ↗
            </a>
          ) : (
            <div className="label">mkt cap</div>
          )}
          <div className="tp-big sm">{marketCap != null ? usdCompact(marketCap) : "—"}</div>
        </div>
      </div>

      <div className="seg tp-seg">
        {(["buy", "sell"] as const).map((s) => (
          <button key={s} className={side === s ? "on" : ""} disabled={pending} onClick={() => edit(() => setSide(s))}>
            {s}
          </button>
        ))}
      </div>

      {result ? (
        <div className="tp-result">
          <div className="tp-top">
            <span className="label">{result.kind}</span>
            <TxLink h={result.hash} />
          </div>
          <div className="tp-main">
            <span className="num">{result.amount}</span>
            <span className="unit">{tag}</span>
          </div>
          {result.usd && <div className="tp-usd">≈ {result.usd}</div>}
          <div className="tp-rows">
            <div className="tp-row">
              <span>{result.paidLabel}</span>
              <span>{result.paid}</span>
            </div>
            {result.potWei != null && (
              <div className="tp-row">
                <span>to the pot</span>
                <span>~{eth(result.potWei)} ETH</span>
              </div>
            )}
          </div>
        </div>
      ) : (
        <div className={`tp-box${over ? " over" : ""}`}>
          <div className="tp-field">
            <div className="tp-top">
              <span>you pay</span>
              {bal != null && (
                <span>
                  <span className="tp-bal">balance {bal}</span>
                  <button className="max" disabled={pending} onClick={max}>
                    max
                  </button>
                </span>
              )}
            </div>
            <div className="tp-main">
              <input
                inputMode="decimal"
                placeholder="0.00"
                aria-label="amount in"
                disabled={pending}
                value={pay}
                onChange={(e) => edit(() => setPay(e.target.value.replace(/[^0-9.]/g, "")))}
              />
              <span className="unit">{inUnit}</span>
            </div>
            {hasAmount && usdText(inUsd) != null && <div className="tp-usd">≈ {usdText(inUsd)}</div>}
          </div>
          <div className="tp-field">
            <div className="tp-top">
              <span>you receive</span>
              {quoting && <span>quoting…</span>}
            </div>
            <div className="tp-main">
              <span className={`num${!hasAmount || quoting ? " zero" : ""}`}>{outText}</span>
              <span className="unit">{outUnit}</span>
            </div>
            {hasAmount && usdText(outUsd) != null && <div className="tp-usd">≈ {usdText(outUsd)}</div>}
          </div>
        </div>
      )}

      {!result && (
        <div className="tp-rows">
          {hasAmount && potBps > 0 && (
            <div className="tp-row">
              <span>to the pot</span>
              <span>{quoting ? "—" : potText}</span>
            </div>
          )}
          {hasAmount && (
            <div className="tp-row">
              <span>minimum received</span>
              <span>{quoting ? "—" : minText}</span>
            </div>
          )}
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
      )}

      {showSteps && (
        <ol className="tp-steps">
          {stepRows.map((r) => (
            <li key={r.name} className={r.state}>
              <i aria-hidden />
              <span>{r.name}</span>
              {r.hash ? <TxLink h={r.hash} /> : r.state === "cur" && <span className="caption">now</span>}
            </li>
          ))}
        </ol>
      )}

      {swapPending && (
        <div className="tp-pending">
          <div className="tp-line">
            <b>
              {swapIng} {tag}
            </b>
            {swapPending.hash && <TxLink h={swapPending.hash} />}
          </div>
          <div className="tp-strip" aria-hidden>
            {Array.from({ length: 20 }, (_, i) => (
              <i key={i} className={i <= stripFill ? "on" : ""} />
            ))}
          </div>
          <div className="caption">submitted {sentSecs}s ago · usually under 30s</div>
        </div>
      )}

      {notice && (
        <div className={`tp-notice ${notice.tone}`}>
          <b>{notice.title}</b>
          <p>{notice.body}</p>
          {failedHash && (
            <p>
              <TxLink h={failedHash}>{`view reverted tx ${hashLabel(failedHash)} ↗`}</TxLink>
            </p>
          )}
        </div>
      )}

      {result ? (
        <button
          className="action secondary"
          onClick={() => {
            setResult(null);
            setWithApprovals(false);
            reset();
          }}
        >
          trade again
        </button>
      ) : (
        <button
          className="action"
          disabled={busy || ("off" in gate && Boolean(gate.off))}
          onClick={"go" in gate ? gate.go : undefined}
        >
          {label}
        </button>
      )}

      {hookFee?.active ? (
        <div className="tp-fee tp-launch">
          <div className="tp-row">
            <span>LAUNCH FEE {(hookFee.bps / 100).toFixed(1)}%</span>
            {hookFee.endsAt != null && hookFee.endsAt > now && <span>{leftLabel(hookFee.endsAt - now)} left</span>}
          </div>
          {hookFee.perMin != null && (
            <p>
              decays {(hookFee.perMin / 100).toFixed(1)}% per minute until it reaches the base fee of {(hookFee.baseBps / 100).toFixed(1)}%
            </p>
          )}
        </div>
      ) : (
        <p className="tp-fee caption">trading fee {parseFloat((feeBps / 100).toFixed(2))}%</p>
      )}
      {!engineDeployed && <p className="panel-note tp-note">engine not deployed.</p>}
    </aside>
  );
}
