"use client";

import type { ReactNode } from "react";
import { Addr } from "./Addr";
import { useBlockTs } from "@/lib/engine";
import { useNow } from "@/lib/live";
import { agoLabel, evmNowTx } from "@/lib/format";

// One history line. The time is the block's timestamp, linked to the transaction.
export function HistRow({
  label,
  value,
  note,
  block,
  tx,
  addr,
}: {
  label: string;
  value: ReactNode;
  note?: string;
  block?: bigint;
  tx?: string;
  addr?: string;
}) {
  const now = useNow();
  const { data: ts } = useBlockTs(block);
  const ago = ts != null ? agoLabel(now - ts) : undefined;
  return (
    <div className="hrow">
      <span className="hlabel">{label}</span>
      <span className="hval">
        {value}
        {note && <span className="muted"> ({note})</span>}
        {addr && (
          <>
            {" by "}
            <Addr address={addr} />
          </>
        )}
      </span>
      {ago && (
        <span className="muted hago" suppressHydrationWarning>
          {tx ? (
            <a href={evmNowTx(tx)} target="_blank" rel="noreferrer">
              {ago}
            </a>
          ) : (
            ago
          )}
        </span>
      )}
    </div>
  );
}
