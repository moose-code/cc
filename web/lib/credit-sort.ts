// Sort orders of the credits the engine holds (the credits page grid and table). Pure functions over values the page
// reads; a value not known yet (a price not read, a band without sales) sorts last in either direction.

export type SortKey = "value" | "price" | "ppp" | "rating" | "newest" | "composing" | "paid";
export type Dir = 1 | -1; // 1 ascending

export interface SortDef {
  key: SortKey;
  label: string; // the select's option
  dir: Dir; // the direction a pick starts in
}

// Best value leads: a credit priced low against what its band trades for is what a buyer looks for first.
export const SORTS: SortDef[] = [
  { key: "value", label: "best value", dir: 1 },
  { key: "price", label: "price", dir: 1 },
  { key: "ppp", label: "price / pt", dir: 1 },
  { key: "rating", label: "rating", dir: -1 },
  { key: "newest", label: "newest", dir: -1 },
  { key: "composing", label: "composing soon", dir: 1 },
  { key: "paid", label: "paid", dir: 1 },
];
export const DEFAULT_SORT: SortKey = "value";
export const sortDef = (k: SortKey): SortDef => SORTS.find((s) => s.key === k) ?? SORTS[0];

export interface SortRow {
  id: number;
  index: number; // queue position, 0 composes first
  price: bigint; // 0 while not read
  cost: bigint;
  acquiredAt: number;
  score?: bigint;
  median?: bigint; // its band's 7-day median paid
}

// The sort value of a row, undefined when not known yet.
function valueOf(r: SortRow, k: SortKey): number | undefined {
  switch (k) {
    case "value":
      return r.price > 0n && r.median != null && r.median > 0n ? Number(r.price) / Number(r.median) : undefined;
    case "price":
      return r.price > 0n ? Number(r.price) : undefined;
    case "ppp":
      return r.price > 0n && r.score != null && r.score > 0n ? Number(r.price) / Number(r.score) : undefined;
    case "rating":
      return r.score != null ? Number(r.score) : undefined;
    case "newest":
      return r.acquiredAt;
    case "composing":
      return r.index;
    case "paid":
      return Number(r.cost);
  }
}

// Rows in the order of `k` and `dir`; unknown values last, ties newest first, then by id.
export function sortRows<T extends SortRow>(rows: T[], k: SortKey, dir: Dir): T[] {
  return [...rows].sort((a, b) => {
    const x = valueOf(a, k), y = valueOf(b, k);
    if (x == null || y == null) {
      if (x != null) return -1;
      if (y != null) return 1;
    } else if (x !== y) return (x < y ? -1 : 1) * dir;
    return b.acquiredAt - a.acquiredAt || b.id - a.id;
  });
}

// The next sort after a click on a column of key `k`: the same key flips its direction, another starts in its own.
export const nextSort = (cur: { key: SortKey; dir: Dir }, k: SortKey): { key: SortKey; dir: Dir } =>
  cur.key === k ? { key: k, dir: (cur.dir === 1 ? -1 : 1) as Dir } : { key: k, dir: sortDef(k).dir };
