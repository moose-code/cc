# connection points

Every place the statements/credits pages use sample data or a disabled action,
and the on-chain call that replaces it at wiring time. Grep the code for
`CONNECT:` to find the same notes inline.

Sample data lives in `lib/sample.ts` — swap its getters for reads, the pages
stay the same. Reads should follow the project's RPC discipline: indexer first,
then cache, then RPC; `CoreLens.snapshot()` returns most of this in one call.

## local anvil (fork) mode

`NEXT_PUBLIC_CHAIN_ID=31337` points every read and write at a local anvil
mainnet fork (`http://127.0.0.1:8545`, viem `foundry` chain). Any other value
selects mainnet. Local mode has no explorer: tx hashes and contract addresses
render as raw text, and ENS lookups are skipped.

The only wallet is the wagmi mock connector, listed as "local account". It acts
as `NEXT_PUBLIC_LOCAL_ACCOUNT` (default
`0x1111111111111111111111111111111111111111`; `local-env.mjs` also reads it from
the environment or `record.localAccount`). Run anvil with `--auto-impersonate`
so it signs for that address. Local mode makes no WalletConnect requests.
Countdowns and "ago" labels use the latest block timestamp, not the browser clock.

Run (anvil up, contracts deployed, record written):

```bash
cd web
npm run dev:local                          # reads ../deployments/31337.json
RECORD=/path/to/31337.json npm run dev:local
```

`dev:local` runs `scripts/local-env.mjs <record> [rpcUrl]`, which writes the
gitignored `web/.env.local`, then `next dev`.

### deployment record: `deployments/<chainId>.json`

Written by the contracts deploy wrapper, read by `scripts/local-env.mjs`:

```json
{
  "chainId": 31337,
  "block": 0,
  "core": "0x..",
  "coin": "0x..",
  "controller": "0x..",
  "router": "0x..",
  "lens": "0x..",
  "poolId": "0x..",
  "credits": "0x..",
  "statements": "0x..",
  "creditScore": "0x..",
  "exitToken": "0x..",
  "exitModule": "0x.."
}
```

`block` is the deploy block (number). `exitToken` and `exitModule` are an
address or `null`. Optional `hook` (address of the pool's skim hook): the app
builds the pool key from it (`NEXT_PUBLIC_POOL_HOOK`); without it the app uses
the mainnet launch hook.

| record field | env var |
| --- | --- |
| chainId | `NEXT_PUBLIC_CHAIN_ID` |
| (flag or default) | `NEXT_PUBLIC_RPC_URL` |
| core | `NEXT_PUBLIC_CORE` |
| lens | `NEXT_PUBLIC_CORE_LENS` |
| credits | `NEXT_PUBLIC_CREDITS` |
| coin | `NEXT_PUBLIC_CC` |
| router | `NEXT_PUBLIC_ROUTER` |
| block | `NEXT_PUBLIC_DEPLOY_BLOCK` |
| hook (optional) | `NEXT_PUBLIC_POOL_HOOK` |

`controller`, `poolId`, `statements`, `creditScore`, `exitToken`, `exitModule`
are not read by the app yet.

## statements index — `app/statements/page.tsx`

- **list** — `statements` → `CoreLens.snapshot().statements` (held + listed) and
  sold statements from `StatementSoldTo` logs. Fields per statement: `id`,
  `cost`, `rating`, `priceReference`, `askingPrice`, `composedAt`, status.
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
- **history** — build from events: `Composed` (cost), the listing (start/markup),
  `StatementSoldTo` (price + buyer). % over cost = price / cost - 1. Buyer runs
  through `<Addr>` (ENS).
- **composed credits** — `creditIds` is synthesized; use the real compose record
  from the Core.

## credits index — `app/credits/page.tsx` (feed layout)

- **list** — `credits` → the engine's held pile. Count is
  `CoreLens.snapshot().pileSize`; enumerate ids from `CreditBought` logs or
  the credits NFT `balanceOf(Core)` + enumeration.
- **bid** — `engineBid` → `snapshot().ethRate` (wei per credit).

## credit detail — `app/credits/[id]/page.tsx` (engine-owned, no action)

- **load** — `getCredit(id)`; a held credit comes from the pile, a composed one
  maps to its statement. The engine owns the credit, so there is no action here.
- **paid by engine** — real `cost` from the `CreditBought` event.
- **state** — held (awaiting compose) vs composed (into statement #X), from the
  Core compose record.

## compose — `app/compose/page.tsx` (the in-progress statement)

- **filled slots** — `credits` (the pile) → the pile's credit ids (CreditBought
  logs not yet composed, or a Core pile view). Count = `snapshot().pileSize`.
- **next statement id** — the id the next compose mints.
- **compose** (button) — `Core.compose()`. Permissionless: anyone can call once
  >= 80 credits are in the pile. Enabled only when full and the Core is
  deployed. `composeChosen(ids, format)` is shown when `chosenComposeOn`, gated by `minCcToChoose`.

## sell — `app/sell/page.tsx` (holder sells into the bid)

- **your credits** — enumerate the connected wallet's Credits NFTs
  (`balanceOf` + `tokenOfOwnerByIndex`, or `Transfer` logs). `addresses.credits`.
- **bid** — `snapshot().ethRate` (wei per credit).
- **buyable now** — `ethPot / rate` caps how many the engine can buy this call;
  there may also be a per-call pace bound.
- **approve** (disabled) — `Credits.setApprovalForAll(Core, true)` once.
- **sell** (disabled) — `Core.sellForEth(ids, minOut)`. `minOut` guards the rate
  moving down between build and mine. Total received = count * rate.

## credit / statement art — `lib/credit-art.ts`, `components/Tiles.tsx`

- Tiles render the real **Credits format**: a Credit is a CMYK overprint
  (cyan/magenta/yellow/black, subtractive on white) in a 12x12 raster; a
  Statement is 80 Credits laid out 8 wide x 10 tall (burn order).
- Currently the raster is seeded by id (a faithful look-alike). At wiring time,
  draw the real raster from `Credits.seedOf(id)` + the art contract (see
  gtmcknight/creditunion `CreditDrawing.sol` / `sheet` renderers), and use the
  real composed ids from the Core compose record in `statementCreditIds`.

## ENS (global) — `lib/ens.ts`, `components/Addr.tsx`

- `<Addr address>` shows the ENS name when one resolves, else a short address,
  linked to evm.now. Reverse lookups are cached in localStorage **forever**
  (hits and misses) so the RPC is never touched twice for the same address.
- Used on: the feed's sold rows, the statement history buyer. The connected
  wallet's own name comes from RainbowKit.

## already wired (for reference)

- header stats, engine feed, next-credit / next-statement bars — `lib/engine.ts`
  (live when `CORE`/`CORE_LENS` set, sample otherwise).
- trade panel price/quote/swap — `lib/v4.ts` (live when `CC` set, `poolReady`).
- `$cc` price — Chainlink ETH/USD feed.
