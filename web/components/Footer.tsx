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
        <span>{"independent · not affiliated with credits or artcoins"}</span>
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
