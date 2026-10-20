"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { useHead } from "@/lib/live";
import { lsGet, lsSet } from "@/lib/cache";
import { commas } from "@/lib/format";
import { Val } from "./Skeleton";

const THEME_KEY = "cc:theme"; // read before first paint by the script in app/layout.tsx
const THEMES = ["auto", "light", "dark"] as const;
type Theme = (typeof THEMES)[number];

const THEME_ICON: Record<Theme, React.ReactNode> = {
  // half-filled circle: follow the system
  auto: (
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3" aria-hidden>
      <circle cx="8" cy="8" r="6" />
      <path d="M8 2a6 6 0 000 12z" fill="currentColor" stroke="none" />
    </svg>
  ),
  light: (
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" aria-hidden>
      <circle cx="8" cy="8" r="3" />
      <path d="M8 1.5v1.5M8 13v1.5M1.5 8H3M13 8h1.5M3.4 3.4l1 1M11.6 11.6l1 1M12.6 3.4l-1 1M4.4 11.6l-1 1" />
    </svg>
  ),
  dark: (
    <svg viewBox="0 0 16 16" fill="currentColor" aria-hidden>
      <path d="M6.2 2.3A6 6 0 108 14a6 6 0 01-1.8-11.7z" />
    </svg>
  ),
};

// One icon button cycling auto -> light -> dark. The default is light; auto removes data-theme so the CSS follows
// prefers-color-scheme.
function ThemeControl() {
  const [theme, setTheme] = useState<Theme>("light");
  useEffect(() => {
    const t = lsGet<Theme>(THEME_KEY);
    if (t && THEMES.includes(t)) setTheme(t);
  }, []);
  const cycle = () => {
    const t = THEMES[(THEMES.indexOf(theme) + 1) % THEMES.length];
    setTheme(t);
    lsSet(THEME_KEY, t);
    if (t === "auto") delete document.documentElement.dataset.theme;
    else document.documentElement.dataset.theme = t;
  };
  return (
    <button className="theme-toggle" aria-label={`theme: ${theme}`} title={`theme: ${theme}`} onClick={cycle}>
      {THEME_ICON[theme]}
    </button>
  );
}

export function Footer() {
  const block = useHead().data?.n;
  return (
    <footer className="footer">
      <span>independent tool · not affiliated with Credits</span>
      <span>
        block <Val ready={block != null} w="10ch">{block != null && commas(Number(block))}</Val>
      </span>
      <Link href="/faq">faq</Link>
      <Link href="/docs">docs</Link>
      <span>
        by{" "}
        <a href="https://x.com/ripe0x" target="_blank" rel="noreferrer">
          ripe
        </a>
      </span>
      <div className="footer-right">
        <ThemeControl />
        <a className="credits-link" href="https://jack.art/credits/" target="_blank" rel="noreferrer">
          credits
          <span className="plates" aria-hidden>
            <i className="c" />
            <i className="m" />
            <i className="y" />
            <i className="k" />
          </span>
        </a>
      </div>
    </footer>
  );
}
