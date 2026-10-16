"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useAcquireCandidate, useAcquireTx } from "@/lib/useAcquire";
import { useEns } from "@/lib/ens";
import { commas, eth, evmNowTx, shortAddr } from "@/lib/format";
import { useNextCredit } from "./EngineFeed";
import { CCLogo } from "./CCLogo";

const NAV = [
  { href: "/credits", label: "credits" },
  { href: "/statements", label: "statements" },
];

export function Header() {
  const path = usePathname();
  const [open, setOpen] = useState(false);
  const active = (href: string) => (href === "/" ? path === "/" : path.startsWith(href));

  // close the mobile menu on navigation
  useEffect(() => setOpen(false), [path]);

  return (
    <header className="header">
      <Link href="/" className="brand">
        <CCLogo size={22} autoplay />
        <b>CC</b>
        <span className={path === "/" ? "brand-sub on" : "brand-sub"}>engine</span>
      </Link>

      <button
        className="nav-toggle"
        onClick={() => setOpen((o) => !o)}
        aria-label="menu"
        aria-expanded={open}
      >
        {open ? "✕" : "≡"}
      </button>

      {/* nav + connect collapse into the hamburger menu on mobile */}
      <div className={`menu${open ? " open" : ""}`}>
        <nav className="nav">
          {NAV.map((n) => (
            <Link
              key={n.href}
              href={n.href}
              className={active(n.href) ? "on" : undefined}
            >
              {n.label}
            </Link>
          ))}
        </nav>
      </div>

      {path === "/" ? (
        <div className="hdr-next">
          <Acquire />
        </div>
      ) : (
        <NextCredit />
      )}
      <WalletButton />
    </header>
  );
}

// Disconnected: filled "connect wallet". Connected: outlined button with the
// account's ENS name or short address; opens the account modal.
function WalletButton() {
  return (
    <ConnectButton.Custom>
      {({ account, chain, mounted, openAccountModal, openChainModal, openConnectModal }) => {
        const ready = mounted;
        const connected = ready && account && chain;
        return (
          <div className={ready ? "wallet" : "wallet pending"} aria-hidden={!ready}>
            {!connected ? (
              <button className="btn-fill" onClick={openConnectModal}>
                <span className="wide">connect wallet</span>
                <span className="narrow">connect</span>
              </button>
            ) : chain.unsupported ? (
              <button className="btn-fill btn-warn" onClick={openChainModal}>
                wrong network
              </button>
            ) : (
              <button className="btn-outline" onClick={openAccountModal}>
                <i className="sq" />
                <AccountName address={account.address} />
              </button>
            )}
          </div>
        );
      }}
    </ConnectButton.Custom>
  );
}

// ENS name from the cached reverse lookup in lib/ens.ts, else the short address
function AccountName({ address }: { address: string }) {
  return <>{useEns(address) ?? shortAddr(address)}</>;
}

// Next credit progress, the bid at refScore and the acquire button beside the wallet. The home page shows the
// progress in the rail, so its header holds the acquire button alone.
function NextCredit() {
  const { ratio, segs, bid } = useNextCredit();
  return (
    <div className="hdr-next">
      <span className="hdr-next-label">next credit</span>
      <div className="hdr-next-segs" aria-hidden>
        {Array.from({ length: 8 }, (_, i) => (
          <i key={i} className={i < segs ? "on" : undefined} />
        ))}
      </div>
      <b>{ratio == null ? "—" : `${commas(ratio)}%`}</b>
      {bid != null && <span className="hdr-next-bid">· bid {eth(bid)} ETH</span>}
      <Link href="/listings" className="hdr-next-bid">
        listings →
      </Link>
      <Acquire />
    </div>
  );
}

// True from the desktop breakpoint of the header (the indicator is hidden below it); keeps the acquire queries off on phones.
function useWide() {
  const [wide, setWide] = useState(false);
  useEffect(() => {
    const m = window.matchMedia("(min-width: 861px)");
    const f = () => setWide(m.matches);
    f();
    m.addEventListener("change", f);
    return () => m.removeEventListener("change", f);
  }, []);
  return wide;
}

function Acquire() {
  return useWide() ? <AcquireButton /> : null;
}

// Buys the listing that clears (price at or below its bid and the pot) through Core.buyListing. The call is
// simulated right before sending; a revert drops that listing for the block and the next one is tried.
function AcquireButton() {
  const { cleared, block } = useAcquireCandidate();
  const { buy, available, pending, err, done } = useAcquireTx(block);
  const next = available(cleared)[0];

  if (done)
    return (
      <a className="hdr-acq-done" href={evmNowTx(done.hash)} target="_blank" rel="noreferrer">
        acquired #{done.id.toString()} ↗
      </a>
    );
  if (!next) return err ? <span className="hdr-acq-err">{err}</span> : null;
  return (
    <>
      {err && <span className="hdr-acq-err">{err}</span>}
      <button
        className="hdr-acq"
        onClick={() => buy(cleared)}
        disabled={pending}
        title={`credit #${next.id} bids ${eth(next.bid)} ETH (${next.source})`}
      >
        <i aria-hidden />
        {pending ? "acquiring…" : `acquire · ${eth(next.price)} ETH`}
      </button>
    </>
  );
}
