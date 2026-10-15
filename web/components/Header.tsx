"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";

const NAV = [
  { href: "/", label: "engine" },
  { href: "/credits", label: "credits" },
  { href: "/statements", label: "statements" },
  { href: "/sell", label: "sell" },
  { href: "/compose", label: "compose" },
  { href: "/balance", label: "balance" },
  { href: "/keeper", label: "keeper" },
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
        <span className="brand-sub">engine</span>
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

      <WalletButton />
    </header>
  );
}

// Disconnected: filled "connect wallet". Connected: short address plus an
// outlined status button that opens the account modal.
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
              <>
                <span className="wallet-addr">{account.displayName}</span>
                <button className="btn-outline" onClick={openAccountModal}>
                  <i className="sq" />
                  connected
                </button>
              </>
            )}
          </div>
        );
      }}
    </ConnectButton.Custom>
  );
}
