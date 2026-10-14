"use client";

import { useHead, useSnapshot } from "@/lib/live";
import { commas, evmNowAddress } from "@/lib/format";
import { core, credits, statements } from "@/lib/config";

export function Footer() {
  const block = useHead().data?.n;
  const snap = useSnapshot().data;
  const contracts = [
    { label: "core", address: core },
    { label: "controller", address: snap?.controller },
    { label: "$CC", address: snap?.coin },
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
