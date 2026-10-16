// The daily budget ledger and the revert loop breaker. The ledger counts, per UTC day, the gas the keeper's wallet
// spent and the payments the Core sent it; the budget caps the net loss (spent minus received). A send is allowed only
// when its own gross cost fits the remaining budget, as if it were not paid. The ledger is a JSON file per day under
// STATE_DIR; it holds amounts and hashes only.

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Door } from "./config.ts";

export interface Day {
  day: string;
  spent: bigint;
  received: bigint;
  txs: number;
}

export const utcDay = (ms: number) => new Date(ms).toISOString().slice(0, 10);

export class Ledger {
  private d: Day;
  private dir: string | undefined;
  private budget: bigint;
  private now: () => number;
  constructor(
    dir: string | undefined,
    budget: bigint,
    now: () => number = Date.now,
  ) {
    this.dir = dir;
    this.budget = budget;
    this.now = now;
    this.d = this.load(utcDay(this.now()));
  }

  private path(day: string) {
    return this.dir ? join(this.dir, `ledger-${day}.json`) : undefined;
  }

  private load(day: string): Day {
    const p = this.path(day);
    try {
      if (p) {
        const j = JSON.parse(readFileSync(p, "utf8"));
        return { day, spent: BigInt(j.spent), received: BigInt(j.received), txs: Number(j.txs) };
      }
    } catch {}
    return { day, spent: 0n, received: 0n, txs: 0 };
  }

  private today(): Day {
    const day = utcDay(this.now());
    if (this.d.day !== day) this.d = this.load(day);
    return this.d;
  }

  // the net loss still allowed today
  remaining(): bigint {
    const d = this.today();
    const net = d.spent - d.received;
    return this.budget > net ? this.budget - net : 0n;
  }

  allows(cost: bigint): boolean {
    return cost <= this.remaining();
  }

  record(spent: bigint, received: bigint, hash: string) {
    const d = this.today();
    d.spent += spent;
    d.received += received;
    d.txs += 1;
    const p = this.path(d.day);
    if (p) {
      mkdirSync(this.dir!, { recursive: true });
      writeFileSync(p, JSON.stringify({ day: d.day, spent: d.spent.toString(), received: d.received.toString(), txs: d.txs, last: hash }) + "\n");
    }
  }

  snapshot(): Day {
    return { ...this.today() };
  }
}

// counts consecutive failures of a door (a sent transaction that reverted, a send no relay took, a receipt that never
// came); at `threshold` the door pauses for `pauseSec` and the breaker reports a trip once. a success resets the count
export class Breaker {
  private fails = new Map<Door, number>();
  private until = new Map<Door, number>();
  private threshold: number;
  private pauseSec: number;
  private now: () => number;
  constructor(
    threshold: number,
    pauseSec: number,
    now: () => number = Date.now,
  ) {
    this.threshold = threshold;
    this.pauseSec = pauseSec;
    this.now = now;
  }

  paused(d: Door): boolean {
    return (this.until.get(d) ?? 0) > this.now();
  }

  pausedUntil(d: Door): number | undefined {
    return this.paused(d) ? this.until.get(d) : undefined;
  }

  // true when this failure trips the breaker
  fail(d: Door): boolean {
    const n = (this.fails.get(d) ?? 0) + 1;
    this.fails.set(d, n);
    if (n >= this.threshold) {
      this.fails.set(d, 0);
      this.until.set(d, this.now() + this.pauseSec * 1000);
      return true;
    }
    return false;
  }

  ok(d: Door) {
    this.fails.set(d, 0);
  }
}
