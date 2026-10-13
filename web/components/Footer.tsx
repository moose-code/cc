"use client";

import { useBlockNumber } from "wagmi";
import { commas, evmNowAddress } from "@/lib/format";
import { contracts } from "@/lib/config";

export function Footer() {
  const { data: block } = useBlockNumber({ watch: true });
  return (
    <footer className="footer">
      <span>{block ? `block ${commas(Number(block))}` : "block —"}</span>

      <div className="footer-right">
        {contracts.length > 0 && (
          <span className="contracts">
            contracts:{" "}
            {contracts.map((c) => {
              const href = evmNowAddress(c.address);
              return href ? (
                <a key={c.label} href={href} target="_blank" rel="noreferrer">
                  {c.label}
                </a>
              ) : (
                <span key={c.label} title={c.address}>
                  {c.label} {c.address}
                </span>
              );
            })}
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
