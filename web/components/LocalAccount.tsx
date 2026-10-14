"use client";

import { useEffect } from "react";
import { useAccount, useConnect } from "wagmi";
import { localAccounts } from "@/lib/config";
import { shortAddr } from "@/lib/format";

const KEY = "cc:local-account";

// Local mode wallet: connects the mock connector of the saved account (the
// first of the record by default) and switches accounts from a select.
export function LocalAccount() {
  const { connectors, connect } = useConnect();
  const { connector, status } = useAccount();

  const pick = (id: string) => {
    const c = connectors.find((x) => x.id === id);
    if (!c) return;
    try {
      localStorage.setItem(KEY, id);
    } catch {
      /* no storage */
    }
    connect({ connector: c });
  };

  useEffect(() => {
    if (status !== "disconnected" || connectors.length === 0) return;
    let saved: string | null = null;
    try {
      saved = localStorage.getItem(KEY);
    } catch {
      /* no storage */
    }
    pick(connectors.find((c) => c.id === saved)?.id ?? connectors[0].id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [status, connectors]);

  if (localAccounts.length === 0) return <span className="muted">no accounts in the record</span>;
  return (
    <select value={connector?.id ?? ""} onChange={(e) => pick(e.target.value)} aria-label="local account">
      {localAccounts.map((a) => (
        <option key={a.name} value={`local-${a.name}`}>
          {a.name} {shortAddr(a.address)}
        </option>
      ))}
    </select>
  );
}
