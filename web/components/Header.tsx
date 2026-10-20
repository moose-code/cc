"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useEns } from "@/lib/ens";
import { shortAddr } from "@/lib/format";
import { useBid } from "./EngineFeed";
import { CCLogo } from "./CCLogo";
import { Val } from "./Skeleton";
import { engineDeployed } from "@/lib/config";

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

  if (path === "/exchange") {
    return (
      <header className="header exchange-header">
        <Link href="/" className="brand">
          <CCLogo size={26} autoplay />
          <b>CC</b>
          <span className="brand-sub">credits → $BALANCE</span>
        </Link>
        <WalletButton exchange />
      </header>
    );
  }

  return (
    <header className="header">
      <Link href="/" className="brand">
        <CCLogo size={22} autoplay />
        <b>CC</b>
        <span className={path === "/" ? "brand-sub on" : "brand-sub"}>engine</span>
      </Link>

      {/* mobile: the bid sits in the header bar, left of the menu button */}
      <Bid narrow />

      <button
        className="nav-toggle"
        onClick={() => setOpen((o) => !o)}
        aria-label="menu"
        aria-expanded={open}
      >
        <svg viewBox="0 0 18 18" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" aria-hidden>
          {open ? <path d="M4 4l10 10M14 4L4 14" /> : <path d="M3 5h12M3 9h12M3 13h12" />}
        </svg>
      </button>

      {/* nav, the bid and the wallet; collapse into the hamburger menu on mobile */}
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
        <Bid />
        <WalletButton />
      </div>
    </header>
  );
}

// Disconnected: filled "connect wallet". Connected: outlined button with the
// account's ENS name or short address; opens the account modal.
function WalletButton({ exchange = false }: { exchange?: boolean }) {
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
              <>
                {exchange && <span className="exchange-account"><AccountName address={account.address} /></span>}
                <button className="btn-outline" onClick={openAccountModal}>
                  <i className="sq" />
                  {exchange ? "connected" : <AccountName address={account.address} />}
                </button>
              </>
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

// The current bid per point, beside the wallet on every page; `narrow` is the stacked copy in the mobile header bar.
// Until the snapshot answers the figure is a skeleton of its usual width, so the row does not grow leftward.
function Bid({ narrow }: { narrow?: boolean }) {
  const per1 = useBid();
  return (
    <div className={narrow ? "hdr-next hdr-bid-m" : "hdr-next"}>
      <span className="hdr-next-label">current bid</span>
      <span>
        <b>{engineDeployed ? <Val ready={per1 != null} w="9ch">{per1}</Val> : "—"} ETH</b>
        <span className="hdr-next-label"> / pt</span>
      </span>
    </div>
  );
}
