"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useAcquireCandidate } from "@/lib/useAcquire";
import { useEns } from "@/lib/ens";
import { commas, eth, shortAddr } from "@/lib/format";
import { usePotPage } from "./EngineFeed";
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
        <svg viewBox="0 0 18 18" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" aria-hidden>
          {open ? <path d="M4 4l10 10M14 4L4 14" /> : <path d="M3 5h12M3 9h12M3 13h12" />}
        </svg>
      </button>

      {/* nav, pot figures and the wallet; collapse into the hamburger menu on mobile */}
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
        <PotPage />
        <WalletButton />
      </div>
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
              <>
                <Link href="/sell" className="ulink wallet-sell">
                  sell yours →
                </Link>
                <button className="btn-outline" onClick={openAccountModal}>
                  <i className="sq" />
                  <AccountName address={account.address} />
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

// The points the pot covers, the bid per 100 points and the next-listing bar, beside the wallet on every page.
function PotPage() {
  const { pts, per100 } = usePotPage();
  return (
    <div className="hdr-next">
      <span className="hdr-next-label">pot covers</span>
      <b>{pts == null ? "—" : `${commas(pts)} pts`}</b>
      {per100 && <span className="hdr-next-bid">· bid {per100} ETH / 100 pts</span>}
      <NextListing />
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

// The next listing the engine will reach: the cheapest row still above its bid, with its ask and the bid's progress
// toward it (bid / price) in eight cells. Reuses the acquire query, so it adds no reads, and runs on wide screens only.
const NL_CELLS = 8;

function NextListing() {
  return useWide() ? <NextListingBar /> : null;
}

function NextListingBar() {
  const { top } = useAcquireCandidate();
  const n = top.find((t) => BigInt(t.bid) < BigInt(t.price)) ?? top[0];
  if (!n) return null;
  const price = BigInt(n.price);
  const bid = BigInt(n.bid);
  const fill = price > 0n ? Math.min(1, Number((bid * 1000n) / price) / 1000) : 0;
  const on = Math.round(fill * NL_CELLS);
  return (
    <span
      className="hdr-nl"
      title={`credit #${n.id} · listed ${eth(price)} ETH · engine bids ${eth(bid)} ETH (${n.source})`}
    >
      <span className="hdr-next-label">next credit</span>
      <span className="hdr-nl-bar" aria-hidden>
        {Array.from({ length: NL_CELLS }, (_, i) => (
          <i key={i} className={i < on ? "on" : undefined} />
        ))}
      </span>
      <b>{eth(price)} ETH</b>
    </span>
  );
}

