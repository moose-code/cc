// Browser cache for chain data that does not change once mined: decoded logs,
// block timestamps, compose modes, settings snapshots and token art. Values are
// JSON in localStorage under one versioned scope per chain + core + deploy block.
// Every storage access is guarded; without storage the in-memory copies still apply.

import { chain, core, deployBlock } from "./config";

export const SCOPE = `cc:v2:${chain.id}:${(core ?? "none").toLowerCase()}:${deployBlock ?? "head"}`;

// bigint <-> {"$b":"123"}
const replacer = (_: string, v: unknown) => (typeof v === "bigint" ? { $b: v.toString() } : v);
const reviver = (_: string, v: any) => (v && typeof v === "object" && typeof v.$b === "string" ? BigInt(v.$b) : v);

export function lsGet<T>(key: string): T | undefined {
  try {
    const s = localStorage.getItem(key);
    return s == null ? undefined : (JSON.parse(s, reviver) as T);
  } catch {
    return undefined;
  }
}

// maxChars skips values larger than the limit, so a large entry cannot fill the quota other keys share.
export function lsSet(key: string, val: unknown, maxChars = Infinity) {
  try {
    const s = JSON.stringify(val, replacer);
    if (s.length <= maxChars) localStorage.setItem(key, s);
  } catch {
    /* storage full or unavailable */
  }
}

// Map whose entries survive reloads: loaded on first use, saved 1 s after the last set.
const maps: { reset(): void }[] = [];

export function persistedMap<V>(name: string) {
  const key = `${SCOPE}:${name}`;
  let m: Map<string, V> | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const load = () => (m ??= new Map(Object.entries(lsGet<Record<string, V>>(key) ?? {})));
  const api = {
    get: (k: string) => load().get(k),
    set(k: string, v: V) {
      load().set(k, v);
      clearTimeout(timer);
      timer = setTimeout(() => lsSet(key, Object.fromEntries(m!)), 1000);
    },
    reset() {
      m = new Map();
      clearTimeout(timer);
    },
  };
  maps.push(api);
  return api;
}

// Drops everything stored for this scope (a different chain history under the same addresses).
export function clearScope() {
  try {
    for (let i = localStorage.length - 1; i >= 0; i--) {
      const k = localStorage.key(i);
      if (k?.startsWith(`${SCOPE}:`)) localStorage.removeItem(k);
    }
  } catch {
    /* storage unavailable */
  }
  for (const m of maps) m.reset();
}

// The cache is trusted when the chain still holds the block recorded as its anchor.
// An anvil restart or a shorter chain fails the check and the scope is cleared. Runs once per page load.
const ANCHOR = `${SCOPE}:anchor`;
let verified: Promise<void> | undefined;

export function verifyScope(client: { getBlock(a: { blockNumber: bigint }): Promise<{ hash: string | null }> }): Promise<void> {
  return (verified ??= (async () => {
    const a = lsGet<{ n: bigint; hash: string }>(ANCHOR);
    if (!a) return;
    const b = await client.getBlock({ blockNumber: a.n }).catch(() => undefined);
    if (b?.hash !== a.hash) clearScope();
  })());
}

export const setAnchor = (n: bigint, hash: string) => lsSet(ANCHOR, { n, hash });
