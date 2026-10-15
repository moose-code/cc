"use client";

import { useEffect, useState } from "react";
import { useHead, useSnapshot } from "@/lib/live";
import { lsGet, lsSet } from "@/lib/cache";
import { commas, evmNowAddress } from "@/lib/format";
import { core, credits, statements } from "@/lib/config";

const THEME_KEY = "cc:theme"; // read before first paint by the script in app/layout.tsx
const THEMES = ["auto", "light", "dark"] as const;
type Theme = (typeof THEMES)[number];

// auto removes data-theme so the CSS follows prefers-color-scheme.
function ThemeControl() {
  const [theme, setTheme] = useState<Theme>("auto");
  useEffect(() => {
    const t = lsGet<Theme>(THEME_KEY);
    if (t && THEMES.includes(t)) setTheme(t);
  }, []);
  const pick = (t: Theme) => {
    setTheme(t);
    lsSet(THEME_KEY, t);
    if (t === "auto") delete document.documentElement.dataset.theme;
    else document.documentElement.dataset.theme = t;
  };
  return (
    <div className="seg" role="group" aria-label="theme">
      {THEMES.map((t) => (
        <button key={t} className={theme === t ? "on" : ""} aria-pressed={theme === t} onClick={() => pick(t)}>
          {t}
        </button>
      ))}
    </div>
  );
}

export function Footer() {
  const block = useHead().data?.n;
  const snap = useSnapshot().data;
  const contracts = [
    { label: "core", address: core },
    { label: "controller", address: snap?.controller },
    { label: "cc", address: snap?.coin },
    { label: "credits", address: credits },
    { label: "statements", address: statements },
  ].filter((c): c is { label: string; address: `0x${string}` } => Boolean(c.address) && Boolean(core));
  return (
    <footer className="footer">
      <span>{block ? `block ${commas(Number(block))}` : "block —"}</span>

      <div className="footer-right">
        {contracts.length > 0 && (
          <span className="contracts">
            contracts:{" "}
            {contracts.map((c) => (
              <a
                key={c.label}
                href={evmNowAddress(c.address)}
                target="_blank"
                rel="noreferrer"
              >
                {c.label}
              </a>
            ))}
          </span>
        )}
        <span>{"independent · not affiliated with credits"}</span>
        <ThemeControl />
        <span>
          by{" "}
          <a href="https://x.com/ripe0x" target="_blank" rel="noreferrer">
            ripe
          </a>
        </span>
      </div>
    </footer>
  );
}
