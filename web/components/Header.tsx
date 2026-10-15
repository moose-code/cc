"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useEns } from "@/lib/ens";
import { commas, shortAddr } from "@/lib/format";
import { useNextCredit } from "./EngineFeed";

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
        <span className="logo" aria-hidden>
          <i />
          <i />
          <i />
        </span>
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

      {path !== "/" && <NextCredit />}
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

// Next credit progress beside the wallet; the home page shows it in the rail.
// TODO: acquire button (handoff 2026-10-15 part 3) waits on the owner naming the transaction it sends.
function NextCredit() {
  const { ratio, segs } = useNextCredit();
  return (
    <div className="hdr-next">
      <span className="hdr-next-label">next credit</span>
      <div className="hdr-next-segs" aria-hidden>
        {Array.from({ length: 8 }, (_, i) => (
          <i key={i} className={i < segs ? "on" : undefined} />
        ))}
      </div>
      <b>{ratio == null ? "—" : `${commas(ratio)}%`}</b>
    </div>
  );
}
