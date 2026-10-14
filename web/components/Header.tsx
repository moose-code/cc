"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";

const LOGO_BARS = ["#0a9b41", "#16b6d8", "#f5c400", "#ff0080"];

// feed lives on the logo; keeper sits at the end of the row.
const NAV = [
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
  const active = (href: string) => path.startsWith(href);

  // close the mobile menu on navigation
  useEffect(() => setOpen(false), [path]);

  return (
    <header className="header">
      <Link href="/" className="brand">
        <span className="bars" aria-hidden>
          {LOGO_BARS.map((c, i) => (
            <i key={i} style={{ background: c, height: `${10 + i * 3}px` }} />
          ))}
        </span>
        CC
      </Link>

      <button
        className="nav-toggle"
        onClick={() => setOpen((o) => !o)}
        aria-label="menu"
        aria-expanded={open}
      >
        {open ? "✕" : "☰"}
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
        <div className="connect">
          <ConnectButton showBalance={false} accountStatus="address" chainStatus="none" />
        </div>
      </div>
    </header>
  );
}
