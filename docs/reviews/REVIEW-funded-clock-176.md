# Funded ETH bid clock: adversarial coverage

2026-10-18. Branch `codex/funded-climb-clock`, based on main `08e2102a05f721196f264fe01ebe03f5bf45a188`. Decisions 176 and 177. All chain tests below ran on a local chain-id-1 fork at block 26,219,768; no mainnet broadcast.

## Claims and probes

| Surface | Adversarial case | Evidence |
|---|---|---|
| Bid clock | A booked pot one wei below the 100-point bid plus royalty cannot earn climb; crossing the exact threshold starts it. Zero artist royalty and maximum allowed 1,000 bps royalty, minimum and maximum launch rate, and elapsed empty hours are exercised | `test/BidRule.t.sol`, 31 passed |
| Market path | Listings rise to 1.5x and 2x, then fall to 0.5x after the pot drains and refills. Above-bid orders are refused; an accepted order pays its quote; the bid drops after a fill and remains bounded by room and cap | `test/BidRule.t.sol`, included in 31 passed |
| Reserve page transitions | Compose at 240 Credits lowers the reserve; adopt at 239 raises it; controller sale of the 240th Credit lowers it. Empty hours do not become funded hours, and funded climb earned before a reserve rise survives | `test/Reserve.t.sol`, 9 passed |
| Paid processing | Reference refresh can drain room to the reserve without losing already-earned climb or earning later empty hours | `test/ValueMode.t.sol`, 43 passed including this case |
| Intake and outflow callers | ETH/balance intake, adopted Credits, chosen compose, credit sales, redemption and Seaport listing routes continue under the changed checkpoint order | Focused caller run: 89 passed, 1 obsolete adopt assertion failed; after updating that assertion, `test/Adopt.t.sol` passed 12/12. The failed assertion had required no checkpoint on adopt, contrary to decision 176. |
| Keeper | A zero-price Seaport order beside a valid order cannot divide by zero and stop every candidate evaluation. Hashless orders are also skipped | `node --test keeper/test/listings.test.ts`: 1 passed; keeper typecheck passed |
| Indexer | A failed snapshot read is retried at the same height; a rolled-back snapshot is rebuilt for the replacement block | `node --test indexer/src/lib/snapshot-gate.test.ts`: 2 passed; indexer typecheck passed |
| Web | Pending fee income is included in executable buying room while only booked ETH advances the clock. A one-wei shortfall remains short with large bigint values | `npm run check --workspace web` passed; web TypeScript check passed |
| Build and gas | Pinned bytecode and EIP-170 margins, one-Credit and 86-Credit ETH sells, and gas caps | `test/BuildIdentity.t.sol`: 6 passed; `test/GasCap.t.sol`: 13 passed. Core 24,556 bytes (20 below EIP-170), CoreLib 24,543 (33 below), ControllerV1 17,189. One-Credit ETH sell estimated 520,386 gas; 86-Credit batch 16,499,537 under 16,777,216 cap. |

The system already has fuzz and invariant tests for spend caps, round trips, quote outages, false-return royalty tokens, return locks, reentry, compose and redeem solvency, migration, and value-reference manipulation. This change does not reinterpret a passing test as proof of market fairness: the Core cannot see every listing, and an already-funded quiet period can still move the ceiling toward the owner-editable 3x hard cap. A direct seller can accept the posted bid when outside asks have fallen. The owner chose to preserve the gradual ceiling, per-fill drop and dynamic cap; the new rule removes only the climb earned while the booked pot cannot pay the 100-point threshold.

## Release limits

This is focused change verification, not candidate acceptance. The full `CANDIDATE_RUN=1` suite, invariants 21/21b, local end-to-end rehearsal, and a combined coinless web/keeper/indexer smoke must run on a frozen candidate. Production services and alert endpoints cannot be verified against a deferred mainnet Core until that Core exists. No mainnet transaction was sent.
