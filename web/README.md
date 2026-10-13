# credits engine — v1 web ui

Independent dashboard for the credits engine: a live engine feed (fees in,
credits bought, statements composed/listed/sold, coin burned) and a buy/sell
panel for the CC coin.

Stack: Next.js (app router) · wagmi · viem · RainbowKit · TanStack Query.

## run

```bash
cd web
cp .env.example .env   # optional; works without it
npm install
npm run dev            # http://localhost:3000
```

## local anvil

`npm run dev:local` runs the UI against a local anvil mainnet fork
(chain 31337, `http://127.0.0.1:8545`) with addresses from
`../deployments/31337.json` (`RECORD=<path>` overrides). Record format and env
mapping: `CONNECTIONS.md`.

## data

Every value comes from the chain. Without the engine addresses the engine
pages render "engine not deployed".

Set the engine addresses in `.env`:

- `NEXT_PUBLIC_CORE_LENS` + `NEXT_PUBLIC_CORE` — turns the feed and stats
  on-chain. Stats aggregate the scanned log window (recent, not genesis
  cumulative). The feed decodes `FeesAdded`, `CreditBought`, `Composed`,
  `StatementSoldTo`, `Buyback`.
- `NEXT_PUBLIC_CREDITS`, `NEXT_PUBLIC_CC` — credits NFT and coin.
- `NEXT_PUBLIC_DEPLOY_BLOCK` — speeds up the feed log scan.
- `NEXT_PUBLIC_RPC_URL` — mainnet RPC (public fallback otherwise).
- `NEXT_PUBLIC_WC_PROJECT_ID` — WalletConnect id. Injected wallets work
  without it; without a real id the WC relay calls 403/400 harmlessly.

## not in v1

Swap execution is wired to the UI quote but gated until the coin and pool
launch — the Uniswap v4 swap call lands when addresses go live. The trade
panel computes quotes and connects a wallet today.

ABIs in `lib/abis.ts` are a hand-written subset kept in sync with
`src/interfaces/ICoreLens.sol` and the events in `src/Core.sol` /
`src/ControllerV1.sol`.
