# data sources

Every number, list and row on the pages comes from the chain. Without the core
and lens addresses each engine page renders "engine not deployed". Before the
first read lands, values are zero or "—". Reads follow the project's RPC
discipline: `CoreLens.snapshot()` returns most engine state in one call and one
log scan feeds the feed, stats and histories.

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

## pages

| page | source |
| --- | --- |
| feed, stats bar | `Core` logs from `NEXT_PUBLIC_DEPLOY_BLOCK` (`FeesAdded`, `CreditBought`, `Composed`, `CreditSold`, `StatementSoldTo`, `StatementExited`, `Buyback`) and coin `Transfer` logs from the core to the zero address (`lib/engine.ts` `useScan`) |
| pot, bid, next statement bar | `CoreLens.snapshot()` (`ethPot`, `ethRate`, `pileSize`) |
| `/statements` | `snapshot().statements` (listed) and `StatementSoldTo` logs (sold); tile credit ids from the `Composed` logs |
| `/statements/[id]` | `snapshot().statements` plus `ControllerV1.priceOf`, `referenceOf`, `atFloor`, `paused`; history from `Composed`, `StatementSoldTo`, `StatementExited` logs and block timestamps. An id with no record shows an empty state |
| `/credits` | `Core.pilePage`, `Core.creditInfo`, `CoreLens.choosable`, `CoreLens.creditPriceOf` |
| `/credits/[id]` | `Core.creditInfo` (in pile), `Composed` logs (statement), `CreditBought` and `CreditSold` logs. An id with no record shows an empty state |
| `/compose` | `snapshot()` (`pileSize`, `pageReady`, `chosenComposeOn`, `minCcToChoose`), the pile reads above, `Core.compose` and `composeChosen` |
| `/sell` | `Credits.tokensOf(account)`, `snapshot()` (`ethRate`, `ethPot`), `Core.settings` and the rate storage slot for the batch quote, `Core.sellForEth` |
| trade panel | v4 `StateView.getSlot0`, v4 `Quoter`, Universal Router; `$cc` price from the Chainlink ETH/USD feed (shows "—" when the read fails) |

## credit / statement art — `lib/credit-art.ts`, `components/Tiles.tsx`

- Tiles render the Credits format: a Credit is a CMYK overprint
  (cyan/magenta/yellow/black, subtractive on white) in a 12x12 raster; a
  Statement is 80 Credits laid out 8 wide x 10 tall (burn order).
- The raster is drawn from the credit id with a seeded PRNG. The statement
  grid uses the credit ids of its `Composed` event.

## ENS (global) — `lib/ens.ts`, `components/Addr.tsx`

- `<Addr address>` shows the ENS name when one resolves, else a short address,
  linked to evm.now. Reverse lookups are cached in localStorage **forever**
  (hits and misses) so the RPC is never touched twice for the same address.
- Used on: the feed's sold rows, the statement history buyer. The connected
  wallet's own name comes from RainbowKit.
