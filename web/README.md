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
Run anvil with `--auto-impersonate`: RainbowKit's wallet list shows the
accounts of the record as wallets, and writes are signed by anvil for the
connected address, so no wallet extension is needed.

## run against mainnet

```bash
cp .env.example .env.local   # set NEXT_PUBLIC_CORE and NEXT_PUBLIC_DEPLOY_BLOCK
npm run dev                  # or npm run build && npm start
```

The controller, coin and balance module are read from the Core. Without
`NEXT_PUBLIC_CORE` the engine pages show "engine not deployed". Wallets connect
through RainbowKit. `npm run check` runs `scripts/selfcheck.ts` (the sell
replays) and `scripts/v4-selfcheck.ts` (the swap encoders). `npm run build`
type checks.

## pages and actions

Prices shown to buyers are the gross ones (`grossPriceOf`, `grossCreditPrice`),
with the engine price and the royalty as the breakdown. The balance side
(redeem, sell for balance, the balance pot, rating value) shows once
`core.balanceModule()` is set.

| page | reads | actions |
|---|---|---|
| `/` flywheel, stats bar, engine feed, swap panel | event scan, snapshot, pool slot0 (StateView), v4 Quoter, Chainlink ETH/USD | Universal Router `execute` (eth for coin and back), coin `approve` and Permit2 `approve` before a sell |
| `/keeper` | snapshot, `lastBuybackBlock`, head block | `core.book()`, `core.buyback()`, `core.claimPayee()`, `controller.claimRoyalty()` |
| `/credits`, `/credits/[id]` | `pilePage`, `creditInfo`, `creditPrice`, `grossCreditPrice`, `pastWindow` | `controller.buyCredit(id)`, `buyCredits(ids)` while `creditSaleOn` |
| `/sell` | `ethRate`, `ethPot`, `settings`, `Credits.tokensOf` | `Credits.setApprovalForAll(core)`, `core.sellForEth(ids, minOut)`, `core.sellForBalance(ids, minOut)` while `balanceBidOn` |
| `/compose` | `nextPage`, `pileSize`, `chosenComposeOn`, `minCcToChoose` | `core.compose()`, `core.compose(format)`, `core.composeChosen(ids, format)` while `chosenComposeOn` |
| `/statements`, `/statements/[id]` | `heldStatements`, `statementInfo`, `statementAge`, `ratingOf`, `composerOf`, `priceOf`, `grossPriceOf`, `referenceOf`, `atFloor`, `valueOf` | `controller.buy(sid)` at the gross price, `core.setHeldFormat(sid, format)`, `core.redeemStatement(sid)` when `redeemOn` and `atFloor` |

`sellForEth` and `sellForBalance` send `minOut` at 99.5% of the batch total,
replayed from the Core's per-credit rules at click time (`lib/sell.ts`, read by
`sellQuote` and `balanceQuote` in `lib/live.ts`). A sweep of a listing
(`buyListing`) is a keeper action and has no page.
