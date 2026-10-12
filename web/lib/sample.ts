// Static sample data for the statements/credits pages. Deterministic so tiles
// and numbers are stable across renders. Replace each getter with an on-chain
// read at wiring time; see web/CONNECTIONS.md for the exact calls.

export type Lane = "eth" | "exit";
export type StatementStatus = "listed" | "sold" | "held";

export interface SampleStatement {
  id: number;
  lane: Lane;
  cost: number; // eth paid for the 80 credits
  ask: number; // current asking price (falling)
  start: number; // listing start price (markup)
  floor: number; // price floor
  composedAgo: number; // seconds since compose
  status: StatementStatus;
  creditIds: number[]; // the 80 composed credit ids
  buyer?: string; // set when sold
}

export interface SampleCredit {
  id: number;
  lane: Lane;
  cost: number; // eth the engine paid at the bid
  statementId: number | null; // the statement it composed into, if any
  boughtAgo: number; // seconds since the engine bought it
}

const round4 = (n: number) => Math.round(n * 1e4) / 1e4;

// 80 credit ids for a statement, deterministic from the id.
function creditIdsFor(sid: number): number[] {
  const base = 40000 + sid * 80;
  return Array.from({ length: 80 }, (_, i) => base + i);
}

export const statements: SampleStatement[] = Array.from({ length: 12 }, (_, i) => {
  const id = 212 - i;
  const cost = round4(0.5 + ((id * 7) % 13) / 100); // 0.50 - 0.62
  const start = round4(cost * 1.5);
  const floor = round4(cost * 0.75);
  // older statements have fallen further toward the floor
  const ask = round4(Math.max(floor, start - (start - floor) * (i / 14)));
  const status: StatementStatus = i === 0 ? "held" : i % 5 === 2 ? "sold" : "listed";
  return {
    id,
    lane: "eth",
    cost,
    ask: status === "sold" ? round4(ask) : ask,
    start,
    floor,
    composedAgo: 60 + i * 1800,
    status,
    creditIds: creditIdsFor(id),
    buyer: status === "sold" ? "0x91ac4df2a1e8b7c3d5f6a9e0b2c4d6e8f0a2c44de".slice(0, 42) : undefined,
  };
});

export const statementSize = 80; // credits composed into one statement
export const nextStatementId = 213; // the statement currently composing

// held credits = the engine's current pile, bought and awaiting the next
// compose. This is the in-progress statement's filled slots.
export const credits: SampleCredit[] = Array.from({ length: 56 }, (_, i) => {
  const id = 48213 - i;
  return {
    id,
    lane: "eth",
    cost: round4(0.0068 + ((id % 7) / 10000)),
    statementId: nextStatementId,
    boughtAgo: 2 + i * 11,
  };
});

export function getStatement(id: number): SampleStatement | undefined {
  return statements.find((s) => s.id === id);
}

export function getCredit(id: number): SampleCredit | undefined {
  return credits.find((c) => c.id === id);
}

export const engineBid = 0.0071; // eth per credit (the rate)
export const enginePot = 8.2; // eth available in the pot to buy credits now

// a connected holder's credits, eligible to sell into the bid (sample).
export const yourSampleCredits: number[] = [51004, 51003, 51002, 51001];
