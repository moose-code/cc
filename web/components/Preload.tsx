"use client";

import { useEffect, useState } from "react";
import { useComposeEta } from "./ComposeEta";
import { useMarketAsks, useMarketReport, useStatementIndex, useStats } from "@/lib/data";
import { usePile, useScores, useStatements } from "@/lib/live";

// Warms the shared query cache with the data /credits and /statements open on, by running their own hooks (same query
// keys) once the home page has settled, so a first visit renders without skeletons. The hooks stay mounted for
// WARM_MS, long enough for the reads to land, then unmount so their refetch intervals do not run from the home page;
// the cached results outlive the unmount (react-query keeps unused data for five minutes).
const DELAY_MS = 1500;
const WARM_MS = 15_000;

export function Preload() {
  const [phase, setPhase] = useState<"wait" | "warm" | "done">("wait");
  useEffect(() => {
    const start = setTimeout(() => setPhase("warm"), DELAY_MS);
    const stop = setTimeout(() => setPhase("done"), DELAY_MS + WARM_MS);
    return () => {
      clearTimeout(start);
      clearTimeout(stop);
    };
  }, []);
  return phase === "warm" ? <Warm /> : null;
}

function Warm() {
  const { data: pile } = usePile();
  useScores(pile.map((c) => BigInt(c.id)));
  useComposeEta(pile, 15000);
  useMarketReport();
  useMarketAsks();
  useStatements();
  useStatementIndex();
  useStats();
  return null;
}
