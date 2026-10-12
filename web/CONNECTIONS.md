# connection points

Every place the statements/credits pages use sample data or a disabled action,
and the on-chain call that replaces it at wiring time. Grep the code for
`CONNECT:` to find the same notes inline.

Sample data lives in `lib/sample.ts` — swap its getters for reads, the pages
stay the same. Reads should follow the project's RPC discipline: indexer first,
then cache, then RPC; `CoreLens.snapshot()` returns most of this in one call.

## statements index — `app/statements/page.tsx`

- **list** — `statements` → `CoreLens.snapshot().statements` (held + listed) and
  sold statements from `StatementSoldTo` logs. Fields per statement: `id`,
  `lane`, `cost`, `askingPrice`, `composedAt`, status.
- **status** — derive: held (in Core, not listed) / listed / sold (has a
  `StatementSoldTo`).
- **filter/sort** — the all/for-sale/sold control is not built yet.

## statement detail — `app/statements/[id]/page.tsx`

- **load** — `getStatement(id)` → `CoreLens.statementsPage` / `snapshot` by id,
  else 404.
- **price** — `ask` is static; poll `ControllerV1.priceOf(id)` (falling price).
  Show start/floor from the sale settings (`markupBps`, `floorBps`).
- **buy** (disabled button) — `ControllerV1.buy(id)` payable at `priceOf(id)`
  (or the Core buy path). Need: live price, slippage/exact value, wallet
  balance check, tx state.
- **composed credits** — `creditIds` is synthesized; use the real compose record
  from the Core.

## credits index — `app/credits/page.tsx`

- **list** — `credits` → the engine's held pile. Count is
  `CoreLens.snapshot().ethPileSize`; enumerate ids from `CreditBought` logs or
  the credits NFT `balanceOf(Core)` + enumeration.
- **bid** — `engineBid` → `snapshot().ethRate` (wei per credit).

## credit detail — `app/credits/[id]/page.tsx`

- **load** — `getCredit(id)`; a held credit comes from the pile, a composed one
  maps to its statement.
- **sell to engine** (disabled button) — `Core.sellForEth([id])` pays the bid
  (`ethRate`); or `buyListing` when the engine takes a listed credit. Gate on
  who owns the credit (only the owner can sell). Need: the bid, min out, owner
  check, tx state.
- **paid by engine** — real `cost` from the `CreditBought` event.

## already wired (for reference)

- header stats, engine feed, next-credit / next-statement bars — `lib/engine.ts`
  (live when `CORE`/`CORE_LENS` set, sample otherwise).
- trade panel price/quote/swap — `lib/v4.ts` (live when `CC` set, `poolReady`).
- `$cc` price — Chainlink ETH/USD feed.
