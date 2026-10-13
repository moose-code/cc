"use client";

import { useEns } from "@/lib/ens";
import { shortAddr, evmNowAddress } from "@/lib/format";

// Shows the ENS name when one resolves, else a short address. Links to the
// explorer by default. suppressHydrationWarning: the cached name may differ
// between the server render (no cache) and the client's first paint.
export function Addr({
  address,
  link = true,
}: {
  address: string;
  link?: boolean;
}) {
  const ens = useEns(address);
  const label = ens ?? shortAddr(address);
  if (!link) return <span suppressHydrationWarning>{label}</span>;
  return (
    <a
      href={evmNowAddress(address)}
      target="_blank"
      rel="noreferrer"
      suppressHydrationWarning
    >
      {label}
    </a>
  );
}
