"use client";

import { useEffect, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { fetchIxHealth, ix, IX_MAX_BEHIND, setIxMode } from "@/lib/indexer";
import { engine } from "@/lib/indexer-schema";
import { useHead, useSnapshot } from "@/lib/live";

const QUARANTINE_BLOCKS = 5; // blocks the app stays in chain mode after an indexer query fails

// Decides the app-wide data source (lib/indexer.ts useIxMode) and keeps indexer queries fresh.
//
// Mode: "ix" when the indexer answers a health query, is at most IX_MAX_BEHIND blocks behind the chain head and holds
// as many pile credits as Core.pileSize; "chain" when it is unconfigured, unreachable, behind, inconsistent, or one of
// its queries failed in the last QUARANTINE_BLOCKS blocks. The health query runs once per new chain head.
//
// Freshness: one live query (server-sent events) on the engine's snapshot block, written at every block that holds an
// engine event and every 300 blocks, invalidates the "ix" queries. While the stream is down a new head does.
export function IndexerSync() {
  const qc = useQueryClient();
  const { data: head } = useHead();
  const { data: snap } = useSnapshot();
  const [live, setLive] = useState(false);
  const headSeen = useRef<bigint | undefined>(undefined);
  const badUntil = useRef<bigint>(0n);

  const health = useQuery({
    queryKey: ["ix-health", head?.n?.toString()],
    enabled: Boolean(ix),
    retry: 0,
    staleTime: 0,
    queryFn: fetchIxHealth,
  });

  useEffect(() => {
    if (!ix) return setIxMode("chain");
    if (health.isError) return setIxMode("chain");
    if (!health.data) return; // first health result pending
    const behind = head ? Number(head.n) - health.data.block : 0;
    const consistent = !snap || health.data.held === Number(snap.pileSize);
    const quarantined = head != null && head.n < badUntil.current;
    setIxMode(behind > IX_MAX_BEHIND || !consistent || quarantined ? "chain" : "ix");
  }, [health.data, health.isError, head, snap]);

  // an indexer query that fails (after its retry) puts the app in chain mode for a few blocks
  useEffect(() => {
    return qc.getQueryCache().subscribe((e) => {
      if (e.type === "updated" && e.action.type === "error" && e.query.queryKey[0] === "ix") {
        badUntil.current = (head?.n ?? 0n) + BigInt(QUARANTINE_BLOCKS);
        setIxMode("chain");
      }
    });
  }, [qc, head]);

  useEffect(() => {
    if (!ix) return;
    let last: string | undefined;
    const sub = ix.live(
      (db) => db.select({ b: engine.snapshotBlock }).from(engine).limit(1),
      (rows) => {
        const v = String(rows[0]?.b);
        setLive(true);
        if (last !== undefined && v !== last) qc.invalidateQueries({ queryKey: ["ix"] });
        last = v;
      },
      () => setLive(false)
    );
    return () => sub.unsubscribe();
  }, [qc]);

  useEffect(() => {
    const prev = headSeen.current;
    headSeen.current = head?.n;
    if (ix && !live && prev !== undefined && head?.n !== prev) qc.invalidateQueries({ queryKey: ["ix"] });
  }, [head?.n, live, qc]);

  return null;
}
