"use client";

import { useEffect, useState } from "react";
import { usePublicClient } from "wagmi";
import type { Address } from "viem";
import { isLocal } from "./config";

// ENS reverse lookup with a persistent cache. Resolved names (and misses) are
// kept in localStorage forever so we never re-hit the RPC for the same address
// across reloads (per the project's RPC discipline). A name that changes later
// goes stale; acceptable for display.

const mem = new Map<string, string | null>();
const key = (a: string) => `ens:${a.toLowerCase()}`;

function readCache(a: string): string | null | undefined {
  const k = a.toLowerCase();
  if (mem.has(k)) return mem.get(k);
  try {
    const raw = localStorage.getItem(key(a));
    if (raw != null) {
      const v = raw === "" ? null : raw;
      mem.set(k, v);
      return v;
    }
  } catch {
    /* no storage */
  }
  return undefined;
}

function writeCache(a: string, name: string | null) {
  mem.set(a.toLowerCase(), name);
  try {
    localStorage.setItem(key(a), name ?? "");
  } catch {
    /* no storage */
  }
}

export function useEns(address?: string): string | null {
  const client = usePublicClient();
  const [name, setName] = useState<string | null>(null);

  useEffect(() => {
    if (!address || isLocal) {
      setName(null);
      return;
    }
    const cached = readCache(address);
    if (cached !== undefined) {
      setName(cached);
      return;
    }
    let alive = true;
    (async () => {
      try {
        const n = client
          ? await client.getEnsName({ address: address as Address })
          : null;
        if (!alive) return;
        writeCache(address, n ?? null);
        setName(n ?? null);
      } catch {
        if (alive) {
          writeCache(address, null);
          setName(null);
        }
      }
    })();
    return () => {
      alive = false;
    };
  }, [address, client]);

  return name;
}
