# credits engine web app

Next.js 14 (app router), wagmi 2, viem 2, RainbowKit. Every value comes from
the chain: one viem multicall over the views of `docs/INTEGRATION.md` section 2
(`lib/live.ts`) and one incremental event scan (`lib/engine.ts`, rows in
`lib/events.ts`). `lib/abis.ts` is a hand written subset of
`src/interfaces/ICore.sol`, `IControllerV1.sol` and `ISeaportBasicAdapter.sol`.

## run against anvil

```bash
cd web
npm install
npm run dev:local        # http://localhost:3000
```

`dev:local` runs `scripts/local-env.mjs`, which reads `../deployments/31337.json`
(`RECORD=<path>` reads another file), writes the ignored `.env.local`, then
starts `next dev`. When the record is missing it prints the reason and exits.
Run anvil with `--auto-impersonate`: the header select switches between the
accounts of the record, and writes are signed by anvil for that address, so no
wallet is needed.

## run against mainnet

```bash
cp .env.example .env.local   # set NEXT_PUBLIC_CORE and NEXT_PUBLIC_DEPLOY_BLOCK
npm run dev                  # or npm run build && npm start
```

The controller, coin and balance module are read from the Core. Without
`NEXT_PUBLIC_CORE` the engine pages show "engine not deployed". Wallets connect
through RainbowKit. `npm run check` runs `scripts/selfcheck.ts` (the sell
estimate). `npm run build` type checks.

## pages and actions

Prices shown to buyers are the gross ones (`grossPriceOf`, `grossCreditPrice`),
with the engine price and the royalty as the breakdown. The balance side
(redeem, sell for balance, the balance pot, rating value) shows once
`core.balanceModule()` is set.

| page | reads | actions |
|---|---|---|
| `/` engine feed, stats bar, engine panel | event scan, snapshot | `core.book()`, `core.buyback()`, `controller.claimRoyalty()` |
| `/credits`, `/credits/[id]` | `pilePage`, `creditInfo`, `creditPrice`, `grossCreditPrice`, `pastWindow` | `controller.buyCredit(id)`, `buyCredits(ids)` while `creditSaleOn` |
| `/sell` | `ethRate`, `ethPot`, `settings`, `Credits.tokensOf` | `Credits.setApprovalForAll(core)`, `core.sellForEth(ids, minOut)`, `core.sellForBalance(ids, minOut)` while `balanceBidOn` |
| `/compose` | `nextPage`, `pileSize`, `chosenComposeOn`, `minCcToChoose` | `core.compose()`, `core.compose(format)`, `core.composeChosen(ids, format)` while `chosenComposeOn` |
| `/statements`, `/statements/[id]` | `heldStatements`, `statementInfo`, `statementAge`, `ratingOf`, `composerOf`, `priceOf`, `grossPriceOf`, `referenceOf`, `atFloor`, `valueOf` | `controller.buy(sid)` at the gross price, `core.setHeldFormat(sid, format)`, `core.redeemStatement(sid)` when `redeemOn` and `atFloor` |

`sellForEth` sends `minOut` at 98% of an estimate of the batch total
(`lib/sell.ts`). `sellForBalance` sends `minOut` 1: the payout is score times the
module unit and the app does not read scores. A sweep of a listing
(`buyListing`) is a keeper action and has no page.
