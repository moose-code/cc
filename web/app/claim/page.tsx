"use client";

import { useEffect, useRef, useState } from "react";
import { useAccount, useConfig, usePublicClient } from "wagmi";
import { getAccount } from "wagmi/actions";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import type { Address } from "viem";
import { ClaimPanel, type ClaimReceipt } from "@/components/ClaimPanel";
import { chain, engineDeployed } from "@/lib/config";
import {
  CLAIM_DEADLINE_SECONDS, PRO_RATA_VERSION, bpsPercent, claimSliderAmount, claimView, decodeRedemption, exchangeAmount, redeemClaim,
  type ClaimMarket,
} from "@/lib/exchange";
import { useClaimQuote, useNow, useTreasury, type TreasuryInfo } from "@/lib/live";
import { useTx } from "@/lib/tx";

// /claim: burn $CC for a proportional share of the phase 2 treasury's claim reserve. The route's layout gates it
// (CLAIM_ENABLED); this page renders only when the gate is open.
export default function ClaimPage() {
  const { address, isConnected, chainId } = useAccount();
  const account = isConnected ? address : undefined;
  // A wallet or network change discards the old amount and its accepted quote.
  return (
    <div className="claim-page">
      <Claim key={`${address}:${chainId}`} account={account} chainId={chainId} />
    </div>
  );
}

function Claim({ account, chainId }: { account?: Address; chainId?: number }) {
  const client = usePublicClient();
  const config = useConfig();
  const mounted = useRef(true);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  const { openConnectModal } = useConnectModal();
  const now = useNow(1000);
  const treasury = useTreasury(account);
  const [amountBps, setAmountBps] = useState(0);
  const [slippage, setSlippage] = useState(50);
  const [receipt, setReceipt] = useState<ClaimReceipt>();
  // the figures frozen at consent: the market, the quote and the amount shown while the wallet confirms
  const [review, setReview] = useState<{ info: TreasuryInfo; market: ClaimMarket; ccIn: bigint; slippage: number }>();
  const live = treasury.data ?? undefined;
  const info = review?.info ?? live;
  const ccDecimals = info?.coinDecimals ?? 18;
  const ccIn = review?.ccIn ?? claimSliderAmount(info?.walletCc ?? 0n, amountBps);
  const liveQuote = useClaimQuote(review ? undefined : info?.treasury, ccIn);
  const tolerance = review?.slippage ?? slippage;
  const market: ClaimMarket | undefined = review?.market ?? (info && {
    treasury: info.treasury, balanceToken: info.balanceToken, coin: info.coin, policy: info.policy, policyVersion: info.policyVersion,
    claimReserve: info.claimReserve, ccSupply: info.ccSupply, freeWorking: info.freeWorking, working: info.working, available: info.available,
    conversionToClaimBps: info.conversionToClaimBps, redemptionFeeBps: info.redemptionFeeBps, configEpoch: info.configEpoch,
    ccRedemptionEnabled: info.ccRedemptionEnabled, selected: info.selected, transfersReady: info.transfersReady,
    solvent: info.solvent, migrated: info.migrated, quote: liveQuote.data,
  });
  // the switch decides the view: accumulating while CC redemption is off (no action), the claim form once it is on,
  // from the same reads, so the switch needs no second deployment
  const view = claimView(market, ccIn, tolerance, info?.walletCc);
  const accumulating = view?.mode === "accumulating";
  const quote = view?.quote;
  const { run, pending, err } = useTx();
  const bal = (value: bigint | undefined) => value === undefined || info?.balanceDecimals === undefined
    ? "—" : exchangeAmount(value, info.balanceDecimals);
  const cc = (value: bigint | undefined) => value === undefined ? "—" : exchangeAmount(value, ccDecimals);
  const wrongChain = Boolean(account && chainId !== chain.id);
  const quoted = Boolean(quote && !quote.reason && quote.executable && quote.out > 0n && (review || liveQuote.data?.ccIn === ccIn));
  const status = pending ? "Your amount, minimum, deadline and redemption terms are held while you confirm in your wallet."
    : !engineDeployed ? "The exchange is not configured."
    : treasury.error ? "Unable to read the treasury. Please try again."
    : !info ? "Reading the treasury…"
    : accumulating ? view.status
    : !account ? "Connect your wallet to burn $CC."
    : wrongChain ? `Switch your wallet to ${chain.name} to burn $CC.`
    : amountBps > 0 && ccIn === 0n ? "This wallet balance is too small for that slider position."
    : quote?.reason ?? (ccIn > 0n && !liveQuote.data ? "Reading the quote…" : undefined);
  const blocked = !account || wrongChain || !info || !view?.actionEnabled || !quote || !quoted || quote.minOut <= 0n || Boolean(treasury.error);
  const label = pending ? "confirming burn…" : ccIn === 0n ? "enter an amount to burn" : "burn $CC for BALANCE";

  async function burn() {
    if (blocked || pending || !account || !client || !info || !market || !quote) return;
    // consent: every value the transaction carries is fixed here, before any await
    const accepted = {
      ccIn, minOut: quote.minOut, epoch: quote.epoch, deadline: BigInt(now + CLAIM_DEADLINE_SECONDS),
      account, treasury: info.treasury, coin: info.coin, chainId: chain.id,
    };
    setReceipt(undefined);
    setReview({ info, market: { ...market }, ccIn, slippage: tolerance });
    const consentIsCurrent = () => {
      const current = getAccount(config);
      return mounted.current && current.address === account && current.chainId === chain.id;
    };
    await run(async (write) => {
      const hash = await redeemClaim(client, write, accepted, consentIsCurrent);
      // the receipt's own CCRedeemed log is the record of what was burned and received
      const rc = await client.getTransactionReceipt({ hash });
      const done = decodeRedemption(rc.logs, info.treasury);
      if (done) setReceipt({ burned: cc(done.burned), received: bal(done.received), hash });
      setAmountBps(0);
    }, [], consentIsCurrent);
    setReview(undefined);
  }

  const notice = !engineDeployed ? "The exchange is not configured."
    : treasury.data === null ? "The engine's balance module is not a phase 2 treasury yet. $CC burns open once the treasury is selected."
    : undefined;
  return <ClaimPanel
    notice={notice}
    redemptionOpen={!accumulating}
    treasury={info?.treasury ?? "—"}
    balanceToken={info?.balanceToken ?? "—"}
    balanceSymbol={info?.balanceSymbol ?? "$BALANCE"}
    policy={info?.policy ?? "—"}
    policyVersion={info?.policyVersion ?? "unknown version"}
    policyIsProRata={info?.policyVersion === PRO_RATA_VERSION}
    claimReserve={bal(info?.claimReserve)}
    freeWorking={bal(info?.freeWorking)}
    available={bal(info?.available)}
    ccSupply={cc(info?.ccSupply)}
    ccSymbol="$CC"
    contributionRate={info ? bpsPercent(info.conversionToClaimBps) : "—"}
    feeRate={info ? bpsPercent(info.redemptionFeeBps) : "—"}
    backingPerCc={bal(quote?.backingPerCc ?? (info ? (info.ccSupply > 0n ? (info.claimReserve * 10n ** 18n) / info.ccSupply : 0n) : undefined))}
    walletCc={cc(info?.walletCc)}
    connected={Boolean(account)}
    amount={cc(ccIn)}
    amountBps={amountBps}
    onAmountChange={(value) => { setReceipt(undefined); setAmountBps(value); }}
    quoted={bal(quoted ? quote?.out : undefined)}
    minimum={bal(quoted ? quote?.minOut : undefined)}
    preview={bal(view?.mode === "accumulating" ? view.preview : undefined)}
    liveMismatch={quote?.liveMatchesLocal === false}
    slippageBps={tolerance}
    onSlippageChange={setSlippage}
    busy={pending}
    status={status}
    error={err ?? undefined}
    receipt={receipt}
    onReset={() => { setReceipt(undefined); setAmountBps(0); }}
    action={accumulating ? undefined
      : !account ? <button type="button" onClick={openConnectModal}>connect wallet</button>
      : <button type="button" disabled={blocked || pending} onClick={burn}>{label}</button>}
  />;
}
