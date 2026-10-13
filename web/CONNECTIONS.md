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

`creditScore` and `exitModule`
are not read by the app yet.

## pages

| page | source |
| --- | --- |
| feed, stats bar | every event of the `Core`, the controller(s) (`Core.controller()` and each `ControllerSet`) and the fee router (`engineEventsAbi` in `lib/abis.ts`), from `NEXT_PUBLIC_DEPLOY_BLOCK`, and coin `Transfer` logs from the core to the zero address (`lib/engine.ts` `useScan`, rows built in `lib/events.ts`). Compose mode (default or chosen) comes from the Composed transaction's calldata; `SettingsSet` rows diff against the previous settings (the first against `Core.settings()` one block earlier); the `$BALANCE` decimals come from `Core.exitToken()`, `$BALANCE` paid for a credit from the token's `Transfer` logs from the core in the `CreditBought` transaction, and the listed price on a composed row from the `price` field of the `Composed` event (0 shows no listed price) |
| pot, bid, next statement bar | `CoreLens.snapshot()` (`ethPot`, `ethRate`, `pileSize`) |
| `/statements` | `snapshot().statements` (for sale), `StatementSoldTo` logs (sold), `StatementExited` logs (redeemed); composed statements with none of these show as not held |
| `/statements/[id]` | `snapshot().statements` plus `ControllerV1.priceOf`, `referenceOf`, `atFloor`, `paused`; history from `Composed` (credits, format, caller, compose mode), `StatementSoldTo`, `AnchorMoved` and `StatementExited` logs and block timestamps. An id with no record shows an empty state |
| `/credits` | `Core.pilePage`, `Core.creditInfo`, `CoreLens.choosable`, `CoreLens.creditPriceOf` |
| `/credits/[id]` | `Core.creditInfo` (in pile), `CoreLens.choosable`, `CoreLens.creditPriceOf` and `snapshot().creditWindow` (sale window), `CreditBought` (eth bid, or `$BALANCE` bid when no `EthRateFill` precedes it in the transaction), `ListingBought`, `CreditAdopted`, `CreditSold` and `Composed` logs. An id with no record shows an empty state |
| `/compose` | `snapshot()` (`pileSize`, `pageReady`, `chosenComposeOn`, `minCcToChoose`), the pile reads above, `Core.compose` and `composeChosen` |
| `/sell` | `Credits.tokensOf(account)`, `snapshot()` (`ethRate`, `ethPot`), `Core.settings` and the rate storage slot for the batch quote, `Core.sellForEth` |
| trade panel | pool key from `Core.HOOK`, `POOL_FEE`, `TICK_SPACING`; fee from the hook's `skimConfig` and the MEV module's `currentSkimBps`; engine share from `skimConfig.bountyBps` less the router payee split (`splitOn`, `payeePpmTotal`); v4 `StateView.getSlot0`, v4 `Quoter`, Universal Router; `$cc` price from the Chainlink ETH/USD feed (shows "—" when the read fails) |

## credit / statement art — `lib/art.ts`, `components/Tiles.tsx`

- Tiles show the `image` of `tokenURI(id)` of the Credits and Statements
  contracts (addresses from `CoreLens.CREDITS()` and `STATEMENTS()`).
  `data:application/json` metadata (base64, utf8 or percent-encoded) is
  decoded in the browser; http and ipfs metadata is fetched. The image is a
  data URI or a URL.
- Reads of one render pass go out as one multicall per collection and are
  cached per token id. A token whose `tokenURI` reverts (a credit burned in a
  compose) shows an empty tile with its id.
- Statement format name and credit rating come from the metadata attributes.

## ENS (global) — `lib/ens.ts`, `components/Addr.tsx`

- `<Addr address>` shows the ENS name when one resolves, else a short address,
  linked to evm.now. Reverse lookups are cached in localStorage **forever**
  (hits and misses) so the RPC is never touched twice for the same address.
- Used on: the feed's sold rows, the statement history buyer. The connected
  wallet's own name comes from RainbowKit.
