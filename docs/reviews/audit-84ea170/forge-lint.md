# forge lint src (forge 1.8.1), counts by rule

| count | rule | note |
|---|---|---|
| 266 | note literal-instead-of-constant | style |
| 34 | warning reentrancy-events | events after external calls; every door is guarded, log order is a consumer concern |
| 30 | warning uninitialized-local | loop counters `uint256 i;` style |
| 29 | warning calls-loop | score reads and transfers per credit, bounded by the batch and the gas cap |
| 25 | warning unsafe-typecast | each site carries a forge-lint disable comment or a checked bound |
| 22 | warning require-revert-in-loop | CreditDrawing capacity checks |
| 18 | warning block-timestamp | the engine is a clock-driven price machine by design |
| 14 | note unused-error | input to the comments and dead code audit |
| 9 | warning reentrancy-no-eth | guarded doors |
| 7 | warning unused-return | `module.call` artist pay, `okPay;` deliberate |
| 6 | warning divide-before-multiply | `(i / COLS) * 1090` grid math, intended integer division |
| 4 | warning non-reentrant-not-first | `onlyOwner nonReentrant` order; both run before the body |
| 4 | warning arbitrary-send-eth | caller payments to `msg.sender`, bounded by the settings |
| 1 | warning weak-prng | CoinRenderer sample by prevrandao, by design (decision 127) |
| 1 | warning incorrect-shift | CreditDrawing.sol:114 `shl(layer, 1)` is `1 << layer` in Yul order, correct; lint heuristic |
| 2 | warning missing-zero-check | renderer constructors take `owner_` unchecked; a zero owner makes `setCore` uncallable (the launch passes the config owner) |

No finding from the linter changed the manual review's conclusions; the unused-error list is folded into the dead code table.
